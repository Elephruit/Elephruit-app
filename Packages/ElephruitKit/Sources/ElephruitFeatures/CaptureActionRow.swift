import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// The four things a capture can be given, without knowing any punctuation.
///
/// ### Why these four, and why any at all
/// The grammar is good and it is invisible. Somebody who has not read the hint row can type a
/// sentence into Quick Jot and get a note, and there is nothing on the card telling them the app can
/// do anything else. Every sigil needs a way in that does not require having already learned it —
/// which is also the way you use it when your hands are on the mouse because you are reading
/// something else, which is most of when a capture panel is open.
///
/// When, Tag, Person, Deadline. The first and last are the two dates, which mean opposite things and
/// therefore get separate buttons rather than one date button with a mode. The project is not here —
/// it is the destination button on the other side of the footer, because "where does this go" is a
/// different question from "what is it like", and answering both in one row makes the user find the
/// difference for themselves.
///
/// Priority has no button. It is the one attribute with no equivalent in the card's visual language
/// and the only one that is genuinely rare; `!high` remains how you say it.
struct CaptureActionRow: View {
    @Binding var draft: QuickJotDraft

    var source: CaptureSuggestionSource

    /// Called before any of these opens. Everything typed but not yet settled becomes a chip first,
    /// so that a click always lands *after* what was typed rather than being overwritten by it —
    /// see ``QuickJotComposition/flush(knowing:)``.
    var onBeforeChoosing: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            CaptureDateButton(
                symbolName: "calendar",
                title: "When",
                clearTitle: "Clear When",
                expression: draft.followDate,
                calendar: source.services?.dateProvider.calendar ?? .current,
                onBeforeChoosing: onBeforeChoosing
            ) { draft.setFollow($0) }
                .accessibilityIdentifier(AccessibilityID.QuickCapture.whenButton)

            tagButton

            personButton

