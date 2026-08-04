import AppKit
import ElephruitCore
import ElephruitDesign
import ElephruitModel
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// One object piece on the page: the thing a prose run flows around.
///
/// Every object shares the same frame behaviour — click to select, Delete to remove, a context
/// menu for moving — and differs only in its face. Selection is the page's cool accent, never
/// the hover fill, because "what am I looking at" and "what would I hit" are different questions.
struct NoteObjectPieceView: View {
    @Environment(\.services) private var services

    let model: NoteEditorModel
    let item: Item
    let pieceIndex: Int
    let object: NoteObject
    let onOpenItem: (UUID) -> Void

    @FocusState private var isFocused: Bool

    private var isSelected: Bool { model.selectedObjectPiece == pieceIndex }
    private var usesEdgeToEdgeFace: Bool {
        if case .webClip = object { return true }
        guard case .image(let attachmentID, _) = object else { return false }
        return (item.attachments ?? []).first(where: { $0.id == attachmentID })?
            .filename.hasPrefix("full-page-") == true
    }

    var body: some View {
        face
            .padding(usesEdgeToEdgeFace ? 0 : Theme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: usesEdgeToEdgeFace ? 0 : Theme.Radius.medium)
                    .fill(isSelected ? Theme.Colors.selectionFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: usesEdgeToEdgeFace ? 0 : Theme.Radius.medium)
                    .strokeBorder(isSelected ? Theme.Colors.selection : Color.clear, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .onTapGesture {
                model.selectedObjectPiece = pieceIndex
                isFocused = true
            }
            .onDeleteCommand {
                model.removePiece(at: pieceIndex)
            }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    model.selectedObjectPiece = pieceIndex
                } else if model.selectedObjectPiece == pieceIndex {
                    model.selectedObjectPiece = nil
                }
            }
            .contextMenu {
                Button("Move Up", systemImage: "arrow.up") {
                    model.movePiece(from: pieceIndex, to: pieceIndex - 1)
                }
                .disabled(pieceIndex == 0)

                Button("Move Down", systemImage: "arrow.down") {
                    model.movePiece(from: pieceIndex, to: pieceIndex + 1)
                }
                .disabled(pieceIndex >= model.document.pieces.count - 1)

                Divider()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.removePiece(at: pieceIndex)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var face: some View {
        switch object {
        case .divider:
            NoteDividerFace()
        case .image(let attachmentID, let caption):
            NoteImageFace(
                item: item,
                attachmentID: attachmentID,
                caption: caption,
                isFullPageCapture: usesEdgeToEdgeFace,
                onCaptionChange: { newCaption in
                    model.updateObject(.image(attachmentID: attachmentID, caption: newCaption), atPiece: pieceIndex)
                }
            )
        case .file(let attachmentID):
            NoteFileFace(item: item, attachmentID: attachmentID)
        case .webClip(let attachmentID):
            NoteWebClipFace(item: item, attachmentID: attachmentID)
        case .table(let table):
            NoteTableFace(table: table) { updated in
                model.updateObject(.table(updated), atPiece: pieceIndex)
            }
        case .reference(let itemID):
            NoteItemCardFace(itemID: itemID, flavour: .reference, onOpen: onOpenItem)
        case .page(let noteID):
            NoteItemCardFace(itemID: noteID, flavour: .page, onOpen: onOpenItem)
        }
    }

    private var accessibilityDescription: String {
        switch object {
        case .divider: String(localized: "Divider")
        case .image: String(localized: "Image")
        case .file: String(localized: "Attached file")
        case .webClip: String(localized: "Web clip")
        case .table: String(localized: "Table")
        case .reference: String(localized: "Linked item")
        case .page: String(localized: "Nested page")
        }
    }
}

// MARK: - Web clip

private struct NoteWebClipFace: View {
    @Environment(\.services) private var services

    let item: Item
    let attachmentID: UUID

