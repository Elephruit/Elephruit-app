import ElephruitCore
import SwiftUI

extension View {
    /// Adds trackpad swipe actions to a list row.
    ///
    /// One modifier, at the row, for every list in the app. The alternative — a gesture per list —
    /// is how three lists end up with three thresholds, two of which are wrong.
    ///
    /// Everything the swipe can do is also on the row's context menu and reachable from the
    /// keyboard: `accessibilityActions` puts each one in VoiceOver's rotor, and the caller is
    /// expected to offer the same commands in its own menu. A gesture is a shortcut for something
    /// that must already be possible without it.
    ///
    /// - Parameters:
    ///   - id: Identifies the row. Only one row's actions are ever open, and this is how the
    ///     coordinator knows which.
    ///   - leading: Revealed by swiping right. Contextual, and never destructive.
    ///   - trailing: Revealed by swiping left. The first is what a full swipe runs, if any is
    ///     marked as the default.
    ///   - allowsFullSwipe: Whether a long swipe left runs the default action rather than merely
    ///     opening. `false` where the action needs a decision first — a linked reminder, or a
    ///     permanent deletion.
    public func rowSwipeActions<ID: Hashable>(
        id: ID,
        leading: [SwipeAction] = [],
        trailing: [SwipeAction] = [],
        allowsFullSwipe: Bool = true
    ) -> some View {
        modifier(
            SwipeActionsModifier(
                rowID: AnyHashable(id),
                leading: leading,
                trailing: trailing,
                allowsFullSwipe: allowsFullSwipe
            )
        )
    }
}

/// Draws the actions behind a row and lets the coordinator move it over them.
struct SwipeActionsModifier: ViewModifier {
    @Environment(\.swipeActions) private var coordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let rowID: AnyHashable
    let leading: [SwipeAction]
    let trailing: [SwipeAction]
    let allowsFullSwipe: Bool

    @State private var rowWidth: CGFloat = 0

    func body(content: Content) -> some View {
        if coordinator == nil || (leading.isEmpty && trailing.isEmpty) {
            // Nothing to reveal, or nowhere to reveal it. The row is returned untouched rather than
            // wrapped in machinery that would only ever measure itself.
            content
        } else {
            decorated(content)
        }
    }

    @ViewBuilder
    private func decorated(_ content: Content) -> some View {
        let offset = coordinator?.offset(for: rowID) ?? 0

        ZStack(alignment: .center) {
            actionsLayer(offset: offset)

            content
                .background(Theme.Colors.contentBackground.opacity(offset == 0 ? 0 : 1))
                .offset(x: offset)
                // While the actions are exposed, a click on the row closes them rather than
                // selecting. That is the same bargain every platform makes with a revealed action:
                // the next click is spent putting the row back.
                .overlay {
                    if isOpen {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture { coordinator?.closeAll() }
                            .offset(x: offset)
                    }
                }
        }
        .clipped()
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { publish(width: proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in publish(width: width) }
            }
        }
        .onHover { coordinator?.setHovered(rowID, $0) }
        .onDisappear { coordinator?.forget(rowID) }
        .calmAnimation(Theme.Motion.standard, value: isOpen)
        // A landed full swipe. The coordinator decides *that* it landed; the row decides what to
        // run, because only the row was given the handlers.
        .onChange(of: coordinator?.pendingCommit?.row) { _, _ in runPendingCommit() }
        .accessibilityActions {
            ForEach(leading + trailing) { action in
                Button(action.title) { coordinator?.perform(action, on: rowID) }
            }
        }
    }

    /// The buttons, pinned to their edges and uncovered as the row moves off them.
    @ViewBuilder
    private func actionsLayer(offset: CGFloat) -> some View {
        HStack(spacing: 0) {
            if offset > 0 {
                buttons(leading, side: .leading, revealed: offset)
                Spacer(minLength: 0)
            } else if offset < 0 {
                Spacer(minLength: 0)
                buttons(trailing, side: .trailing, revealed: -offset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One side's buttons.
    ///
    /// Past the full-swipe threshold the default action takes the whole revealed width and its
    /// glyph changes. That is the warning: the row has stopped offering a choice of buttons and is
    /// showing the single thing that letting go will do.
    @ViewBuilder
    private func buttons(_ actions: [SwipeAction], side: SwipeSide, revealed: CGFloat) -> some View {
        let armed = coordinator?.isArmed(rowID) ?? false
        let visible = armed ? Array(actions.prefix(1).filter(\.isFullSwipeDefault)) : actions

        HStack(spacing: 0) {
            ForEach(visible.isEmpty ? actions : visible) { action in
                SwipeActionButton(
                    action: action,
                    isArmed: armed && action.isFullSwipeDefault,
                    width: buttonWidth(count: (visible.isEmpty ? actions : visible).count, revealed: revealed)
                ) {
                    coordinator?.perform(action, on: rowID)
                }
            }
        }
        .frame(width: max(revealed, 0))
    }

    private func buttonWidth(count: Int, revealed: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        // The buttons share whatever has been uncovered, so they grow with the gesture rather than
        // sitting at a fixed width with a gap behind them.
        return max(revealed / CGFloat(count), 0)
    }

    private var isOpen: Bool { coordinator?.isOpen(rowID) ?? false }

    private func publish(width: CGFloat) {
        rowWidth = width
        coordinator?.setGeometry(
            SwipeGesture(
                leadingCount: leading.count,
                trailingCount: trailing.count,
                rowWidth: width,
                allowsFullSwipeLeading: false,
                allowsFullSwipeTrailing: allowsFullSwipe && trailing.contains(where: \.isFullSwipeDefault)
            ),
            for: rowID
        )
    }

    private func runPendingCommit() {
        guard let coordinator, let side = coordinator.takeCommit(for: rowID) else { return }
        let actions = side == .trailing ? trailing : leading
        guard let action = actions.first(where: \.isFullSwipeDefault) else { return }
        coordinator.perform(action, on: rowID)
    }
}

/// One revealed button.
struct SwipeActionButton: View {
    let action: SwipeAction
    let isArmed: Bool
    let width: CGFloat
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            VStack(spacing: Theme.Spacing.hairline) {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))

                if width >= 56 {
                    Text(action.title)
                        .font(Theme.Text.metadata)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Theme.Colors.onAccent)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(action.tint)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(action.title)
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("swipe.action.\(action.id)")
    }

    private var symbolName: String {
        isArmed ? (action.armedSystemImage ?? action.systemImage) : action.systemImage
    }
}
