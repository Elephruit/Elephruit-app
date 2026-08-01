import ElephruitCore
import ElephruitDesign
import SwiftUI

/// One decision, drawn as an object that can be taken back.
///
/// ### Why a chip and not a line of prose
/// The panel used to summarise what it had understood in a sentence — "Will create a task, tagged
/// errand, due Friday". It was accurate and it was unusable: reading it told you the app had heard
/// you, and gave you no way to say it had heard wrong short of finding the words in your own sentence
/// and deleting them by hand. A chip is the same fact with a handle on it.
struct CaptureChip: View {
    @State private var isHovering = false

    let symbolName: String
    let label: String
    /// A tag's own colour, when it has one. Everything else is quiet by design — a row of five
    /// differently-tinted chips is a row nobody can scan.
    var tint: Color?
    let removalDescription: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.hairline) {
            Image(systemName: symbolName)
                .font(.system(size: 9))

            Text(label)
                .font(Theme.Text.chip)
                .lineLimit(1)

            // Revealed on hover rather than always drawn. Five chips each wearing a permanent ✕ is
            // five invitations to undo something, sitting under a sentence somebody is still writing.
            Image(systemName: "xmark")
                .font(.system(size: 7))
                .foregroundStyle(Theme.Colors.tertiaryText)
                .opacity(isHovering ? 1 : 0)
        }
        .foregroundStyle(tint ?? Theme.Colors.secondaryText)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background((tint ?? Theme.Colors.secondaryText).opacity(0.14), in: Capsule())
        .contentShape(Capsule())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: remove)
        .help(removalDescription)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(removalDescription)
    }
}

/// Everything the Quick Jot has been told, other than the words.
///
/// The project is deliberately not here — it is the destination button in the footer, because "where
/// does this go" is a different question from "what is it like", and a card that answers both in the
/// same row makes the user find the difference for themselves.
struct CaptureChipRow: View {
    @Binding var draft: QuickJotDraft

    /// Tag colours, so a chip here matches the same tag in a list. Absent is fine — an uncoloured tag
    /// is the common case.
    var tagColors: [String: String] = [:]

    var body: some View {
        FlowLayout(spacing: Theme.Spacing.tight, lineSpacing: Theme.Spacing.tight) {
            ForEach(draft.tagSlugs, id: \.self) { slug in
                CaptureChip(
                    symbolName: "number",
                    label: TextNormalizer.slugComponents(slug).last ?? slug,
                    tint: tagColors[slug].map(Theme.Palette.color(named:)),
                    removalDescription: "Remove the tag \(slug)"
                ) {
                    draft.removeTag(slug)
                }
            }

            ForEach(draft.personHints, id: \.self) { name in
                CaptureChip(
                    symbolName: "person",
                    label: name,
                    removalDescription: "Stop mentioning \(name)"
                ) {
                    draft.removePerson(name)
                }
            }

            // The start date takes the calendar and the deadline takes the flag, which is the
            // arrangement the user already knows from elsewhere. The two must never share a glyph:
            // one brings the item into Today and the other can go overdue, and an interface that drew
            // them alike would be conflating exactly what the grammar went to trouble to separate.
            if let follow = draft.followDate {
                CaptureChip(
                    symbolName: "calendar",
                    label: follow.summary,
                    removalDescription: "Clear when this starts"
                ) {
                    draft.setFollow(nil)
                }
            }

            if let due = draft.dueInterpretation {
                CaptureChip(
                    symbolName: "flag",
                    label: "Deadline: \(due.summary)",
                    removalDescription: "Clear the deadline"
                ) {
                    draft.setDue(nil)
                }
            }

            if let priority = draft.priority, let symbol = priority.symbolName {
                CaptureChip(
                    symbolName: symbol,
                    label: priority.displayName,
                    removalDescription: "Clear the priority"
                ) {
                    draft.setPriority(nil)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.QuickCapture.interpretation)
    }
}

/// The checkbox that says whether this is a task.
///
/// ### Why a checkbox rather than a segmented control
/// Because it is the thing it stands for. A to-do in this app is drawn with a box you tick, so a box
/// in front of the title says "this will be one of those" without needing a label, and a note is the
/// absence of one rather than a second option competing for the same space. It is also where the eye
/// already is: immediately left of the first character somebody is about to type.
///
/// Setting a date, a priority or a project ticks it on the user's behalf, because a note in this app
/// can hold none of those. That happens in ``QuickJotDraft``, where the decision is recorded, so it
/// happens identically whether the date arrived from this row or from the sentence.
struct CaptureKindToggle: View {
    @Binding var draft: QuickJotDraft

    private var isTask: Bool { draft.kind == .task }

    var body: some View {
        Button {
            draft.choose(isTask ? .note : .task)
        } label: {
            Image(systemName: isTask ? "square" : "text.alignleft")
                .font(.system(size: 13, weight: .light))
                .foregroundStyle(isTask ? Theme.Colors.secondaryText : Theme.Colors.tertiaryText)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isTask ? "A task. Click to make it a note." : "A note. Click to make it a task.")
        .accessibilityIdentifier(AccessibilityID.QuickCapture.kindToggle)
        .accessibilityLabel(isTask ? "Task" : "Note")
        .accessibilityHint("Switches between a task and a note")
    }
}