    @State private var html: String?
    @State private var capturedWidth: CGFloat = 720
    @State private var capturedInset: CGFloat = 0
    @State private var resolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "globe")
                Text("Web clip")
                    .font(Theme.Text.rowTitleEmphasised)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Colors.secondaryText)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .background(Theme.Colors.subtleFill)

            if let html {
                SelectableWebClipView(
                    html: html,
                    capturedWidth: capturedWidth,
                    capturedInset: capturedInset
                )
                    .frame(width: capturedWidth)
                    .frame(maxWidth: .infinity)
            } else if resolved {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("This web clip's saved page is missing.")
                }
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(Theme.Spacing.large)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .padding(Theme.Spacing.large)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        )
        .task(id: attachmentID) { load() }
    }

    private func load() {
        defer { resolved = true }
        guard let services,
              let attachment = (item.attachments ?? []).first(where: { $0.id == attachmentID }),
              let htmlURL = services.attachments.resolve(attachment),
              let loadedHTML = try? String(contentsOf: htmlURL, encoding: .utf8)
        else { return }

        var displayHTML = loadedHTML
        for candidate in (item.attachments ?? []) where candidate.id != attachmentID {
            guard let url = services.attachments.resolve(candidate) else { continue }
            let mimeType = UTType(candidate.typeIdentifier)?.preferredMIMEType
                ?? "application/octet-stream"

            // A custom WKURLSchemeHandler can leave a static HTML navigation waiting forever for
            // an attachment subresource inside an embedded SwiftUI WebView. The attachment remains
            // a first-class file on the item for OCR and search; only the display copy is inlined.
            if let data = try? Data(contentsOf: url) {
                let source = "elephruit-attachment://\(candidate.id.uuidString.lowercased())"
                let inline = "data:\(mimeType);base64,\(data.base64EncodedString())"
                displayHTML = displayHTML.replacingOccurrences(of: source, with: inline)
            }
        }
        // A missing image must not hold the document navigation open. Its searchable attachment
        // metadata is still intact, and the rest of the clipped document remains readable.
        displayHTML = displayHTML.replacingOccurrences(
            of: #"elephruit-attachment://[0-9a-fA-F-]{36}"#,
            with: "data:,",
            options: .regularExpression
        )
        capturedWidth = Self.capturedWidth(in: loadedHTML)
        capturedInset = Self.capturedInset(in: loadedHTML)
        html = displayHTML
    }

    private static func capturedWidth(in html: String) -> CGFloat {
        let range = NSRange(html.startIndex..., in: html)
        let patterns = [
            #"data-elephruit-captured-width="([0-9.]+)""#,
            #"<article\b[^>]*style="[^"]*?\bwidth:\s*([0-9.]+)px"#,
        ]
        for pattern in patterns {
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: .caseInsensitive
            )
            guard let match = expression?.firstMatch(in: html, range: range),
                  let valueRange = Range(match.range(at: 1), in: html),
                  let width = Double(html[valueRange])
            else { continue }
            return min(max(CGFloat(width), 320), 1_200)
        }
        return 720
    }

    private static func capturedInset(in html: String) -> CGFloat {
        // AppKit's HTML importer drops CSS box padding. Preserve the first symmetric content
        // inset so older clips retain their saved desktop measure in the compatibility renderer.
        let expression = try? NSRegularExpression(
            pattern: #"padding-right:\s*([0-9.]+)px;[^\"]*padding-left:\s*([0-9.]+)px"#,
            options: .caseInsensitive
        )
        let range = NSRange(html.startIndex..., in: html)
        for match in expression?.matches(in: html, range: range) ?? [] {
            guard let rightRange = Range(match.range(at: 1), in: html),
                  let leftRange = Range(match.range(at: 2), in: html),
                  let right = Double(html[rightRange]),
                  let left = Double(html[leftRange]),
                  right > 0,
                  abs(right - left) < 0.5
            else { continue }
            return min(CGFloat(left), 64)
        }
        return 0
    }
}

