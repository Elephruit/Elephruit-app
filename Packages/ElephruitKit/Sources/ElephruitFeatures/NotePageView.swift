import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI
import UniformTypeIdentifiers

/// The note page: prose segments and object pieces, in document order, over one scroll view.
///
/// The page renders what ``NoteEditorModel`` says the document is. Rows are identified by what
/// they represent — a prose segment by its ordinal among prose segments, an object by its piece
/// position — never by their index in the visible list; that distinction is the `/` menu trap
/// from the spec, and it applies to the page for the same reason.
public struct NotePageView: View {
    @Environment(\.services) private var services
    @Environment(\.undoManager) private var windowUndoManager

    let item: Item
    let navigation: NavigationModel
    @Bindable var model: NoteEditorModel

    @State private var pendingSave = PendingSave()
    @State private var pageEditorID = UUID()
    @State private var loadedItemID: UUID?

    /// A file import waiting on the open panel, remembering where it will land.
    private struct PendingImport: Identifiable {
        enum Flavour {
            case image
            case file
        }

        var id = UUID()
        var flavour: Flavour
        var location: NotePieceLocation
    }

    @State private var pendingImport: PendingImport?
    @State private var referencePickerLocation: NotePieceLocation?
    @State private var visibleRect: CGRect = .zero

    public init(item: Item, navigation: NavigationModel, model: NoteEditorModel) {
        self.item = item
        self.navigation = navigation
        self.model = model
    }

    public var body: some View {
        ScrollView {
            content
        }
        .onScrollGeometryChange(for: CGRect.self) { geometry in
            CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
        } action: { _, newValue in
            visibleRect = newValue
            model.updateActiveOutlineEntry(viewportTop: newValue.minY)
        }
        .task(id: item.id) { load() }
        .task { navigation.registerEditFlush(pageEditorID) { pendingSave.flush() } }
        .onDisappear {
            navigation.unregisterEditFlush(pageEditorID)
            pendingSave.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            pendingSave.flush()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            pendingSave.flush()
        }
        .fileImporter(
            isPresented: importBinding,
            allowedContentTypes: pendingImport?.flavour == .image ? [.image] : [.item],
            allowsMultipleSelection: false
        ) { result in
            completeImport(result)
        }
        .sheet(isPresented: referencePickerBinding) {
            NoteReferencePickerSheet(excludedItemID: item.id) { pickedID in
                if let location = referencePickerLocation {
                    model.insertObject(.reference(itemID: pickedID), at: location)
                }
                referencePickerLocation = nil
            }
        }
        // The Format menu and the ⌘F flip act on whichever note's editor is open in this scene.
        .focusedSceneValue(\.noteEditor, model)
        .accessibilityIdentifier(AccessibilityID.Notes.page)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(pageRows) { row in
                switch row.kind {
                case .prose(let ordinal):
                    NoteProseSegmentView(
                        model: model,
                        ordinal: ordinal,
                        isEditable: !item.isInTrash,
                        onInsertionCommand: handleInsertion,
                        onOpenLink: open
                    )
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("noteContent"))
                    } action: { frame in
                        model.proseSegmentFrames[ordinal] = frame
                    }

                case .object(let pieceIndex, let object):
                    NoteObjectPieceView(
                        model: model,
                        item: item,
                        pieceIndex: pieceIndex,
                        object: object,
                        onOpenItem: { navigation.selectItem($0) }
                    )
                    .padding(.vertical, usesEdgeToEdgeLayout(object) ? 0 : Theme.Spacing.tight)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.large)
        .frame(
            maxWidth: containsWebClip ? Theme.Size.todayContentWidth : Theme.Size.editorMaxWidth,
            alignment: .leading
        )
        .frame(maxWidth: .infinity)
        .coordinateSpace(name: "noteContent")
        .overlay(alignment: .topLeading) {
            if model.document.isEffectivelyEmpty, model.document.pieces.count == 1 {
                Text("Write, or type / to insert something…")
                    .font(Theme.Text.editorBody)
                    .foregroundStyle(Theme.Colors.placeholderText)
                    .padding(.horizontal, Theme.Spacing.section)
                    .padding(.vertical, Theme.Spacing.large)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            slashMenuOverlay
        }
    }

    /// The rows, precomputed so identity comes from the document rather than list position.
    private struct PageRow: Identifiable {
        enum Kind {
            case prose(ordinal: Int)
            case object(pieceIndex: Int, object: NoteObject)
        }

        var id: String
        var kind: Kind
    }

