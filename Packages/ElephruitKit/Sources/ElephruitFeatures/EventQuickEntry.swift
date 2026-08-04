import AppKit
import ElephruitCore
import ElephruitDesign
import SwiftUI

/// The state behind the natural-language field.
///
/// ### Raw text and parsed state are kept apart, deliberately and completely
/// The field owns a `String`. This owns an interpretation *derived* from that string. Nothing here
/// ever writes back into the text, and the field never reads the interpretation — which is what
/// makes it impossible for parsing to disturb a space, a paste, an undo step, a selection, a caret
/// position, or an input method's marked text.
///
/// That is not a stylistic preference. Every one of those failures is what happens when a field
/// "helpfully" rewrites what somebody is typing: a Japanese or Chinese user loses their composition
/// mid-word, a paste is re-tokenised and reordered, and undo has to be pressed twice.
///
/// Corrections made in the chips are held here as **overrides**, applied *after* each parse. So
/// typing more text re-parses everything and keeps the correction, and clearing a correction returns
/// to what the text says.
///
/// ### Where this rule stops
/// Quick Jot does write back — see ``CaptureLift``, which takes a settled `due:friday` out of the
/// sentence and turns it into a chip. That is not a disagreement with the paragraphs above; the two
/// surfaces are doing different jobs with what somebody typed.
///
/// Here the parse is **advisory**. The text is the record — "Lunch with Sam Thursday 1pm" is what the
/// user wrote and what they will recognise — and the interpretation is a reading of it. Dismissing a
/// chip leaves the words alone on purpose, because nobody asked for their sentence to be edited.
///
/// In Quick Jot the parse is **constitutive**. The sigils are instructions and the title is what
/// remains once they have been obeyed; `due:friday` is not part of anybody's sentence. Leaving it in
/// the title of an item that now has a deadline shows the same fact twice and makes the duplicate the
/// user's to clean up.
///
/// The distinction is which of the two the user will later want to read back. It is not a licence to
/// rewrite a field in general, and the guards there are the ones described above, kept in full.
@Observable
@MainActor
public final class EventQuickEntryModel {
    /// What the user typed. Written only by the field.
    public var text: String = "" {
        didSet { reparse() }
    }

    /// What the app understood. Written only by ``reparse()``.
    public private(set) var interpretation = EventPhraseInterpretation()

    /// Fields the user corrected by hand, which a re-parse must not undo.
    public private(set) var overrides = Overrides()

    /// A correction made in the interpretation chips.
    public struct Overrides: Sendable, Hashable {
        public var calendarIdentifier: String?
        public var startAt: Date?
        public var durationMinutes: Int?
        public var isAllDay: Bool?

        /// Set when the user removed a chip, so a re-parse does not put it back.
        public var suppressedKinds: Set<EventPhraseToken.Kind> = []

        public var isEmpty: Bool {
            calendarIdentifier == nil && startAt == nil && durationMinutes == nil
                && isAllDay == nil && suppressedKinds.isEmpty
        }

        public init() {}
    }

    private let dateProvider: any DateProvider
    private var context: EventPhraseContext

    public init(dateProvider: any DateProvider, context: EventPhraseContext = .empty) {
        self.dateProvider = dateProvider
        self.context = context
    }

    /// Updates what the parser is allowed to recognise, and re-reads the current text.
    public func updateContext(_ context: EventPhraseContext) {
        self.context = context
        reparse()
    }

    private func reparse() {
        var parsed = EventPhraseParser.parse(text, context: context, calendar: dateProvider.calendar)

        for kind in overrides.suppressedKinds {
            parsed.tokens.removeAll { $0.kind == kind }
            switch kind {
            case .recurrence: parsed.recurrence = nil
            case .location: parsed.location = nil
            case .calendar: parsed.calendarName = nil
            case .person: parsed.personID = nil; parsed.personName = nil
            case .timeZone: parsed.timeZoneIdentifier = nil
            case .alarm: parsed.alarmMinutesBefore = nil
            case .duration: parsed.durationMinutes = nil
            case .date, .dateRange: parsed.day = nil; parsed.endDay = nil
            case .time, .endTime: parsed.time = nil; parsed.endTime = nil
            }
        }

        interpretation = parsed
    }