private struct SelectableWebClipView: NSViewRepresentable {
    let html: String
    let capturedWidth: CGFloat
    let capturedInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: capturedWidth, height: 120)
        )
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: capturedWidth,
            height: .greatestFiniteMagnitude
        )
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        // Keep the page's captured foreground colors instead of forcing every link blue.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let rendered = try? NSMutableAttributedString(
            data: Data(html.utf8),
            options: options,
            documentAttributes: nil
        ) else { return }
        prepareForDisplay(rendered)
        textView.textContainer?.containerSize = NSSize(
            width: capturedWidth,
            height: .greatestFiniteMagnitude
        )
        textView.textStorage?.setAttributedString(rendered)
        textView.invalidateIntrinsicContentSize()
    }

    private func prepareForDisplay(_ rendered: NSMutableAttributedString) {
        let mediaWidth = max(capturedWidth - capturedInset * 2, 1)
        var mediaReplacements: [(range: NSRange, content: NSAttributedString)] = []
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, range, _ in
            guard let attachment = value as? NSTextAttachment,
                  let image = attachment.image
                    ?? attachment.contents.flatMap(NSImage.init(data:))
                    ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:)),
                  image.size.width > mediaWidth
            else { return }
            let scale = mediaWidth / image.size.width
            let displaySize = NSSize(width: mediaWidth, height: image.size.height * scale)
            let displayImage = NSImage(size: displaySize, flipped: false) { destination in
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(
                    in: destination,
                    from: NSRect(origin: .zero, size: image.size),
                    operation: .copy,
                    fraction: 1
                )
                return true
            }
            let replacement = NSTextAttachment()
            replacement.image = displayImage
            replacement.bounds = NSRect(origin: .zero, size: displaySize)
            mediaReplacements.append((range, NSAttributedString(attachment: replacement)))
        }
        for replacement in mediaReplacements.reversed() {
            rendered.replaceCharacters(in: replacement.range, with: replacement.content)
        }

        restoreCapturedBlockLayout(rendered)

        rendered.enumerateAttributes(
            in: NSRange(location: 0, length: rendered.length)
        ) { attributes, range, _ in
            guard attributes[.link] != nil,
                  let background = attributes[.backgroundColor] as? NSColor,
                  background.isDark
            else { return }
            rendered.addAttribute(.foregroundColor, value: NSColor.white, range: range)
            rendered.removeAttribute(.underlineStyle, range: range)
        }
    }

    private func restoreCapturedBlockLayout(_ rendered: NSMutableAttributedString) {
        guard capturedInset > 0 else { return }
        let plainText = rendered.string as NSString
        var location = 0

        while location < rendered.length {
            let paragraphRange = plainText.paragraphRange(
                for: NSRange(location: location, length: 0)
            )
            let attributes = rendered.attributes(
                at: paragraphRange.location,
                effectiveRange: nil
            )
            let style = ((attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()

            style.firstLineHeadIndent = capturedInset
            style.headIndent = capturedInset
            style.tailIndent = -capturedInset

            if let background = attributes[.backgroundColor] as? NSColor,
               background.isVisibleBlockBackground {
                let block = NSTextBlock()
                block.backgroundColor = background
                block.setContentWidth(
                    capturedWidth - capturedInset * 2,
                    type: .absoluteValueType
                )
                let verticalInset = min(max(capturedInset * 2 / 3, 4), 12)
                block.setWidth(verticalInset, type: .absoluteValueType, for: .padding)
                block.setWidth(
                    capturedInset,
                    type: .absoluteValueType,
                    for: .padding,
                    edge: .minX
                )
                block.setWidth(
                    capturedInset,
                    type: .absoluteValueType,
                    for: .padding,
                    edge: .maxX
                )
                style.firstLineHeadIndent = 0
                style.headIndent = 0
                style.tailIndent = 0
                style.textBlocks = [block]
            }

            rendered.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            location = NSMaxRange(paragraphRange)
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = capturedWidth
        if abs(nsView.frame.width - width) > 0.5 {
            nsView.setFrameSize(NSSize(width: width, height: nsView.frame.height))
        }
        nsView.textContainer?.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        let measuredHeight = context.coordinator.measuredHeight(for: nsView, width: width)
        return CGSize(width: width, height: measuredHeight)
    }

    @MainActor
    final class Coordinator {
        var loadedHTML: String?

        func measuredHeight(for textView: NSTextView, width: CGFloat) -> CGFloat {
            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager
            else { return 120 }

            textContainer.containerSize.height = .greatestFiniteMagnitude
            layoutManager.ensureLayout(for: textContainer)
            let content = layoutManager.usedRect(for: textContainer)
            return min(max(ceil(content.height + textView.textContainerInset.height * 2), 120), 30_000)
        }
    }
}

private extension NSColor {
    var isDark: Bool {
        guard let color = usingColorSpace(.deviceRGB) else { return false }
        let luminance = 0.2126 * color.redComponent
            + 0.7152 * color.greenComponent
            + 0.0722 * color.blueComponent
        return color.alphaComponent > 0.5 && luminance < 0.45
    }

    var isVisibleBlockBackground: Bool {
        guard let color = usingColorSpace(.deviceRGB) else { return false }
        return color.alphaComponent > 0.5
            && (color.redComponent < 0.95
                || color.greenComponent < 0.95
                || color.blueComponent < 0.95)
    }
}

// MARK: - Divider

private struct NoteDividerFace: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.separator)
            .frame(height: 1)
            .padding(.vertical, Theme.Spacing.medium)
            .padding(.horizontal, Theme.Spacing.tight)
    }
}

