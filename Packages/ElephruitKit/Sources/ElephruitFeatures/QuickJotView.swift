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
        case bang
        case dueDate
        case followDate

        /// What was typed to start it.
        public var prefix: String {
            switch self {
            case .tag: "#"
            case .person: "@"
            case .project: ">"
            case .bang: "!"
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
    /// How many words *before* the one being typed a `>` or `@` is still looked for. Two extra words
    /// covers nearly every project and person name, and is short enough that an ordinary sentence
    /// stops offering suggestions rather than trailing them to the end of the line.
    private static let extraNameWords = 2

    /// Works out what, if anything, the caret is completing.
    ///
    /// Scans back from the caret to the start of the current word. A completion ends at whitespace,
    /// so `#work ` is finished and `#wo` is not — which is the behaviour that stops a suggestion
    /// list appearing over text the user has moved on from.
    ///
    /// For `>` and `@` the scan carries on past a space, because those name things whose names
    /// contain spaces: half-way through `>Q3 Lau` the user is still naming a project, and a
    /// suggestion list that vanished at the space would be the one moment it was needed. `#` is a
    /// single slug and the date keywords bring their own words with them, so both stop at the first
    /// space as before.
    public static func active(in text: String, caretAt caret: Int) -> CaptureCompletion? {
        let characters = Array(text)
        guard caret <= characters.count, caret > 0 else { return nil }

        var wordEnd = caret

        for wordsBack in 0...extraNameWords {
            var start = wordEnd
            while start > 0, !characters[start - 1].isWhitespace {
                start -= 1
            }
            guard start < wordEnd else { return nil }

            let span = String(characters[start..<caret])
            if let trigger = trigger(startingWith: span) {
                guard wordsBack == 0 || trigger == .person || trigger == .project else { return nil }
                return CaptureCompletion(
                    trigger: trigger,
                    query: String(span.dropFirst(trigger.prefix.count)),
                    start: start
                )
            }

            // Step back over the space to the word before. Not over a newline: the grammar is the
            // first line's, and a `>` two paragraphs up is not what this line is about.
            var previous = start
            while previous > 0, characters[previous - 1].isWhitespace, !characters[previous - 1].isNewline {
                previous -= 1
            }
            guard previous > 0, previous < start else { return nil }
            wordEnd = previous
        }

        return nil
    }

    /// The trigger a stretch of text begins with, if any.
    ///
    /// Keywords before sigils: `due:` starts with a letter, so a sigil test would never see it.
    private static func trigger(startingWith span: String) -> Trigger? {
        for trigger in [Trigger.dueDate, .followDate] where span.lowercased().hasPrefix(trigger.prefix) {
            return trigger
        }

        for trigger in [Trigger.tag, .person, .project, .bang] where span.hasPrefix(trigger.prefix) {
            return trigger
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
        CaptureComposer(
            composition: $controller.composition,
            presentationStyle: .panel,
            error: controller.lastError,
            onSave: { controller.save() },
            onCancel: { controller.hide() }
        )
        .frame(width: 560)
        .background(Theme.FloatingCapturePanel.background)
        .accessibilityIdentifier(AccessibilityID.QuickCapture.root)
    }
}
