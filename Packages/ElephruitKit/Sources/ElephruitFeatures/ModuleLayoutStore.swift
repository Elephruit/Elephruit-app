import CoreGraphics
import ElephruitDesign
import Foundation
import Observation

/// What the user has done to each module's columns, and what to do with it next time.
///
/// ### Why per module rather than per window
/// Because the width of the person pane is an opinion about people, not about this window. Somebody
/// who widens it to read a profile has said something about profiles, and they should not have to
/// say it again in the next window or after the next relaunch. What is per *window* is which module
/// you are in — that lives on ``NavigationModel``, and this is keyed by module so two windows in two
/// modules never collide.
///
/// ### Why the width is stored raw and clamped on the way out
/// The stored number is a record of what the user dragged, and clamping it on the way *in* would
/// quietly forget the request the moment they used a smaller window. A 900-point profile pane
/// dragged on a 6K display should come back at 900 points on that display and at whatever fits on a
/// laptop, not be permanently reduced to the laptop's answer. So the number survives and
/// ``PaneWidth/resolved(stored:available:)`` decides what it means today.
@MainActor
@Observable
public final class ModuleLayoutStore {
    /// Keyed by module, and by `nil` for primary navigation.
    private var widths: [Key: [ModuleShellLayout.Column: CGFloat]] = [:]

    private let defaults: UserDefaults

    /// `nil` means primary navigation — Today, Inbox, a tag — which is not inside a module.
    private enum Key: Hashable {
        case module(AppModule)
        case primaryNavigation

        init(_ module: AppModule?) {
            self = module.map(Key.module) ?? .primaryNavigation
        }

        var storageName: String {
            switch self {
            case .module(let module): module.rawValue
            case .primaryNavigation: "_primary"
            }
        }

