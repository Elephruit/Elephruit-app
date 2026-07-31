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

    /// Forgets what it has seen — used when the shell applies a policy, so the jump that follows is
    /// not mistaken for a drag.
    public mutating func reset() {
        lastWindowWidth = nil
        lastColumnWidth = nil
    }
}
