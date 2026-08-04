import ElephruitCore
import ElephruitDesign
import ElephruitModel
import SwiftUI

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
    private var isFullPageCapture: Bool {
        guard case .image(let attachmentID, _) = object else { return false }
        return item.attachments.first(where: { $0.id == attachmentID })?
            .filename.hasPrefix("full-page-") == true
    }

    var body: some View {
        face
            .padding(isFullPageCapture ? 0 : Theme.Spacing.tight)
            .background(
                RoundedRectangle(cornerRadius: isFullPageCapture ? 0 : Theme.Radius.medium)
                    .fill(isSelected ? Theme.Colors.selectionFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: isFullPageCapture ? 0 : Theme.Radius.medium)
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
                isFullPageCapture: isFullPageCapture,
                onCaptionChange: { newCaption in
                    model.updateObject(.image(attachmentID: attachmentID, caption: newCaption), atPiece: pieceIndex)
                }
            )
        case .file(let attachmentID):
            NoteFileFace(item: item, attachmentID: attachmentID)
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
        case .table: String(localized: "Table")
        case .reference: String(localized: "Linked item")
        case .page: String(localized: "Nested page")
        }
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
              let attachment = item.attachments.first(where: { $0.id == attachmentID }),
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
        item.attachments.first { $0.id == attachmentID }
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
