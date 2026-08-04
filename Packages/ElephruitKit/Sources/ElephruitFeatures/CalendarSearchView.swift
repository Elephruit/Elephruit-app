import ElephruitCore
import ElephruitDesign
import ElephruitSearch
import SwiftUI

/// Searching the calendar.
///
/// ### Why this is a separate surface from the library's search
/// Because they are different questions with different vocabularies. `⌘F` in the library asks about
/// notes and tasks and understands `tag:` and `is:open`; this asks about meetings and understands
/// `with:`, `in:`, and "last year". Folding the two into one field with a scope switch would mean a
/// query language whose meaning changes depending on a segmented control most people never notice.
struct CalendarSearchView: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var results: CalendarSearchResults?
    @State private var isSearching = false
    @State private var selectedID: String?
    @FocusState private var isFieldFocused: Bool

    /// Debounces the query, so a burst of keystrokes runs one search rather than eight.
    @State private var searchTask: Task<Void, Never>?

    var onOpen: (IndexedEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            field
            Divider()
            body(for: results)
        }
        .frame(width: 560, height: 480)
        .onAppear { isFieldFocused = true }
        .accessibilityIdentifier(AccessibilityID.Calendar.search)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .accessibilityHidden(true)

                TextField("Search your calendar", text: $text)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.rowTitle)
                    .focused($isFieldFocused)
                    .onChange(of: text) { _, _ in scheduleSearch() }
                    .onSubmit { openFirst() }
                    .accessibilityIdentifier(AccessibilityID.Calendar.searchField)

                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }

            understood
        }
        .padding(Theme.Spacing.medium)
    }

    /// What the query was understood to mean, and what it was not.
    @ViewBuilder
    private var understood: some View {
        if let query = results?.query, !query.understoodTokens.isEmpty || !query.unrecognisedTokens.isEmpty {
            HStack(spacing: Theme.Spacing.tight) {
                ForEach(query.understoodTokens, id: \.value) { token in
                    HStack(spacing: 3) {
                        Text(token.label)
                            .font(Theme.Text.keyHint)
                            .foregroundStyle(Theme.Colors.tertiaryText)
                        Text(token.value)
                            .font(Theme.Text.keyHint)
                    }
                    .padding(.horizontal, Theme.Spacing.tight)
                    .padding(.vertical, Theme.Spacing.hairline)
                    .background { Capsule().fill(Theme.Colors.subtleFill) }
                }

                if !query.unrecognisedTokens.isEmpty {
                    Label(
                        "Not understood: \(query.unrecognisedTokens.joined(separator: ", "))",
                        systemImage: "questionmark.circle"
                    )
                    .font(Theme.Text.keyHint)
                    .foregroundStyle(Theme.Colors.warning)
                    .help("Silently ignoring part of a query gives results that look right and are not")
                }

                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
        } else if text.isEmpty {
            Text("Try “lunches last year”, “with:maya”, “in:austin”, or “without:notes”.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
        }
    }

    @ViewBuilder
    private func body(for results: CalendarSearchResults?) -> some View {
        if text.isEmpty {
            examples
        } else if let results, !results.isEmpty {
            list(results)
        } else if let results, !results.isIndexAvailable {
            EmptyStateView(
                symbolName: "exclamationmark.triangle",
                headline: "The calendar index is unavailable",
                message: "Rebuilding it from Settings ▸ Advanced usually fixes this.",
                tone: .noResults
            )
        } else if results != nil {
            EmptyStateView(
                symbolName: "magnifyingglass",
                headline: "Nothing matched",
                message: "Try fewer words, or a wider period.",
                tone: .noResults
            )
        } else {
            Color.clear
        }
    }

    private func list(_ results: CalendarSearchResults) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results.events) { event in
                    CalendarSearchRow(
                        event: event,
                        calendar: services?.calendar.displayCalendar ?? .current,
                        isSelected: selectedID == event.id
                    )
                    .contentShape(.rect)
                    .onTapGesture {
                        selectedID = event.id
                        onOpen(event)
                        dismiss()
                    }
                    .padding(.horizontal, Theme.Spacing.medium)
                }
            }
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    /// The queries worth knowing about, as buttons rather than as help text nobody reads.
    private var examples: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader("Try")

            ForEach(Self.examples, id: \.query) { example in
                Button {
                    text = example.query
                    scheduleSearch()
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        Text(example.query)
                            .font(Theme.Text.rowSubtitle)
                            .monospaced()
                        Text(example.meaning)
                            .font(Theme.Text.metadata)
                            .foregroundStyle(Theme.Colors.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverHighlight(extending: Theme.Spacing.small)
            }

            Spacer()
        }
        .padding(Theme.Spacing.medium)
    }

    private static let examples: [(query: String, meaning: String)] = [
        ("with:maya", "meetings with somebody"),
        ("lunches last year", "words, narrowed to a period"),
        ("in:austin", "events in a place"),
        ("calendar:work next month", "one calendar, one period"),
        ("without:notes", "events you never wrote anything about"),
        ("is:recurring", "everything that repeats"),
        ("project:\"Q3 Launch\"", "events filed under a project"),
    ]

    // MARK: Searching

    /// Runs the query a beat after typing stops.
    ///
    /// 180 ms: long enough that a typed word is one search rather than five, short enough that the
    /// results feel like they are following the typing rather than arriving afterwards.
    private func scheduleSearch() {
        searchTask?.cancel()
        guard !text.isEmpty else {
            results = nil
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        guard let services else { return }
        isSearching = true
        defer { isSearching = false }

        results = await services.calendarSearch.search(
            text,
            now: services.dateProvider.now,
            calendar: services.calendar.displayCalendar,
            limit: 200
        )
    }

    private func openFirst() {
        guard let first = results?.events.first else { return }
        onOpen(first)
        dismiss()
    }
}