        /// The module this key names, or `nil` for primary navigation — which is what
        /// ``AppModule/shellLayout`` already takes.
        var module: AppModule? {
            switch self {
            case .module(let module): module
            case .primaryNavigation: nil
            }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Widths

    /// The width this column should have right now.
    public func width(
        of column: ModuleShellLayout.Column,
        in module: AppModule?,
        available: CGFloat
    ) -> CGFloat {
        paneWidth(of: column, in: module)
            .resolved(stored: widths[Key(module)]?[column], available: available)
    }

    /// What the user has dragged this module's columns to, unresolved.
    ///
    /// Raw, because the resolving is now done for every column at once rather than one at a time —
    /// see ``ElephruitDesign/ModuleShellLayout/widths(windowWidth:sidebarWidth:showsList:userWantsInspector:hasSelection:stored:)``.
    /// A column asked on its own could only be told about the window, which is how two columns were
    /// each offered the same slack and both took it.
    public func storedWidths(in module: AppModule?) -> [ModuleShellLayout.Column: CGFloat] {
        widths[Key(module)] ?? [:]
    }

    /// Records a width the user dragged to.
    ///
    /// Ignored when it matches what the policy would have produced anyway, so a module the user has
    /// never touched keeps following its policy — including when that policy is later changed. A
    /// stored value that happens to equal today's ideal would otherwise pin the column to a number
    /// nobody chose.
    public func setWidth(
        _ width: CGFloat,
        of column: ModuleShellLayout.Column,
        in module: AppModule?,
        available: CGFloat
    ) {
        let policy = paneWidth(of: column, in: module)
        guard !policy.isFixed else { return }

        let key = Key(module)
        let unchanged = policy.resolved(stored: nil, available: available)

        if abs(width - unchanged) < 1 {
            widths[key]?.removeValue(forKey: column)
        } else {
            widths[key, default: [:]][column] = width
        }

        save()
    }

    /// Forgets what the user did to one module, so it follows its policy again.
    public func reset(_ module: AppModule?) {
        widths.removeValue(forKey: Key(module))
        save()
    }

    public func resetAll() {
        widths.removeAll()
        save()
    }

    // MARK: - Policy lookup

    private func paneWidth(of column: ModuleShellLayout.Column, in module: AppModule?) -> PaneWidth {
        let layout = module.shellLayout
        switch column {
        case .primary: return layout.primary
        case .detail: return layout.detail.width
        case .inspector: return layout.inspector.width
        case .sidebar:
            return PaneWidth(
                minimum: Theme.Size.sidebarMinWidth,
                ideal: Theme.Size.sidebarIdealWidth,
                maximum: Theme.Size.sidebarMaxWidth
            )
        }
    }

    // MARK: - Persistence

    private static let widthsKey = "layout.moduleColumnWidths"

    /// Unreadable stored layout costs the user their divider positions, not their launch.
    private func load() {
        guard let raw = defaults.dictionary(forKey: Self.widthsKey) as? [String: [String: Double]] else {
            return
        }
        widths = decode(raw) { CGFloat($0) }
        discardImpossibleWidths()
    }

    /// Throws away any stored width the user could not have produced.
    ///
    /// ### Why this is not the clamping the type already refuses to do
    /// The note above says a stored width is never clamped on the way in, and that stands: it is
    /// clamped to *today's window* on the way out, so a 900-point pane dragged on a 6K display comes
    /// back at 900 there and at whatever fits on a laptop. That is about the window.
    ///
    /// This is about the policy. A column cannot be dragged past its own maximum, so a value outside
    /// the module's declared range is not a preference — it is a record of something that was never
    /// a drag. The store was full of them: a Notes list at 1,171 points against a declared maximum
    /// of 480, an editor at 118 against a minimum of 420. They were written by a drag detector that
    /// read the frames of the shell's own animations as choices, and while that no longer happens,
    /// what it wrote is still on disk and would otherwise be restored forever.
    private func discardImpossibleWidths() {
        for (key, columns) in widths {
            for (column, width) in columns {
                let policy = paneWidth(of: column, in: key.module)
                let ceiling = policy.maximum ?? .greatestFiniteMagnitude

                if width < policy.minimum || width > ceiling {
                    widths[key]?.removeValue(forKey: column)
                }
            }
            if widths[key]?.isEmpty == true { widths.removeValue(forKey: key) }
        }

        save()
    }

    private func decode<Stored, Value>(
        _ raw: [String: [String: Stored]],
        _ transform: (Stored) -> Value
    ) -> [Key: [ModuleShellLayout.Column: Value]] {
        var out: [Key: [ModuleShellLayout.Column: Value]] = [:]
        for (moduleName, columns) in raw {
            // A module or a column this build does not have is skipped rather than treated as a
            // failure: a preference file written by a newer version is not a reason to lose the
            // rest of the layout.
            let key: Key = moduleName == "_primary"
                ? .primaryNavigation
                : AppModule(rawValue: moduleName).map(Key.module) ?? .primaryNavigation
            guard moduleName == "_primary" || AppModule(rawValue: moduleName) != nil else { continue }

            for (columnName, value) in columns {
                guard let column = ModuleShellLayout.Column(rawValue: columnName) else { continue }
                out[key, default: [:]][column] = transform(value)
            }
        }
        return out
    }

    private func save() {
        var storedWidths: [String: [String: Double]] = [:]
        for (key, columns) in widths where !columns.isEmpty {
            storedWidths[key.storageName] = Dictionary(
                uniqueKeysWithValues: columns.map { ($0.key.rawValue, Double($0.value)) }
            )
        }

        defaults.set(storedWidths, forKey: Self.widthsKey)
    }
}

/// Tells a divider the user dragged apart from one the window moved.
///
/// ### Why the difference has to be told
/// A column's width is observable and the drag that produced it is not: all the shell sees is that
/// the pane is now 640 points instead of 560. That happens for three quite different reasons — the
/// user dragged the divider, the window was resized and every column took a share, or the shell
/// itself just applied a module's policy — and only the first is a preference worth remembering.
/// Recording the other two would mean dragging the window's corner silently rewriting the widths of
/// every module you visited afterwards, and a policy change never taking effect because the old
/// value had been re-recorded as if it were a choice.
///
/// The test is simple and holds: a column width that changed while the window width did not is a
/// drag. A value type so it can be asserted without a window, which is the only way to check
/// something whose whole job is to distinguish two indistinguishable-looking events.
///
/// ### Why it is asked once per gesture rather than once per frame
/// The test above is only true of a *settled* width. Every reason a column moves — a drag, a window
/// resize, the sidebar collapsing, a module's policy arriving — produces a stream of intermediate
/// widths, and the intermediate ones all look identical: the window width has not changed between
/// two frames of a sidebar animation any more than it has between two frames of a drag. So the
/// caller coalesces the stream and asks about the width the column came to rest at, which is also
/// the only width the user could be said to have chosen. See ``PaneWidthRecorder``.
public struct PaneDragDetector: Sendable, Hashable {
    private var lastWindowWidth: CGFloat?
    private var lastColumnWidth: CGFloat?