    // MARK: Corrections

    public func setCalendar(_ identifier: String?) {
        overrides.calendarIdentifier = identifier
    }

    public func setStart(_ date: Date?) {
        overrides.startAt = date
    }

    public func setDuration(minutes: Int?) {
        overrides.durationMinutes = minutes
    }

    public func setAllDay(_ isAllDay: Bool?) {
        overrides.isAllDay = isAllDay
    }

    /// Removes something the parser found. The words stay in the field; only the reading changes.
    public func remove(kind: EventPhraseToken.Kind) {
        overrides.suppressedKinds.insert(kind)
        reparse()
    }

    public func clearOverrides() {
        overrides = Overrides()
        reparse()
    }

    public func reset() {
        overrides = Overrides()
        text = ""
    }

    // MARK: Result

    /// The draft this would produce, with corrections applied.
    public func draft(defaultCalendarIdentifier: String, calendars: [CalendarInfo]) -> EventDraft? {
        guard interpretation.isUsable else { return nil }

        guard var draft = interpretation.draft(
            defaultCalendarIdentifier: overrides.calendarIdentifier ?? defaultCalendarIdentifier,
            calendars: calendars,
            dateProvider: dateProvider,
            defaultDurationMinutes: context.defaultDurationMinutes
        ) else { return nil }

        // Overrides land last, so a correction always wins over the text it disagrees with.
        if let identifier = overrides.calendarIdentifier { draft.calendarIdentifier = identifier }
        if let start = overrides.startAt { draft.move(to: start) }
        if let minutes = overrides.durationMinutes { draft.setDuration(TimeInterval(minutes * 60)) }
        if let isAllDay = overrides.isAllDay { draft.isAllDay = isAllDay }

        return draft
    }