    private var pageRows: [PageRow] {
        var rows: [PageRow] = []
        var proseOrdinal = 0

        for segment in model.document.segments {
            switch segment {
            case .prose:
                rows.append(PageRow(id: "prose-\(proseOrdinal)", kind: .prose(ordinal: proseOrdinal)))
                proseOrdinal += 1
            case .object(let index):
                if case .object(let object) = model.document.pieces[index] {
                    rows.append(PageRow(id: "object-\(index)", kind: .object(pieceIndex: index, object: object)))
                }
            }
        }

        return rows
    }

    private var containsWebClip: Bool {
        model.document.pieces.contains { piece in
            if case .object(.webClip) = piece { return true }
            return false
        }
    }

    private func usesEdgeToEdgeLayout(_ object: NoteObject) -> Bool {
        if case .webClip = object { return true }
        guard case .image(let attachmentID, _) = object else { return false }
        return (item.attachments ?? []).first(where: { $0.id == attachmentID })?
            .filename.hasPrefix("full-page-") == true
    }

    // MARK: - The / menu overlay

    @ViewBuilder
    private var slashMenuOverlay: some View {
        if let menu = model.slashMenu {
            let matches = model.slashMatches
            NoteSlashMenuView(
                matches: matches,
                highlighted: menu.highlighted,
                onHighlight: { command in
                    var updated = menu
                    updated.highlighted = command
                    model.slashMenu = updated
                },
                onChoose: { command in
                    model.registry.view(forOrdinal: menu.ordinal)?.performInsertion(command)
                }
            )
            .offset(slashMenuOffset(for: menu))
            .accessibilityIdentifier(AccessibilityID.Notes.slashMenu)
        }
    }

    /// Keeps the menu beside the caret and inside the viewport: below the caret when there is
    /// room, above it when the caret is near the bottom of the window.
    private func slashMenuOffset(for menu: NoteEditorModel.SlashMenuState) -> CGSize {
        let menuHeight: CGFloat = 320
        let menuWidth: CGFloat = 280

        var x = menu.anchor.minX
        var y = menu.anchor.maxY + Theme.Spacing.tight

        if visibleRect.height > 0 {
            if y + menuHeight > visibleRect.maxY, menu.anchor.minY - menuHeight - 4 > visibleRect.minY {
                y = menu.anchor.minY - menuHeight - Theme.Spacing.tight
            }
            let rightEdge = min(visibleRect.width, Theme.Size.editorMaxWidth)
            if x + menuWidth > rightEdge {
                x = max(0, rightEdge - menuWidth)
            }
        }

        return CGSize(width: x, height: y)
    }

    // MARK: - Loading and saving

    private func load() {
        pendingSave.flush()

        model.undoManager = windowUndoManager
        model.onDocumentChange = { document in
            scheduleSave(document)
        }

        guard loadedItemID != item.id else { return }
        loadedItemID = item.id
        model.load(item.noteDocument)
    }

    private func scheduleSave(_ document: NoteDocument) {
        pendingSave.schedule { commit(document) }
    }

    /// Half a second after the last change, the document goes to the store — the same trade,
    /// with the same flushes, as the plain-text editor's `PendingSave`.
    private func commit(_ document: NoteDocument) {
        guard let services,
              let id = loadedItemID,
              let current = try? services.items.item(id: id),
              !current.isInTrash
        else { return }

        guard current.noteDocument != document else { return }

        services.perform {
            try services.items.update(current) { subject in
                subject.setNoteDocument(document)
            }
        }
        services.noteChange(to: current)
    }

    // MARK: - Insertions

    private func handleInsertion(_ command: NoteInsertionCommand, at location: NotePieceLocation) {
        switch command {
        case .paragraph:
            // Applied inside the text view; it never reaches the page.
            break
        case .divider:
            model.insertObject(.divider, at: location)
        case .table:
            model.insertObject(.table(Self.freshTable), at: location)
        case .image:
            pendingImport = PendingImport(flavour: .image, location: location)
        case .file:
            pendingImport = PendingImport(flavour: .file, location: location)
        case .reference:
            referencePickerLocation = location
        case .page:
            createPage(at: location)
        }
    }

    private static var freshTable: NoteTable {
        NoteTable(
            rows: [
                [NoteRichText("Column"), NoteRichText("Column"), NoteRichText("Column")],
                [NoteRichText(), NoteRichText(), NoteRichText()],
                [NoteRichText(), NoteRichText(), NoteRichText()],
            ],
            hasHeaderRow: true
        )
    }

    private var importBinding: Binding<Bool> {
        Binding(
            get: { pendingImport != nil },
            set: { if !$0 { pendingImport = nil } }
        )
    }

    private var referencePickerBinding: Binding<Bool> {
        Binding(
            get: { referencePickerLocation != nil },
            set: { if !$0 { referencePickerLocation = nil } }
        )
    }