    /// How far a width must move to count as deliberate. Below this it is a rounding difference
    /// between two layout passes.
    private static let threshold: CGFloat = 1

    public init() {}

    /// Records a sample and says whether it was a drag.
    public mutating func isUserDrag(columnWidth: CGFloat, windowWidth: CGFloat) -> Bool {
        defer {
            lastWindowWidth = windowWidth
            lastColumnWidth = columnWidth
        }

        guard let lastWindowWidth, let lastColumnWidth else { return false }
        guard abs(windowWidth - lastWindowWidth) < Self.threshold else { return false }
        return abs(columnWidth - lastColumnWidth) >= Self.threshold
    }
}

/// Turns a stream of column widths into the few that were choices.
///
/// ### Why the samples are coalesced rather than acted on as they arrive
/// `onGeometryChange` reports every intermediate width, and a column's width changes on every frame
/// of an animation — collapsing the sidebar, arriving in a module, dragging a divider. Acting on
/// each sample meant, per frame: a `UserDefaults` write, a mutation of an `@Observable` store the
/// shell reads, and a mutation of the `@State` holding the detectors. The last two invalidate the
/// very view that produced the sample, so the shell re-evaluated its whole body — three columns, an
/// inspector, and a re-derivation of the sidebar's widths — once per frame for the length of every
/// animation. That is the sluggishness; the write was merely the least of it.
///
/// What the user chose is the width they *stopped* at, so that is the only sample worth asking
/// about. A reference type held in `@State` rather than a value: the recorder is written to on every
/// frame and read by nobody, and the whole point is that writing to it does not redraw anything.
@MainActor
public final class PaneWidthRecorder {
    /// How long the geometry must be still before a width counts as settled.
    ///
    /// Longer than a frame and shorter than a gesture: it must outlast the gaps between frames of a
    /// sidebar collapse, so that one animation produces one answer rather than two, and it must be
    /// short enough that a divider let go of is recorded before the user does anything else with the
    /// window. Nothing user-visible waits on it.
    public static let settleDelay = Duration.milliseconds(200)

    private var detectors: [ModuleShellLayout.Column: PaneDragDetector] = [:]
    private var pending: [ModuleShellLayout.Column: Sample] = [:]

    /// Columns the shell has said it is about to move itself.
    ///
    /// Cleared by the next settle whether or not anything moved, which is the case that decides the
    /// shape of this: switching between two modules whose policies agree changes no width, produces
    /// no sample, and must not leave an expectation lying in wait to swallow the user's next drag.
    private var expectingShellMove: Set<ModuleShellLayout.Column> = []

    private var settling: Task<Void, Never>?

    private struct Sample {
        var width: CGFloat
        var windowWidth: CGFloat
    }

    /// Called with each column that came to rest at a width the user chose, and the width of the
    /// window it was chosen in — carried with the sample rather than read at delivery, because the
    /// two must describe the same moment for the stored width to mean anything.
    public var onDrag: ((ModuleShellLayout.Column, CGFloat, CGFloat) -> Void)?

    public init() {}

    /// Records a sample. Nothing is decided until the geometry has been still.
    public func sample(_ width: CGFloat, of column: ModuleShellLayout.Column, windowWidth: CGFloat) {
        guard width > 0, windowWidth > 0 else { return }

        pending[column] = Sample(width: width, windowWidth: windowWidth)
        armSettle()
    }

    /// Says that the shell is about to move these columns itself, so the widths they come to rest at
    /// are adopted rather than stored as choices.
    public func expectShellMove(of columns: some Sequence<ModuleShellLayout.Column>) {
        expectingShellMove.formUnion(columns)
        armSettle()
    }

    /// Decides now rather than when the geometry goes quiet. For tests, and for a window closing.
    public func settleNow() {
        settling?.cancel()
        settling = nil
        commit()
    }

    private func armSettle() {
        settling?.cancel()
        settling = Task { [delay = Self.settleDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self.settling = nil
            self.commit()
        }
    }

    private func commit() {
        let settled = pending
        pending = [:]
        let expected = expectingShellMove
        expectingShellMove = []

        for (column, sample) in settled {
            var detector = detectors[column] ?? PaneDragDetector()
            // Asked either way, so the settled width becomes the baseline the next gesture is
            // measured against even when the shell is what moved it.
            let moved = detector.isUserDrag(columnWidth: sample.width, windowWidth: sample.windowWidth)
            detectors[column] = detector

            if moved, !expected.contains(column) {
                onDrag?(column, sample.width, sample.windowWidth)
            }
        }
    }
}
