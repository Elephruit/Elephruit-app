import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// An item's attachments, collapsed at the foot of its detail view.
///
/// Below the content and closed by default, with the count visible: attachments are *about* an item
/// rather than part of it, and the count is enough to decide whether to open the section.
public struct AttachmentSection: View {
    @Environment(\.services) private var services

    private let item: Item

    @State private var isImporting = false
    @State private var previewURL: URL?
    @State private var relocating: Attachment?

    public init(item: Item) {
        self.item = item
    }

    public var body: some View {
        DetailDisclosure(
            title: "Attachments",
            count: attachments.isEmpty ? nil : attachments.count,
            systemImage: "paperclip"
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                ForEach(attachments, id: \.id) { attachment in
                    AttachmentRow(
                        attachment: attachment,
                        onOpen: { open(attachment) },
                        onLocate: { relocating = attachment },
                        onRemove: { remove(attachment) }
                    )
                }

                Button("Attach a File…", systemImage: "plus") { isImporting = true }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Attachments.addButton)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            handleImport($0)
        }
        .fileImporter(
            isPresented: relocatingBinding,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            handleRelocate(result)
        }
        .quickLookPreview($previewURL)
        .accessibilityIdentifier(AccessibilityID.Attachments.section)
    }

    private var attachments: [Attachment] {
        (item.attachments ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private var relocatingBinding: Binding<Bool> {
        Binding(get: { relocating != nil }, set: { if !$0 { relocating = nil } })
    }

    // MARK: - Actions

    private func handleImport(_ result: Result<[URL], any Error>) {
        guard let services, case .success(let urls) = result else { return }

        services.perform {
            for url in urls {
                // Copied rather than referenced by default: a file dragged in from Downloads will be
                // tidied away, and an attachment that evaporates a week later is worse than the disk
                // it would have cost to keep.
                try services.attachments.attachCopy(of: url, to: item)
            }
        }
        services.noteChange(to: item)
    }

    private func handleRelocate(_ result: Result<[URL], any Error>) {
        guard let services,
              let attachment = relocating,
              case .success(let urls) = result,
              let url = urls.first
        else {
            relocating = nil
            return
        }
        services.perform { try services.attachments.relocate(attachment, to: url) }
        relocating = nil
    }

    private func open(_ attachment: Attachment) {
        guard let services else { return }
        guard let url = services.attachments.resolve(attachment) else { return }
        previewURL = url
    }

    private func remove(_ attachment: Attachment) {
        guard let services else { return }
        services.perform { try services.attachments.remove(attachment) }
        services.noteChange(to: item)
    }
}

/// One attachment, including the case where its file has gone.
struct AttachmentRow: View {
    let attachment: Attachment
    let onOpen: () -> Void
    let onLocate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: symbolName)
                .foregroundStyle(isLost ? Theme.Colors.warning : Theme.Colors.secondaryText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(Theme.Text.rowSubtitle)
                    .lineLimit(1)

                Text(subtitle)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(isLost ? Theme.Colors.warning : Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.small)

            if isLost {
                // The row keeps its name and size, so the user can see *what* is missing rather than
                // finding a gap where something used to be.
                Button("Locate…", action: onLocate)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            } else {
                Button("Open", action: onOpen)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Colors.tertiaryText)
            .help(attachment.storageKind == .managedCopy
                ? "Remove this attachment and delete its copy"
                : "Remove this attachment. The original file is left alone.")
            .accessibilityLabel("Remove attachment")
        }
        .frame(minHeight: Theme.Size.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityIdentifier(AccessibilityID.Attachments.row(id: attachment.id.uuidString))
    }

    private var isLost: Bool { attachment.referenceLostAt != nil }

    private var symbolName: String {
        if isLost { return "exclamationmark.triangle" }
        return attachment.storageKind == .managedCopy ? "doc" : "link"
    }

    private var subtitle: String {
        if isLost {
            return "Missing — was at \(attachment.lastKnownPath ?? "an unknown location")"
        }

        var parts = [ByteCountFormatStyle().format(Int64(attachment.byteCount))]
        parts.append(attachment.storageKind == .managedCopy ? "copied in" : "linked")
        return parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        isLost
            ? "\(attachment.filename), missing"
            : "\(attachment.filename), \(subtitle)"
    }
}

// MARK: - Drop targets

/// Accepts files dropped onto an item.
///
/// Says what it will do *before* it does it — a highlight while hovering, and copying rather than
/// moving, so nothing leaves the user's Desktop because they aimed slightly wrong.
public struct AttachmentDropTarget: ViewModifier {
    @Environment(\.services) private var services

    let item: Item
    @State private var isTargeted = false

    public func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Colors.selection, lineWidth: 2)
                        .background(Theme.Colors.selection.opacity(0.06))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                attach(urls)
                return !urls.isEmpty
            } isTargeted: { targeted in
                isTargeted = targeted
            }
    }

    private func attach(_ urls: [URL]) {
        guard let services else { return }
        services.perform {
            for url in urls {
                try services.attachments.attachCopy(of: url, to: item)
            }
        }
        services.noteChange(to: item)
    }
}

extension View {
    /// Makes a view accept dropped files as attachments.
    public func acceptsAttachmentDrops(on item: Item) -> some View {
        modifier(AttachmentDropTarget(item: item))
    }
}
