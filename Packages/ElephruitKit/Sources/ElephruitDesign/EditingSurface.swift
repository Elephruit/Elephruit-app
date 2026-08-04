import SwiftUI

/// Where a piece of editable content has got to on its way into the store.
///
/// ### Why the user is told at all
/// Everything in this app saves itself. That is the right behaviour and it has one cost: there is no
/// moment where the user is told it worked, so "did that take?" is a question the interface never
/// answers and the user has to answer by navigating away and back. A quiet line under the field
/// answers it in place.
///
/// ### Why it is quiet
/// A save that worked is the expected outcome, and an interface that celebrates the expected outcome
/// is an interface that has to be ignored. Idle says nothing at all; saving and saved are tertiary
/// text; only a failure is coloured, because only a failure is news.
public enum SaveState: Sendable, Hashable {
    /// Nothing has changed since the last write. Says nothing.
    case idle
    /// Changes are waiting for the debounce, or are being written.
    case saving
    /// Written. Fades back to ``idle``.
    case saved
    /// The write failed and the text is still only in this window.
    case failed(String)

    /// What to show, or `nil` when there is nothing worth saying.
    public var message: String? {
        switch self {
        case .idle: nil
        case .saving: "Saving…"
        case .saved: "Saved"
        case .failed(let reason): reason
        }
    }