// MARK: - Image

private struct NoteImageFace: View {
    @Environment(\.services) private var services

    let item: Item
    let attachmentID: UUID
    let caption: NoteRichText
    let isFullPageCapture: Bool
    let onCaptionChange: (NoteRichText) -> Void

    @State private var captionDraft = ""
    @State private var image: NSImage?
    @State private var resolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: isFullPageCapture ? nil : 420)
                    .clipShape(RoundedRectangle(
                        cornerRadius: isFullPageCapture ? 0 : Theme.Radius.medium
                    ))
            } else if resolved {
                missingFace
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.medium)
                    .fill(Theme.Colors.subtleFill)
                    .frame(height: 120)
            }

            if !isFullPageCapture {
                TextField(
                    String(localized: "Add a caption", comment: "Placeholder under an image"),
                    text: $captionDraft
                )
                .textFieldStyle(.plain)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .onSubmit { commitCaption() }
            }
        }
        .task(id: attachmentID) { load() }
        .onAppear { captionDraft = caption.plainText }
    }

    private var missingFace: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "photo.badge.exclamationmark")
            Text("This image's file is missing.")
        }
        .font(Theme.Text.rowSubtitle)
        .foregroundStyle(Theme.Colors.secondaryText)
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
    }

    private func load() {
        defer { resolved = true }
        guard let services,
              let attachment = (item.attachments ?? []).first(where: { $0.id == attachmentID }),
              let url = services.attachments.resolve(attachment)
        else { return }
        image = NSImage(contentsOf: url)
    }

    private func commitCaption() {
        let updated = NoteRichText(captionDraft)
        guard updated != caption else { return }
        onCaptionChange(updated)
    }
}

// MARK: - File

private struct NoteFileFace: View {
    @Environment(\.services) private var services

    let item: Item
    let attachmentID: UUID

    @State private var previewURL: URL?

    var body: some View {
        Group {
            if let attachment {
                Button {
                    guard let services, let url = services.attachments.resolve(attachment) else { return }
                    previewURL = url
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Image(systemName: "doc")
                            .foregroundStyle(Theme.Colors.secondaryText)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.filename)
                                .font(Theme.Text.rowTitle)
                                .foregroundStyle(Theme.Colors.primaryText)
                                .lineLimit(1)
                            Text(attachment.byteCount.formatted(.byteCount(style: .file)))
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.small)
                    .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.medium))
                }
                .buttonStyle(.plain)
                .quickLookPreview($previewURL)
            } else {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("This attachment has been removed.")
                }
                .font(Theme.Text.rowSubtitle)
                .foregroundStyle(Theme.Colors.secondaryText)
                .padding(Theme.Spacing.small)
            }
        }
    }

    private var attachment: Attachment? {
        (item.attachments ?? []).first { $0.id == attachmentID }
    }
}

