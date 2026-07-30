import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import ElephruitTransfer
import SwiftUI
import UniformTypeIdentifiers

/// One window.
///
/// A three-column `NavigationSplitView` — sidebar, list, detail — with the inspector as a trailing
/// pane rather than a fourth column, because an inspector is *about* the detail rather than a peer
/// of it.
///
/// Owns its own ``NavigationModel``, so two windows can look at different things.
public struct RootView: View {
    @Environment(\.services) private var services

    @State private var navigation = NavigationModel()
    @State private var isExportPresented = false
    @State private var isImportPresented = false
    @State private var transferSummary: String?
    @State private var isRepairSheetPresented = false

    public init() {}

    public var body: some View {
        Group {
            if services == nil {
                // The shell can render before services exist only in a misconfigured scene; saying so
                // beats an empty window with no explanation.
                EmptyStateView(
                    symbolName: "exclamationmark.triangle",
                    headline: "Library unavailable",
                    message: "Elephruit could not reach your library. Restart the app to try again."
                )
            } else {
                shellWithBanner
            }
        }
        .environment(navigation)
        .sheet(isPresented: quickCaptureBinding) {
            QuickCaptureView { id in
                navigation.selectItem(id)
            }
        }
        .sheet(isPresented: commandPaletteBinding) {
            CommandPaletteView(navigation: navigation, commands: paletteCommands)
        }
        .sheet(isPresented: $isExportPresented) {
            ExportSheet()
        }
        .fileImporter(
            isPresented: $isImportPresented,
            allowedContentTypes: [.json, UTType(filenameExtension: "md") ?? .plainText, .plainText],
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .alert(
            errorTitle,
            isPresented: errorBinding,
            presenting: services?.lastError
        ) { error in
            // The recovery options come from `AppError` itself, so the same failure always offers the
            // same way out no matter where it was raised.
            ForEach(error.recovery, id: \.self) { option in
                Button(option.title, role: option.isDestructive ? .destructive : nil) {
                    handleRecovery(option, for: error)
                }
            }
        } message: { error in
            Text(error.failureReason ?? "")
        }
        .alert("Transfer complete", isPresented: transferSummaryBinding) {
            Button("OK") { transferSummary = nil }
        } message: {
            Text(transferSummary ?? "")
        }
        .task {
            services?.checkForContainmentRepair()
            // Housekeeping, in the same place and on the same terms: looked at once the store is
            // open, reported if there is anything to say, and never acted on unasked.
            services?.checkForAttachmentTidy()
            // Before the index warm, because a timer left running deserves an answer sooner than
            // search deserves to be fast.
            services?.timer.start()
            await services?.warmSearchIndex()
        }
        .sheet(isPresented: repairSheetBinding) {
            if let services, let report = services.pendingContainmentRepair {
                ContainmentRepairSheet(
                    report: report,
                    onApply: {
                        services.applyContainmentRepair()
                        isRepairSheetPresented = false
                    },
                    onDefer: {
                        services.deferContainmentRepair()
                        isRepairSheetPresented = false
                    }
                )
            }
        }
        // One handler for the whole window. The ladder decides; the view only reports the key.
        // Returning `.ignored` when nothing happened lets the event fall through rather than being
        // silently swallowed.
        .onKeyPress(.escape) {
            navigation.handleEscape() ? .handled : .ignored
        }
    }

    /// The shell, with the repair offer above it when there is one.
    ///
    /// Lifted out of `body` because the combined expression exceeded the type checker's budget — the
    /// same limit documented on `ItemPredicateBuilder`, in a different guise.
    @ViewBuilder
    private var shellWithBanner: some View {
        VStack(spacing: 0) {
            if let report = services?.pendingContainmentRepair {
                ContainmentRepairBanner(report: report) {
                    isRepairSheetPresented = true
                }
            }
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            SidebarView(navigation: navigation)
                // Derived, not fixed: the minimum is whatever primary navigation needs at the current
                // text size, so a long or localised title widens the sidebar rather than truncating.
                .navigationSplitViewColumnWidth(
                    min: SidebarMetrics.minimumWidth(fittingTitles: SidebarRegistry.nonTruncatingTitles),
                    ideal: SidebarMetrics.idealWidth(fittingTitles: SidebarRegistry.nonTruncatingTitles),
                    max: SidebarMetrics.maximumWidth
                )
        } content: {
            // Time replaces the list rather than opening beside it: it *is* the middle column's
            // contents for that destination, in the same way a project's task list is.
            Group {
                if navigation.selection == .time {
                    TimeView(navigation: navigation)
                } else if navigation.selection == .home {
                    HomeView(navigation: navigation)
                } else {
                    ItemListView(navigation: navigation)
                }
            }
            .navigationSplitViewColumnWidth(
                min: Theme.Size.listMinWidth,
                ideal: Theme.Size.listIdealWidth
            )
        } detail: {
            ItemDetailView(navigation: navigation)
                .frame(
                    // Focus mode caps the measure: long lines are hard to read, and the point of the
                    // mode is reading and writing rather than filling the window.
                    maxWidth: navigation.layoutMode == .focus ? Theme.Size.editorMaxWidth : .infinity
                )
                .frame(maxWidth: .infinity)
                .navigationSplitViewColumnWidth(min: Theme.Size.detailMinWidth, ideal: 720)
        }
        .navigationSplitViewStyle(.balanced)
        .inspector(isPresented: inspectorBinding) {
            InspectorView(navigation: navigation)
                .inspectorColumnWidth(
                    min: InspectorLayout.minimumWidth,
                    ideal: InspectorLayout.idealWidth,
                    max: InspectorLayout.maximumWidth
                )
        }
        .focusedSceneValue(\.navigationModel, navigation)
        .focusedSceneValue(\.transferActions, TransferActions(
            export: { isExportPresented = true },
            importFiles: { isImportPresented = true }
        ))
    }

    // MARK: - Palette commands

    /// The palette's contents.
    ///
    /// Built here rather than in a global registry so that every command closes over *this* window's
    /// navigation model — a palette action in one window must not move another window.
    private var paletteCommands: [PaletteCommand] {
        // Glyphs come from the registry, never from a literal beside the row.
        let registry = services?.shortcuts ?? ShortcutRegistry()

        var commands: [PaletteCommand] = [
            PaletteCommand(id: "go-today", title: "Go to Today", category: .navigate, symbolName: "sun.max", command: .goToday, in: registry) {
                navigation.select(.today)
            },
            PaletteCommand(id: "go-upcoming", title: "Go to Upcoming", category: .navigate, symbolName: "calendar") {
                navigation.select(.upcoming)
            },
            PaletteCommand(id: "go-inbox", title: "Go to Inbox", category: .navigate, symbolName: "tray", command: .goInbox, in: registry) {
                navigation.select(.inbox)
            },
            PaletteCommand(id: "go-trash", title: "Go to Trash", category: .navigate, symbolName: "trash") {
                navigation.select(.trash)
            },
        ]

        for kind in ItemKind.shippingInMilestoneOne where kind != .dailyEntry {
            commands.append(
                PaletteCommand(
                    id: "go-\(kind.rawValue)",
                    title: "Go to \(kind.pluralDisplayName)",
                    category: .navigate,
                    symbolName: kind.symbolName
                ) {
                    navigation.select(.kind(kind))
                }
            )
            commands.append(
                PaletteCommand(
                    id: "new-\(kind.rawValue)",
                    title: "New \(kind.displayName)",
                    category: .create,
                    symbolName: "plus"
                ) {
                    create(kind: kind)
                }
            )
        }

        commands.append(contentsOf: [
            PaletteCommand(id: "quick-capture", title: "Quick Capture", category: .create, symbolName: "square.and.pencil", command: .quickCapture, in: registry) {
                navigation.isQuickCaptureVisible = true
            },
            PaletteCommand(id: "search", title: "Search Everything", category: .navigate, symbolName: "magnifyingglass", command: .search, in: registry) {
                navigation.beginSearch()
            },
            PaletteCommand(id: "start-timer", title: "Start Timer", category: .create, symbolName: "play.circle", command: .toggleTimer, in: registry) {
                services?.timer.switchTo(item: nil)
            },
            PaletteCommand(id: "stop-timer", title: "Stop Timer", category: .create, symbolName: "stop.circle") {
                services?.timer.stop()
            },
            PaletteCommand(id: "go-time", title: "Go to Time", category: .navigate, symbolName: "timer") {
                navigation.select(.time)
            },
            PaletteCommand(id: "toggle-inspector", title: "Toggle Inspector", category: .view, symbolName: "sidebar.trailing", command: .toggleInspectorAlternate, in: registry) {
                navigation.isInspectorVisible.toggle()
            },
            PaletteCommand(id: "toggle-sidebar", title: "Toggle Sidebar", category: .view, symbolName: "sidebar.leading", command: .toggleSidebar, in: registry) {
                navigation.toggleSidebar()
            },
            PaletteCommand(id: "focus-mode", title: "Focus Mode", category: .view, symbolName: "rectangle.center.inset.filled", command: .focusMode, in: registry) {
                navigation.toggleFocusMode()
            },
            PaletteCommand(id: "export", title: "Export Library…", category: .transfer, symbolName: "square.and.arrow.up", command: .exportLibrary, in: registry) {
                isExportPresented = true
            },
            PaletteCommand(id: "import", title: "Import Files…", category: .transfer, symbolName: "square.and.arrow.down") {
                isImportPresented = true
            },
            PaletteCommand(id: "rebuild-index", title: "Rebuild Search Index", category: .view, symbolName: "arrow.clockwise") {
                Task {
                    await services?.invalidateAndWarmIndex()
                }
            },
        ])

        return commands
    }

    // MARK: - Bindings

    /// Layout mode drives column visibility, rather than the two states drifting apart.
    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                switch navigation.layoutMode {
                case .full: .all
                case .twoPane: .doubleColumn
                case .focus: .detailOnly
                }
            },
            set: { visibility in
                // A drag on the divider is a layout-mode change, so the two cannot disagree.
                switch visibility {
                case .all: navigation.setLayoutMode(.full)
                case .doubleColumn: navigation.setLayoutMode(.twoPane)
                case .detailOnly: navigation.setLayoutMode(.focus)
                default: break
                }
            }
        )
    }

    private var repairSheetBinding: Binding<Bool> {
        Binding(
            get: { isRepairSheetPresented && services?.pendingContainmentRepair != nil },
            set: { isRepairSheetPresented = $0 }
        )
    }

    private var inspectorBinding: Binding<Bool> {
        Binding(get: { navigation.isInspectorVisible }, set: { navigation.isInspectorVisible = $0 })
    }

    private var quickCaptureBinding: Binding<Bool> {
        Binding(get: { navigation.isQuickCaptureVisible }, set: { navigation.isQuickCaptureVisible = $0 })
    }

    private var commandPaletteBinding: Binding<Bool> {
        Binding(get: { navigation.isCommandPaletteVisible }, set: { navigation.isCommandPaletteVisible = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { services?.lastError != nil },
            set: { isPresented in
                if !isPresented { services?.clearError() }
            }
        )
    }

    private var transferSummaryBinding: Binding<Bool> {
        Binding(
            get: { transferSummary != nil },
            set: { if !$0 { transferSummary = nil } }
        )
    }

    private var errorTitle: String {
        services?.lastError?.errorDescription ?? "Something went wrong"
    }

    // MARK: - Actions

    private func create(kind: ItemKind) {
        guard let services else { return }
        services.perform {
            let created = try services.items.create(ItemDraft(kind: kind))
            navigation.select(.kind(kind))
            navigation.selectItem(created.id)
            services.noteChange(to: created)
        }
    }

    /// Reads the chosen files inside their security-scoped access and imports them.
    ///
    /// The archive and Markdown paths are distinguished by extension. Each file's access is balanced
    /// by a `defer` inside one helper, so a scope can never be left open.
    private func handleImport(_ result: Result<[URL], any Error>) {
        guard let services else { return }

        switch result {
        case .failure(let error):
            services.lastError = .importFailed(format: "file", reason: error.localizedDescription)

        case .success(let urls):
            var markdownFiles: [(filename: String, contents: String)] = []
            var reports: [ImportReport] = []

            for url in urls {
                let isJSON = url.pathExtension.lowercased() == "json"

                let outcome = withSecurityScopedAccess(url) { () -> Result<Data, AppError> in
                    do {
                        return .success(try Data(contentsOf: url))
                    } catch {
                        return .failure(.fileAccessDenied(path: url.path(percentEncoded: false)))
                    }
                }

                switch outcome {
                case .failure(let error):
                    services.lastError = error
                    return
                case .success(let data):
                    if isJSON {
                        let didImport = services.perform {
                            reports.append(try services.importer.importArchive(data))
                        }
                        guard didImport else { return }
                    } else if let text = String(data: data, encoding: .utf8) {
                        markdownFiles.append((filename: url.lastPathComponent, contents: text))
                    } else {
                        services.lastError = .importFailed(
                            format: "Markdown",
                            reason: "“\(url.lastPathComponent)” is not valid UTF-8 text."
                        )
                        return
                    }
                }
            }

            if !markdownFiles.isEmpty {
                let didImport = services.perform {
                    reports.append(try services.importer.importMarkdownFiles(markdownFiles))
                }
                guard didImport else { return }
            }

            presentImportSummary(reports)
            Task { await services.invalidateAndWarmIndex() }
        }
    }

    /// Runs work inside a security-scoped resource access, always balanced.
    ///
    /// One helper so the `stopAccessing` call cannot be forgotten — the sandbox leaks quietly when it
    /// is, and the symptom appears much later as an unexplained permission failure.
    private func withSecurityScopedAccess<Value>(_ url: URL, _ work: () -> Value) -> Value {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        return work()
    }

    private func presentImportSummary(_ reports: [ImportReport]) {
        guard !reports.isEmpty else { return }

        var lines = reports.map { "\($0.format): \($0.summary)" }
        let warnings = reports.flatMap(\.warnings)
        if !warnings.isEmpty {
            lines.append("")
            lines.append(contentsOf: warnings.prefix(5))
            if warnings.count > 5 {
                lines.append("…and \(warnings.count - 5) more.")
            }
        }
        transferSummary = lines.joined(separator: "\n")
    }

    private func handleRecovery(_ option: RecoveryOption, for error: AppError) {
        guard let services else { return }
        services.clearError()

        switch option {
        case .retry:
            Task { await services.invalidateAndWarmIndex() }
        case .chooseFile:
            isExportPresented = true
        case .revealLibraryInFinder:
            if let location = services.stack.location {
                NSWorkspace.shared.activateFileViewerSelecting([location.storeURL])
            }
        case .revealBackupInFinder:
            if let location = services.stack.location {
                NSWorkspace.shared.activateFileViewerSelecting([location.backupsRoot])
            }
        case .quit:
            NSApplication.shared.terminate(nil)
        case .dismiss, .locateFile, .removeReference, .keepBoth, .skip:
            break
        }
    }
}

import AppKit

extension AppServices {
    /// Throws away the index and rebuilds it. The user-visible "Rebuild Search Index" command.
    func invalidateAndWarmIndex() async {
        await search.invalidateIndex()
        await warmSearchIndex()
    }
}

/// Export and import, exposed to the menu bar through the focused scene.
public struct TransferActions: Sendable {
    public var export: @MainActor () -> Void
    public var importFiles: @MainActor () -> Void

    public init(export: @escaping @MainActor () -> Void, importFiles: @escaping @MainActor () -> Void) {
        self.export = export
        self.importFiles = importFiles
    }
}

extension FocusedValues {
    /// The focused window's navigation model, so menu commands act on the right window.
    @Entry public var navigationModel: NavigationModel?

    @Entry public var transferActions: TransferActions?
}

#Preview("Root", traits: .fixedLayout(width: 1180, height: 720)) {
    RootView()
        .appServices(AppServices.inMemory())
        .frame(width: 1180, height: 720)
}