    public var symbolName: String? {
        switch self {
        case .idle: nil
        case .saving: "arrow.triangle.2.circlepath"
        case .saved: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Whether this state should be announced to VoiceOver rather than merely drawn.
    ///
    /// Only a failure. Announcing every autosave would talk over the user while they are typing into
    /// the field the announcement is about, which is the worst possible moment to interrupt.
    public var deservesAnnouncement: Bool { isFailure }
}

/// A titled region that is unmistakably somewhere text can be typed.
///
/// ### The problem
/// The task inspector had a large blank area below the title that accepted typing. Nothing said it
/// was for notes, nothing said it was editable, and nothing distinguished it from the pane's own
/// background — so it read as empty space that happened to swallow keystrokes. A first-time user
/// cannot find it, and a user who has found it once cannot tell whether their text is saved.
///
/// ### What makes it recognisable
/// Four things, and all four are needed. A **visible heading**, so the region has a name. A
/// **placeholder** in the field itself, so an empty one still says what it is for. A **surface** —
/// a fill a shade off the pane, with a hairline border — so the boundary of the typing area is a
/// fact rather than a guess. And a **focus ring** in the accent colour, so having clicked into it is
/// visible without a caret to hunt for.
///
/// ### Why it is compact when empty
/// A blank canvas that fills the pane says *this is the main event* about a field most tasks never
/// use, and pushes everything that matters below the fold. Empty, it is three lines and inviting;
/// it grows as it is written into and takes the room it has earned.
public struct EditingSurface<Content: View>: View {
    private let title: String
    private let systemImage: String?

    /// Shown inside the surface when there is nothing in it.
    private let placeholder: String

    private let isEmpty: Bool
    private let isFocused: Bool
    private let isEditable: Bool
    private let saveState: SaveState

    /// A control belonging to this region — a formatting menu, a link button.
    private let accessory: AnyView?

    private let content: Content

    public init(
        title: String,
        systemImage: String? = nil,
        placeholder: String,
        isEmpty: Bool,
        isFocused: Bool = false,
        isEditable: Bool = true,
        saveState: SaveState = .idle,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.placeholder = placeholder
        self.isEmpty = isEmpty
        self.isFocused = isFocused
        self.isEditable = isEditable
        self.saveState = saveState
        self.accessory = nil
        self.content = content()
    }

    public init<Accessory: View>(
        title: String,
        systemImage: String? = nil,
        placeholder: String,
        isEmpty: Bool,
        isFocused: Bool = false,
        isEditable: Bool = true,
        saveState: SaveState = .idle,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.placeholder = placeholder
        self.isEmpty = isEmpty
        self.isFocused = isFocused
        self.isEditable = isEditable
        self.saveState = saveState
        self.accessory = AnyView(accessory())
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
            header

            surface

            if let message = saveState.message {
                Label {
                    Text(message)
                } icon: {
                    if let symbol = saveState.symbolName {
                        Image(systemName: symbol)
                    }
                }
                .font(Theme.Text.metadata)
                .foregroundStyle(saveState.isFailure ? Theme.Colors.destructive : Theme.Colors.tertiaryText)
                .accessibilityHidden(!saveState.deservesAnnouncement)
                .calmAnimation(Theme.Motion.appearance, value: saveState)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let systemImage {
                Label {
                    SectionHeader(title)
                } icon: {
                    Image(systemName: systemImage)
                        .font(Theme.Text.sectionHeader)
                        .foregroundStyle(Theme.Colors.secondaryText)
                }
                .labelStyle(.titleAndIcon)
                .fixedSize()
            } else {
                SectionHeader(title)
                    .fixedSize()
            }

            Spacer()

            if let accessory, isEditable {
                accessory
            }
        }
    }

    private var surface: some View {
        content
            .overlay(alignment: .topLeading) {
                // Inside the surface rather than above it: a placeholder outside the field is a
                // caption, and a caption does not say *type here*.
                if isEmpty, !isFocused {
                    Text(placeholder)
                        .font(Theme.Text.editorBody)
                        .foregroundStyle(Theme.Colors.placeholderText)
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, Theme.Spacing.medium)
                        .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(isEditable ? Theme.Colors.contentBackground : Theme.Colors.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(
                        isFocused ? Theme.Colors.selection : Theme.Colors.separator,
                        lineWidth: isFocused ? 2 : 1
                    )
            )
            // An I-beam over an editable region, so the pointer says what the border implies before
            // anybody clicks to find out. A finger has no resting position, so on iOS there is
            // nothing to say and the modifier says nothing.
            .editingPointer(isEditable: isEditable)
            .calmAnimation(Theme.Motion.appearance, value: isFocused)
    }
}

extension View {
    @ViewBuilder
    fileprivate func editingPointer(isEditable: Bool) -> some View {
        #if os(macOS)
            pointerStyle(isEditable ? .horizontalText : nil)
        #else
            self
        #endif
    }
}

/// How tall an editor should be, given what is in it.
///
/// ### Why this is a function rather than a constant
/// Because the two failure modes are opposite and both are real. A fixed tall editor turns a task
/// with no notes into a pane that is nine-tenths empty rectangle, with the scheduling controls that
/// somebody actually opened the task for pushed below the fold. A fixed short one turns a task with
/// a page of notes into a three-line porthole. Growing with the content is the only answer that is
/// right at both ends, and stating it as arithmetic means the growth can be asserted rather than
/// eyeballed at two content lengths.
public enum EditorHeight {
    /// Empty: enough to be obviously a field and not enough to be the main event.
    public static let compact: CGFloat = 72

    /// The most it takes before it scrolls internally rather than pushing the rest of the pane down.
    public static let maximum: CGFloat = 420

    /// Roughly one line of body text at the default size.
    public static let lineHeight: CGFloat = 18

    public static func height(forLines lines: Int, isFocused: Bool = false) -> CGFloat {
        // A focused empty editor gets the room it is about to need, so clicking into it does not
        // make the pane jump on the first character typed.
        let wanted = CGFloat(max(lines, isFocused ? 4 : 1)) * lineHeight + 24
        return min(maximum, max(compact, wanted))
    }

    /// How many lines a string will occupy, near enough for sizing.
    ///
    /// Newlines plus a rough allowance for wrapping. Exact measurement would mean laying the text
    /// out twice per keystroke to save a few points of height, which is a bad trade.
    public static func lineCount(of text: String, width: CGFloat = 560) -> Int {
        guard !text.isEmpty else { return 0 }
        let charactersPerLine = max(20, Int(width / 7))

        return text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { total, line in
            total + max(1, (line.count + charactersPerLine - 1) / charactersPerLine)
        }
    }
}