    /// A sentence describing what will be created, shown under the field.
    public func summary(calendars: [CalendarInfo], defaultCalendarIdentifier: String) -> String? {
        guard let draft = draft(
            defaultCalendarIdentifier: defaultCalendarIdentifier, calendars: calendars
        ) else { return nil }

        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = dateProvider.calendar.timeZone
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = dateProvider.calendar.timeZone

        var parts = [draft.title.isEmpty ? "Untitled event" : draft.title]
        if draft.isAllDay {
            parts.append("all day on \(draft.startAt.formatted(style))")
        } else {
            parts.append("\(draft.startAt.formatted(style)) at \(draft.startAt.formatted(timeStyle))")
            parts.append("for \(EventAlarm.durationPhrase(Int(draft.duration / 60)))")
        }
        if let name = calendars.first(where: { $0.id == draft.calendarIdentifier })?.title {
            parts.append("on \(name)")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The field

/// The quick-entry panel: one line of typing, and what was understood beneath it.
struct EventQuickEntryView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var model: EventQuickEntryModel
    @State private var isSaving = false
    @State private var failure: CalendarWriteFailure?
    @FocusState private var isFocused: Bool

    /// The day a drag or a click started on, so a new event lands where the user pointed.
    let suggestedStart: Date?

    var onCreated: (CalendarEventSummary) -> Void

    /// Opening the full editor with whatever has been understood so far.
    var onOpenEditor: (EventDraft) -> Void

    init(
        dateProvider: any DateProvider,
        suggestedStart: Date? = nil,
        onCreated: @escaping (CalendarEventSummary) -> Void,
        onOpenEditor: @escaping (EventDraft) -> Void
    ) {
        self._model = State(initialValue: EventQuickEntryModel(dateProvider: dateProvider))
        self.suggestedStart = suggestedStart
        self.onCreated = onCreated
        self.onOpenEditor = onOpenEditor
    }

    private var calendars: [CalendarInfo] {
        services?.calendar.calendars.filter { $0.allowsModification } ?? []
    }

    private var defaultCalendarIdentifier: String {
        services?.calendar.defaultCalendarIdentifier ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            field
            tokens
            summary
            actions
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 520)
        .onAppear {
            isFocused = true
            model.updateContext(makeContext())
            if let suggestedStart { model.setStart(suggestedStart) }
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.quickEntry)
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "calendar.badge.plus")
                .foregroundStyle(Theme.Colors.secondaryText)
                .accessibilityHidden(true)

            PlainEventEntryField(
                text: $model.text,
                highlights: model.interpretation.tokens.map(\.range),
                onSubmit: { Task { await save() } },
                onCancel: { dismiss() }
            )
            .frame(height: 24)
            .focused($isFocused)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Colors.subtleFill)
        }
        .accessibilityIdentifier(AccessibilityID.Calendar.quickEntryField)
    }

    /// What was understood, as chips that can be corrected or removed.
    @ViewBuilder
    private var tokens: some View {
        if !model.interpretation.tokens.isEmpty || model.overrides.calendarIdentifier != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.tight) { chips }
                VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                    HStack(spacing: Theme.Spacing.tight) { chips }
                }
            }
            .accessibilityIdentifier(AccessibilityID.Calendar.quickEntryTokens)
        }
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(model.interpretation.tokens) { token in
            InterpretationChip(token: token) {
                model.remove(kind: token.kind)
            }
        }

        calendarChip
    }

    /// The calendar chip is always shown, even when the phrase said nothing about one.
    ///
    /// Where an event lands is the decision people most often get wrong and least often check, and
    /// an absent chip reads as "no calendar" rather than "the default one".
    @ViewBuilder
    private var calendarChip: some View {
        if let identifier = model.overrides.calendarIdentifier ?? resolvedCalendarIdentifier,
           let calendar = calendars.first(where: { $0.id == identifier }) {
            Menu {
                ForEach(calendars) { option in
                    Button(option.title) { model.setCalendar(option.id) }
                }
            } label: {
                HStack(spacing: 3) {
                    Circle()
                        .fill(Theme.EventStyle.accent(colorName: calendar.colorName))
                        .frame(width: 7, height: 7)
                    Text(calendar.title)
                        .font(Theme.Text.keyHint)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Which calendar this lands on")
            .accessibilityLabel("Calendar: \(calendar.title)")
        }
    }

    private var resolvedCalendarIdentifier: String? {
        model.interpretation.resolvedCalendar(among: calendars)?.id ?? defaultCalendarIdentifier
    }

    @ViewBuilder
    private var summary: some View {
        if let text = model.summary(
            calendars: calendars, defaultCalendarIdentifier: defaultCalendarIdentifier
        ) {
            Text(text)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Will create: \(text)")
        } else if !model.text.isEmpty {
            Text("Keep typing — a title is enough.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        } else {
            Text("Try “Lunch with Maya tomorrow at noon”.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }

        if let failure {
            Text(failure.message)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.destructive)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.small) {
            if !model.overrides.isEmpty {
                Button("Reset corrections") { model.clearOverrides() }
                    .buttonStyle(.borderless)
                    .font(Theme.Text.metadata)
            }

            Spacer()

            Button("More…") {
                guard let draft = model.draft(
                    defaultCalendarIdentifier: defaultCalendarIdentifier, calendars: calendars
                ) else { return }
                onOpenEditor(draft)
                dismiss()
            }
            .buttonStyle(.borderless)
            .disabled(!model.interpretation.isUsable)
            .help("Open the full editor with what has been understood so far")

            Button("Add") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || !model.interpretation.isUsable)
        }
    }

    private func makeContext() -> EventPhraseContext {
        guard let services else { return .empty }

        let people = (try? services.persons.allPeople(includingPlaceholders: false))?.compactMap { person -> KnownPerson? in
            guard let profile = person.personProfile else {
                return KnownPerson(id: person.id, fullName: person.displayTitle)
            }
            return KnownPerson(
                id: person.id,
                fullName: profile.fullName.isEmpty ? person.displayTitle : profile.fullName,
                aliases: [profile.nickname].compactMap { $0 }
            )
        } ?? []

        return EventPhraseContext(
            people: people,
            calendarNames: calendars.map(\.title),
            timeZoneIdentifiers: services.calendar.timeZoneDisplay.favouriteZoneIdentifiers
        )
    }

    private func save() async {
        guard let services else { return }
        guard let draft = model.draft(
            defaultCalendarIdentifier: defaultCalendarIdentifier, calendars: calendars
        ) else { return }

        isSaving = true
        defer { isSaving = false }
        failure = nil

        switch await services.calendar.create(draft) {
        case .success(let event):
            // The person the phrase named is linked *locally*, never written into the event — which
            // is the whole difference between a CRM and a calendar entry other people can read.
            if let personID = model.interpretation.personID,
               let person = try? services.items.item(id: personID) {
                services.perform { try services.eventLinks.link(person: person, to: event) }
            }
            onCreated(event)
            dismiss()

        case .failure(let error):
            failure = error
        }
    }
}

/// One thing the parser understood, as a removable chip.
private struct InterpretationChip: View {
    let token: EventPhraseToken
    var onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: token.kind.symbolName)
                .font(Theme.Text.denseLabel)
                .accessibilityHidden(true)

            Text(token.text)
                .font(Theme.Text.keyHint)
                .lineLimit(1)

            if isHovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(Theme.Text.denseLabel)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ignore \(token.kind.displayLabel)")
            }
        }
        .padding(.horizontal, Theme.Spacing.tight)
        .padding(.vertical, 2)
        .background {
            Capsule().fill(Theme.Colors.subtleFill)
        }
        .onHover { isHovering = $0 }
        .help("\(token.kind.displayLabel): \(token.text) — click the cross to ignore it")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(token.kind.displayLabel): \(token.text)")
    }
}