// MARK: - Table

private struct NoteTableFace: View {
    let table: NoteTable
    let onChange: (NoteTable) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        NoteTableCell(
                            text: table.rows[row][column].plainText,
                            isHeader: table.hasHeaderRow && row == 0
                        ) { newText in
                            commit(row: row, column: column, text: newText)
                        }
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small)
                .strokeBorder(Theme.Colors.separator, lineWidth: 1)
        )
        .contextMenu {
            Button("Add Row", systemImage: "plus") { addRow() }
            Button("Add Column", systemImage: "plus.square") { addColumn() }
            Toggle("Header Row", isOn: Binding(
                get: { table.hasHeaderRow },
                set: { value in
                    var updated = table
                    updated.hasHeaderRow = value
                    onChange(updated)
                }
            ))
            if table.rows.count > 1 {
                Divider()
                Button("Delete Last Row", systemImage: "minus", role: .destructive) { removeRow() }
            }
        }
    }

    private func commit(row: Int, column: Int, text: String) {
        var updated = table
        guard updated.rows.indices.contains(row), updated.rows[row].indices.contains(column) else { return }
        guard updated.rows[row][column].plainText != text else { return }
        updated.rows[row][column] = NoteRichText(text)
        onChange(updated)
    }

    private func addRow() {
        var updated = table
        let width = updated.rows.first?.count ?? 1
        updated.rows.append(Array(repeating: NoteRichText(), count: width))
        onChange(updated)
    }

    private func addColumn() {
        var updated = table
        updated.rows = updated.rows.map { $0 + [NoteRichText()] }
        onChange(updated)
    }

    private func removeRow() {
        var updated = table
        guard updated.rows.count > 1 else { return }
        updated.rows.removeLast()
        onChange(updated)
    }
}

private struct NoteTableCell: View {
    let text: String
    let isHeader: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(isHeader ? Theme.Text.rowTitleEmphasised : Theme.Text.rowTitle)
            .focused($isEditing)
            .onSubmit { onCommit(draft) }
            .onChange(of: isEditing) { _, editing in
                if !editing { onCommit(draft) }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.tight)
            .frame(minWidth: 96, alignment: .leading)
            .background(isHeader ? Theme.Colors.subtleFill : Color.clear)
            .border(Theme.Colors.separator, width: 0.5)
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                if !isEditing { draft = newValue }
            }
    }
}

// MARK: - Reference and page cards

private struct NoteItemCardFace: View {
    @Environment(\.services) private var services

    enum Flavour {
        case reference
        case page
    }

    let itemID: UUID
    let flavour: Flavour
    let onOpen: (UUID) -> Void

    var body: some View {
        if let item = target {
            Button {
                onOpen(itemID)
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: flavour == .page ? "doc.text" : item.kind.symbolName)
                        .foregroundStyle(Theme.Colors.secondaryText)
                        .frame(width: Theme.Size.rowGlyph)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.displayTitle)
                            .font(Theme.Text.rowTitleEmphasised)
                            .foregroundStyle(Theme.Colors.primaryText)
                            .lineLimit(1)
                        Text(flavour == .page ? String(localized: "Page") : item.kind.displayName)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(Theme.Spacing.medium)
                .background(Theme.Colors.subtleFill, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "questionmark.square.dashed")
                Text("The linked item no longer exists.")
            }
            .font(Theme.Text.rowSubtitle)
            .foregroundStyle(Theme.Colors.secondaryText)
            .padding(Theme.Spacing.medium)
        }
    }

    private var target: Item? {
        guard let services else { return nil }
        return try? services.items.item(id: itemID)
    }
}