    private func completeImport(_ result: Result<[URL], any Error>) {
        guard let services,
              let pending = pendingImport,
              case .success(let urls) = result,
              let url = urls.first
        else {
            pendingImport = nil
            return
        }
        pendingImport = nil

        var created: Attachment?
        services.perform {
            created = try services.attachments.attachCopy(of: url, to: item)
        }
        guard let attachment = created else { return }

        switch pending.flavour {
        case .image:
            model.insertObject(.image(attachmentID: attachment.id, caption: NoteRichText()), at: pending.location)
        case .file:
            model.insertObject(.file(attachmentID: attachment.id), at: pending.location)
        }
        services.noteChange(to: item)
    }

    /// A nested page is a real note, created now, linked from here. Not a child in the store —
    /// notes do not contain items — but kept in the same container as this note.
    private func createPage(at location: NotePieceLocation) {
        guard let services else { return }

        var created: Item?
        services.perform {
            created = try services.items.create(ItemDraft(
                kind: .note,
                title: String(localized: "Untitled Page", comment: "Title of a page created from the / menu"),
                parentID: item.parent?.id
            ))
        }
        guard let page = created else { return }

        model.insertObject(.page(noteID: page.id), at: location)
        services.refreshDerivedState()
    }

    // MARK: - Links

    private func open(_ link: NoteInlineLink) {
        switch link {
        case .url(let address):
            // Handed to the OS; the app itself has no network entitlement.
            guard let url = URL(string: address) else { return }
            NSWorkspace.shared.open(url)

        case .item(let id):
            navigation.selectItem(id)

        case .wiki(let title):
            guard let services else { return }
            Task {
                let matches = await services.search.titleSuggestions(prefix: title, limit: 1)
                if let match = matches.first {
                    navigation.selectItem(match.id)
                }
            }
        }
    }
}

// MARK: - Outline geometry

extension NoteEditorModel {
    /// The last heading whose paragraph sits above the viewport's reading line — what "where am
    /// I" means while scrolling.
    func updateActiveOutlineEntry(viewportTop: CGFloat) {
        let entries = outline
        guard !entries.isEmpty else {
            activeOutlineEntryID = nil
            return
        }

        var active = entries[0]
        for entry in entries {
            guard let y = pageY(of: entry) else { continue }
            if y <= viewportTop + 48 {
                active = entry
            } else {
                break
            }
        }
        if activeOutlineEntryID != active.id {
            activeOutlineEntryID = active.id
        }
    }

    /// A heading's vertical position in the page's content space: its segment's frame plus the
    /// paragraph's offset inside the text view.
    func pageY(of entry: NoteOutlineEntry) -> CGFloat? {
        guard let frame = proseSegmentFrames[entry.proseOrdinal],
              let view = registry.view(forOrdinal: entry.proseOrdinal),
              let rect = view.rectOfParagraph(ordinal: entry.paragraphOffset)
        else { return nil }
        return frame.minY + rect.minY
    }

    /// Scrolls the page so a heading's paragraph is visible, by asking the text view itself —
    /// `scrollToVisible` climbs to whatever clip view encloses it, which is the page's.
    func reveal(_ entry: NoteOutlineEntry) {
        activeOutlineEntryID = entry.id
        guard let view = registry.view(forOrdinal: entry.proseOrdinal),
              let rect = view.rectOfParagraph(ordinal: entry.paragraphOffset)
        else { return }

        // Padded below so the heading lands with its section visible, not flush at the fold.
        var target = rect
        target.size.height = min(target.height + 240, view.bounds.height - target.minY)
        _ = view.scrollToVisible(target)
    }
}

extension NoteProseTextView {
    /// The frame of the nth paragraph of this segment, in the view's coordinates.
    func rectOfParagraph(ordinal: Int) -> NSRect? {
        let text = string as NSString

        var start = 0
        var remaining = ordinal
        var scan = 0
        while remaining > 0, scan < text.length {
            if text.character(at: scan) == 0x0A {
                remaining -= 1
                start = scan + 1
            }
            scan += 1
        }
        guard remaining == 0 else { return nil }

        guard let layoutManager, let textContainer else { return nil }
        guard text.length > 0 else { return bounds }

        let anchor = min(start, text.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
        var lineRange = NSRange()
        var rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineRange)
        _ = textContainer
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        return rect
    }

    /// Runs a `/` command chosen with the mouse, through the same path the keyboard takes.
    func performInsertion(_ command: NoteInsertionCommand) {
        noteCoordinator?.prose(self, performsInsertion: command)
    }
}