/// One search result.
struct CalendarSearchRow: View {
    let event: IndexedEvent
    let calendar: Calendar
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(dayLabel)
                    .font(Theme.Text.metadata)
                    .monospacedDigit()
                    .rowForeground(.secondary)
                Text(yearLabel)
                    .font(Theme.Text.keyHint)
                    .rowForeground(.tertiary)
            }
            .frame(width: 74, alignment: .trailing)

            Capsule()
                .fill(Theme.EventStyle.accent(colorName: event.calendarColorName))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.displayTitle)
                    .font(Theme.Text.rowTitle)
                    .strikethrough(event.isCancelled)
                    .lineLimit(1)

                if let highlighted = event.highlightedSnippet {
                    HighlightedText(text: highlighted.text, matches: highlighted.matches)
                        .font(Theme.Text.metadata)
                        .lineLimit(2)
                }

                if let context = contextLine {
                    Text(context)
                        .font(Theme.Text.keyHint)
                        .rowForeground(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Spacing.tight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.Colors.selectionFill)
            }
        }
        .hoverHighlight(isEnabled: !isSelected, extending: Theme.Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    private var dayLabel: String {
        var style = Date.FormatStyle().day().month(.abbreviated)
        style.timeZone = calendar.timeZone
        return event.startAt.formatted(style)
    }

    private var yearLabel: String {
        var style = Date.FormatStyle().year()
        style.timeZone = calendar.timeZone
        return event.startAt.formatted(style)
    }

    private var contextLine: String? {
        var parts: [String] = []
        if let location = event.locationName, !location.isEmpty { parts.append(location) }
        if !event.attendeeNames.isEmpty { parts.append(event.attendeeNames.prefix(2).joined(separator: ", ")) }
        if !event.linkedNames.isEmpty { parts.append(event.linkedNames.prefix(2).joined(separator: ", ")) }
        if let name = event.calendarName { parts.append(name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityDescription: String {
        var parts = [event.displayTitle, dayLabel + " " + yearLabel]
        if let context = contextLine { parts.append(context) }
        return parts.joined(separator: ", ")
    }
}

/// Text with the matched runs emphasised.
///
/// Built from ranges rather than from markup, so nothing has to parse a string that came out of a
/// database — and so the emphasis is a font weight the design system chose rather than a colour that
/// might not survive dark mode.
struct HighlightedText: View {
    let text: String
    let matches: [Range<String.Index>]

    var body: some View {
        // Laid out as a run of styled pieces rather than concatenated `Text` values, which is
        // deprecated as of macOS 26 — and which, having tried it, wraps worse anyway: a concatenated
        // string breaks at the joins rather than at the words.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Text(segment.text)
                    .fontWeight(segment.isMatch ? .semibold : .regular)
                    .foregroundStyle(segment.isMatch ? Theme.Colors.primaryText : Theme.Colors.secondaryText)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var segments: [(text: String, isMatch: Bool)] {
        guard !matches.isEmpty else { return [(text, false)] }

        var result: [(String, Bool)] = []
        var cursor = text.startIndex

        for range in matches.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= cursor, range.upperBound <= text.endIndex else { continue }
            if cursor < range.lowerBound {
                result.append((String(text[cursor..<range.lowerBound]), false))
            }
            result.append((String(text[range]), true))
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            result.append((String(text[cursor...]), false))
        }
        return result.map { (text: $0.0, isMatch: $0.1) }
    }
}
