import AppKit
import EverythingCore
import EverythingDesign
import EverythingTransfer
import SwiftUI

/// Choosing what to export and where — journey J8.
///
/// ### Why `NSSavePanel` rather than `.fileExporter`
/// Two of the three formats write a *directory*, and SwiftUI's `fileExporter` is built around
/// `FileDocument`, which models a single file. `NSSavePanel` handles both, and it is the panel that
/// grants the sandbox permission to write where the user chose — so this is one of the four
/// sanctioned AppKit bridges in `docs/02-architecture.md`.
public struct ExportSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var format: ExportFormat = .jsonArchive
    @State private var isWriting = false
    @State private var report: ExportReport?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            header

            if let report {
                completion(report)
            } else {
                formatPicker
                footer
            }
        }
        .padding(Theme.Spacing.large)
        .frame(width: 480)
        .accessibilityIdentifier("export.sheet")
    }

    private var header: some View {
        Label("Export your library", systemImage: "square.and.arrow.up")
            .font(.system(.headline, design: .default, weight: .medium))
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(ExportFormat.allCases, id: \.self) { candidate in
                Button {
                    format = candidate
                } label: {
                    HStack(alignment: .top, spacing: Theme.Spacing.small) {
                        Image(systemName: format == candidate ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(format == candidate ? Theme.Colors.selection : Theme.Colors.tertiaryText)

                        VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                            Text(candidate.displayName)
                                .foregroundStyle(Theme.Colors.primaryText)
                            Text(candidate.explanation)
                                .font(Theme.Text.metadata)
                                .foregroundStyle(Theme.Colors.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(format == candidate ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Transfer.formatPicker)
    }

    private var footer: some View {
        HStack {
            if isWriting {
                ProgressView().controlSize(.small)
                Text("Writing…")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityIdentifier(AccessibilityID.Transfer.progress)
            }

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Choose Location…") { chooseDestinationAndWrite() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isWriting)
                .accessibilityIdentifier(AccessibilityID.Transfer.exportButton)
        }
    }

    private func completion(_ report: ExportReport) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.completed)
                Text("Exported \(report.summary).")
            }
            .accessibilityIdentifier(AccessibilityID.Transfer.summary)

            Text("\(report.fileCount) file\(report.fileCount == 1 ? "" : "s") written to \(report.destination.lastPathComponent).")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)

            HStack {
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([report.destination])
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Writing

    /// Presents the save panel, then writes.
    ///
    /// The panel is what grants sandbox access to the destination, so the write must happen while
    /// that grant is live — hence doing both here rather than storing the URL for later.
    private func chooseDestinationAndWrite() {
        guard let services else { return }

        let panel = NSSavePanel()
        panel.title = "Export Library"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName(for: format)

        if let fileExtension = format.fileExtension {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(suggestedName(for: format)).\(fileExtension)"
        } else {
            // A bundle format writes a directory the panel is asked to create.
            panel.allowedContentTypes = []
        }

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isWriting = true
        defer { isWriting = false }

        services.perform {
            report = try services.exporter.write(format: format, to: destination)
        }
    }

    private func suggestedName(for format: ExportFormat) -> String {
        let day = services?.dateProvider.todayKey ?? "export"
        return switch format {
        case .jsonArchive: "Everything-\(day)"
        case .markdownBundle: "Everything-\(day)"
        case .csv: "Everything-\(day)-csv"
        }
    }
}

#Preview("Export") {
    ExportSheet()
        .appServices(AppServices.inMemory())
}