// MARK: - The text field

/// A single-line field that never has its contents rewritten.
///
/// ### Why this is not `TextField`
/// It is not that `TextField` is wrong; it is that this field has to guarantee something SwiftUI's
/// binding cannot express. A `@Binding<String>` round-trips: SwiftUI may write the value back into
/// the view, and when it does it resets the caret, discards marked text, and adds an undo step. That
/// is invisible in English and catastrophic in Japanese, where a word being composed disappears
/// mid-keystroke.
///
/// So the text flows one way only. The view reads `text` once, at creation, and afterwards only ever
/// *reports* what the user typed. ``updateNSView(_:context:)`` writes back to the text view in
/// exactly one case — when the model's text has been changed by something other than typing, which
/// is only ``EventQuickEntryModel/reset()`` — and even then it refuses while an input method is
/// composing.
struct PlainEventEntryField: NSViewRepresentable {
    @Binding var text: String

    /// Character ranges the parser recognised, for the underline.
    let highlights: [Range<Int>]

    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isFieldEditor = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        // Straight quotes and no substitutions: the parser is looking for the characters somebody
        // typed, and a smart dash is not the one it matches.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 3)

        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        context.coordinator.parent = self
        applyHighlights(to: textView)

        // The one case a write-back is legitimate: the model was reset from outside. Anything else —
        // and in particular anything derived from parsing — must not touch the text.
        guard textView.string != text, !context.coordinator.isEditing else { return }

        // Never while an input method is composing. Replacing the string mid-composition destroys
        // the marked text and the user's word with it.
        guard !textView.hasMarkedText() else { return }

        textView.string = text
    }

    /// Underlines what the parser understood, without changing a character of what was typed.
    ///
    /// A temporary attribute rather than an edit to the storage: attributes are presentation, they
    /// carry no undo step, and they cannot desynchronise the string from the model.
    private func applyHighlights(to textView: NSTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length

        layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: NSRange(location: 0, length: length))
        layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: NSRange(location: 0, length: length))

        for range in highlights {
            // Clamped, because the ranges came from a parse of a string that may already have moved
            // on by a keystroke, and an out-of-bounds attribute range is a crash rather than a
            // cosmetic error.
            let location = min(max(0, range.lowerBound), length)
            let extent = min(range.count, length - location)
            guard extent > 0 else { continue }

            let nsRange = NSRange(location: location, length: extent)
            layoutManager.addTemporaryAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue,
                    .underlineColor: NSColor.tertiaryLabelColor,
                ],
                forCharacterRange: nsRange
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainEventEntryField

        /// Set while the user is typing, so `updateNSView` never writes back during an edit.
        var isEditing = false

        init(_ parent: PlainEventEntryField) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Not while composing: the marked text is provisional, and parsing a half-formed word
            // produces chips that flicker and a title that is briefly wrong.
            guard !textView.hasMarkedText() else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    /// Reports Return even when the field editor would otherwise swallow it.
    final class SubmittingTextView: NSTextView {
        weak var coordinator: Coordinator?

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: 24)
        }
    }
}