            CaptureDateButton(
                symbolName: "flag",
                title: "Deadline",
                clearTitle: "Clear Deadline",
                expression: draft.dueDate,
                calendar: source.services?.dateProvider.calendar ?? .current,
                onBeforeChoosing: onBeforeChoosing
            ) { draft.setDue($0.map { DateInterpretation(day: $0) }) }
                .accessibilityIdentifier(AccessibilityID.QuickCapture.deadlineButton)
        }
    }

    // MARK: - Tags

    /// A menu of what already exists, with a tick against what is already on.
    ///
    /// No "new tag" here on purpose. Inventing a tag is a decision worth a moment's thought, and `#`
    /// is both the way to do it and the thing this menu is teaching.
    private var tagButton: some View {
        Menu {
            let slugs = source.tagSlugs(matching: "", limit: 40)
            if slugs.isEmpty {
                Text("No tags yet — type # to make one")
            } else {
                ForEach(slugs, id: \.self) { slug in
                    Button {
                        onBeforeChoosing()
                        if draft.tagSlugs.contains(slug) { draft.removeTag(slug) } else { draft.addTag(slug) }
                    } label: {
                        Label(slug, systemImage: draft.tagSlugs.contains(slug) ? "checkmark" : "number")
                    }
                }
            }
        } label: {
            CaptureActionGlyph(symbolName: "tag", isActive: !draft.tagSlugs.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Tags")
        .accessibilityIdentifier(AccessibilityID.QuickCapture.tagButton)
        .accessibilityLabel("Tags")
    }

    // MARK: - People

    private var personButton: some View {
        CapturePopoverButton(
            symbolName: "person",
            isActive: !draft.personHints.isEmpty,
            help: "Mention someone",
            onBeforeChoosing: onBeforeChoosing
        ) { dismiss in
            CaptureSearchPicker(
                prompt: "Who?",
                symbolName: "person",
                search: { await source.titles(matching: $0, kinds: [.person]) }
            ) { name in
                draft.addPerson(name)
                dismiss()
            }
        }
        .accessibilityIdentifier(AccessibilityID.QuickCapture.personButton)
        .accessibilityLabel("Mention someone")
    }
}

/// One of the four glyphs, drawn the same whichever kind of control is behind it.
struct CaptureActionGlyph: View {
    let symbolName: String
    /// Filled in once the thing it stands for has been set, so the row doubles as a summary.
    let isActive: Bool

    var body: some View {
        Image(systemName: isActive ? symbolName + ".fill" : symbolName)
            .font(.system(size: 13))
            .foregroundStyle(isActive ? Theme.CaptureToken.accent : Theme.Colors.tertiaryText)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

/// A glyph that opens a popover, closing it when something is chosen.
struct CapturePopoverButton<Content: View>: View {
    let symbolName: String
    let isActive: Bool
    let help: String
    var onBeforeChoosing: () -> Void
    @ViewBuilder var content: (@escaping () -> Void) -> Content

    @State private var isPresented = false

    var body: some View {
        Button {
            onBeforeChoosing()
            isPresented = true
        } label: {
            CaptureActionGlyph(symbolName: symbolName, isActive: isActive)
        }
        .buttonStyle(.plain)
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content { isPresented = false }
        }
    }
}

/// One of the two dates.
///
/// ### Why the days are expressions rather than dates
/// "Tomorrow" written into a draft at half past eleven at night and saved at five past midnight has
/// to mean the day after the one it is saved on, not the day after the one it was chosen on. That is
/// the whole reason ``DateExpression`` exists, and resolving here to hand over a `Date` would throw
/// it away at the one moment it earns its keep. Only "Other Date…" produces an instant, because an
/// explicit calendar day is not relative to anything.
struct CaptureDateButton: View {
    let symbolName: String
    let title: String
    let clearTitle: String
    let expression: DateExpression?
    let calendar: Calendar
    var onBeforeChoosing: () -> Void
    let choose: (DateExpression?) -> Void

    @State private var isPickingDate = false
    @State private var pickedDate = Date()

    var body: some View {
        Menu {
            Button("Today") { set(.today) }
            Button("Tomorrow") { set(.tomorrow) }
            // Saturday, in `Calendar`'s 1-based numbering where Sunday is 1.
            Button("This Weekend") { set(.nextWeekday(7)) }
            Button("Next Week") { set(.weekOffset(1)) }

            Divider()

            Button("Other Date…") {
                onBeforeChoosing()
                isPickingDate = true
            }

            if expression != nil {
                Divider()
                Button(clearTitle) { set(nil) }
            }
        } label: {
            CaptureActionGlyph(symbolName: symbolName, isActive: expression != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(expression.map { "\(title): \($0.summary)" } ?? title)
        .accessibilityLabel(title)
        .popover(isPresented: $isPickingDate, arrowEdge: .bottom) {
            VStack(spacing: Theme.Spacing.small) {
                DatePicker(title, selection: $pickedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()

                Button("Set \(title)") {
                    let parts = calendar.dateComponents([.year, .month, .day], from: pickedDate)
                    if let year = parts.year, let month = parts.month, let day = parts.day {
                        choose(.explicit(year: year, month: month, day: day))
                    }
                    isPickingDate = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(Theme.Spacing.medium)
        }
    }

    private func set(_ expression: DateExpression?) {
        onBeforeChoosing()
        choose(expression)
    }
}

/// Where the capture will be filed — the Inbox, or something that can contain it.
///
/// ### Why an unresolved name is shown rather than corrected
/// Typing `>Q3 Lunch` when the project is "Q3 Launch" files the item in the Inbox, which is the right
/// behaviour — guessing would be worse — but silently. This says so, in the place the answer is,
/// while the panel is still open and the typo is still fixable.
///
/// The picker stores the *exact* title it was given, so a project chosen with the mouse always
/// resolves. Only a name typed by hand can fail to.
struct CaptureDestinationButton: View {
    @Binding var draft: QuickJotDraft

    var source: CaptureSuggestionSource
    var onBeforeChoosing: () -> Void

    @State private var isPresented = false

    private var resolved: Item? {
        guard let hint = draft.projectHint else { return nil }
        return (try? source.services?.capture.resolveContainer(named: hint)) ?? nil
    }

    private var isUnresolved: Bool { draft.projectHint != nil && resolved == nil }

    var body: some View {
        Button {
            onBeforeChoosing()
            isPresented = true
        } label: {
            Label(label, systemImage: symbolName)
                .font(Theme.Text.metadata)
                .foregroundStyle(isUnresolved ? Theme.Colors.unresolvedLink : Theme.Colors.secondaryText)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            isUnresolved
                ? "No project with this name — this will go to the Inbox"
                : "Where this will be filed"
        )
        .accessibilityIdentifier(AccessibilityID.QuickCapture.destinationButton)
        .accessibilityLabel("Filed under \(label)")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 0) {
                if draft.projectHint != nil {
                    Button {
                        draft.setProject(nil)
                        isPresented = false
                    } label: {
                        Label("Inbox", systemImage: "tray")
                            .font(Theme.Text.metadata)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.medium)
                    .padding(.top, Theme.Spacing.medium)
                }

                CaptureSearchPicker(
                    prompt: "Which project?",
                    symbolName: "square.stack.3d.up",
                    search: {
                        await source.titles(matching: $0, kinds: CaptureSuggestionSource.containerKinds)
                    }
                ) { title in
                    draft.setProject(title)
                    isPresented = false
                }
            }
        }
    }

    private var label: String {
        resolved?.title ?? draft.projectHint ?? "Inbox"
    }

    private var symbolName: String {
        if isUnresolved { return "questionmark.square.dashed" }
        return draft.projectHint == nil ? "tray" : "square.stack.3d.up"
    }
}
