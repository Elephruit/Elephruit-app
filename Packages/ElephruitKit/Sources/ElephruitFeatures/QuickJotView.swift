import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What the caret is in the middle of typing.
///
/// Pure, so the rule for "is the user part-way through a tag" is testable without a window.
public struct CaptureCompletion: Sendable, Hashable {
    public enum Trigger: String, Sendable, Hashable {
        case tag
        case person
        case project
        case dueDate
        case followDate

        /// What was typed to start it.
        public var prefix: String {
            switch self {
            case .tag: "#"
            case .person: "@"
            case .project: ">"
            case .dueDate: "due:"
            case .followDate: "follow:"
            }
        }
    }

    public var trigger: Trigger
    /// What has been typed since the trigger.
    public var query: String
    /// Where the trigger began, as a character offset.
    public var start: Int

    public init(trigger: Trigger, query: String, start: Int) {
        self.trigger = trigger
        self.query = query
        self.start = start
    }
}

extension CaptureCompletion {
    /// Works out what, if anything, the caret is completing.
    ///
    /// Scans back from the caret to the start of the current word. A completion ends at whitespace,
    /// so `#work ` is finished and `#wo` is not — which is the behaviour that stops a suggestion
    /// list appearing over text the user has moved on from.
    public static func active(in text: String, caretAt caret: Int) -> CaptureCompletion? {
        let characters = Array(text)
        guard caret <= characters.count, caret > 0 else { return nil }

        var start = caret
        while start > 0, !characters[start - 1].isWhitespace {
            start -= 1
        }
        guard start < caret else { return nil }

        let word = String(characters[start..<caret])

        // Keywords before sigils: `due:` starts with a letter, so a sigil test would never see it.
        for trigger in [Trigger.dueDate, .followDate] where word.lowercased().hasPrefix(trigger.prefix) {
            return CaptureCompletion(
                trigger: trigger,
                query: String(word.dropFirst(trigger.prefix.count)),
                start: start
            )
        }

        for trigger in [Trigger.tag, .person, .project] where word.hasPrefix(trigger.prefix) {
            return CaptureCompletion(
                trigger: trigger,
                query: String(word.dropFirst()),
                start: start
            )
        }

        return nil
    }

    /// Replaces the word being completed with the chosen value, and says where the caret goes.
    ///
    /// A trailing space is added because the next thing typed is always something else — making the
    /// user press space after every accepted suggestion would be a tax on the common case.
    public func applying(_ value: String, to text: String, caretAt caret: Int) -> (text: String, caret: Int) {
        let characters = Array(text)
        let replacement = Array(trigger.prefix + value + " ")
        var updated = characters
        updated.replaceSubrange(start..<min(caret, characters.count), with: replacement)
        return (String(updated), start + replacement.count)
    }
}

/// The contents of the floating capture panel.
///
/// Deliberately the same grammar, the same parser and the same save path as the in-window sheet —
/// this is a different way in, not a different feature. Everything between the title and the buttons
/// is ``CaptureComposer``, which is that promise made structural rather than repeated.
///
/// What is left here is only what a panel does differently from a sheet: it cannot dismiss itself,
/// so cancelling asks the controller to hide the window; and it stays open after a failure, so it
/// has an error to show.
struct QuickJotView: View {
    @Bindable var controller: QuickJotController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            CaptureComposerHeader()

            CaptureComposer(
                text: $controller.text,
                error: controller.lastError,
                onSave: { controller.save() },
                onCancel: { controller.hide() }
            )
        }
        .padding(Theme.Spacing.large)
        .frame(width: 560)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.QuickCapture.root)
    }
}
