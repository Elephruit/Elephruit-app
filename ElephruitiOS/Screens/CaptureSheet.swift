import ElephruitCore
import ElephruitDesign
import ElephruitFeaturesCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// Quick capture: a sheet, a keyboard, one thumb.
///
/// The same grammar as everywhere else — `#tag @person >project !friday due: follow:` —
/// with the interpretation shown as chips while you type, suggestions for the token the
/// caret is inside, and the draft preserved across dismissal, interruption, and
/// backgrounding. Saving lands in the Inbox unless the text said otherwise; deciding
/// *where it goes* is never the price of writing it down.
struct CaptureSheet: View {
    @Environment(\.services) private var services
    @Environment(\.dismiss) private var dismiss

    /// The draft outlives the sheet: dismissal keeps it, backgrounding keeps it, and
    /// only Save or an explicit Discard clears it.
    @AppStorage("capture.draft.title") private var storedTitle = ""
    @AppStorage("capture.draft.notes") private var storedNotes = ""

    @State private var titleText = ""
    @State private var notesText = ""
    @State private var vocabulary = CaptureVocabulary.empty
    @State private var tagColors: [String: String] = [:]
    @State private var saveError: String?
    @State private var hasPrepared = false

    @FocusState private var focusedField: Field?

    private enum Field { case title, notes }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                TextField("What's on your mind?", text: $titleText, axis: .vertical)
                    .font(Theme.Text.title)
                    .lineLimit(1...4)
                    .focused($focusedField, equals: .title)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("capture.title")

                TextField("Notes", text: $notesText, axis: .vertical)
                    .font(Theme.Text.editorBody)
                    .lineLimit(2...8)
                    .focused($focusedField, equals: .notes)
                    .accessibilityIdentifier("capture.notes")

                chipRow
                suggestionRow

                Spacer(minLength: 0)

                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle")
                        .font(Theme.Text.metadata)
                        .foregroundStyle(Theme.Colors.warning)
                }

                grammarHints
            }
            .padding(Theme.Spacing.large)
            .navigationTitle("Capture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        stash()
                        dismiss()
                    }
                    .accessibilityHint("Keeps the draft for next time")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !isEmpty {
                        Button("Discard", role: .destructive) {
                            clear()
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isEmpty)
                        .accessibilityIdentifier("capture.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Interactive dismissal must not lose the draft — it is stashed, not dropped.
        .onDisappear(perform: stash)
        .task { prepare() }
        .tint(Theme.Colors.captureAccent)
    }

    // MARK: - Interpretation

    private var draft: CaptureDraft {
        CaptureParser.parse(composedText, knowing: vocabulary)
    }

    private var composedText: String {
        notesText.isEmpty ? titleText : titleText + "\n" + notesText
    }

    private var isEmpty: Bool {
        titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && notesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the parser understood, as chips: kind, destination, people, tags, dates.
    @ViewBuilder
    private var chipRow: some View {
        let parsed = draft
        if !isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.tight) {
                    captureChip(parsed.kind.displayName, symbol: parsed.kind.symbolName)

                    if let project = parsed.projectHint {
                        captureChip(project, symbol: "square.stack.3d.up")
                    }
                    ForEach(parsed.personHints, id: \.self) { person in
                        captureChip(person, symbol: "person")
                    }
                    ForEach(parsed.tagSlugs, id: \.self) { slug in
                        captureChip("#\(slug)", symbol: nil, colorName: tagColors[slug])
                    }
                    if let interpretation = parsed.dueInterpretation,
                        let services,
                        let day = interpretation.day.resolve(using: services.dateProvider) {
                        captureChip(
                            "Due \(RelativeDay.text(for: day, using: services.dateProvider))",
                            symbol: "flag.checkered"
                        )
                    }
                    if let priority = parsed.priority, priority != .normal {
                        captureChip(priority.displayName, symbol: priority.symbolName)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Understood as: \(parsed.kind.displayName)")
        }
    }

    private func captureChip(_ text: String, symbol: String?, colorName: String? = nil) -> some View {
        HStack(spacing: Theme.Spacing.hairline) {
            if let symbol {
                Image(systemName: symbol)
            }
            Text(text)
        }
        .font(Theme.Text.chip)
        .foregroundStyle(
            colorName != nil ? Theme.Palette.color(named: colorName) : Theme.Colors.captureAccent
        )
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.tight)
        .background(
            (colorName != nil ? Theme.Palette.color(named: colorName) : Theme.Colors.captureAccent)
                .opacity(0.14),
            in: Capsule()
        )
    }

    /// Suggestions for the token being typed — same source as every other capture door.
    @ViewBuilder
    private var suggestionRow: some View {
        if let completion = CaptureCompletion.active(in: titleText, caretAt: titleText.count) {
            let source = CaptureSuggestionSource(services: services, vocabulary: vocabulary)
            let suggestions: [String] = {
                switch completion.trigger {
                case .tag: source.tagSlugs(matching: completion.query, limit: 6)
                case .person: source.people(matching: completion.query, limit: 6)
                case .project: source.containers(matching: completion.query, limit: 6)
                // Dates complete by being typed, not by being listed — `!fri` needs a
                // parser, not a directory.
                case .bang, .dueDate, .followDate: []
                }
            }()

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.tight) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                titleText = completion.applying(
                                    suggestion, to: titleText, caretAt: titleText.count
                                ).text
                            } label: {
                                Text(suggestion)
                                    .font(Theme.Text.chip)
                                    .padding(.horizontal, Theme.Spacing.small)
                                    .padding(.vertical, Theme.Spacing.tight)
                                    .background(Theme.Colors.subtleFill, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var grammarHints: some View {
        CaptureGrammarHints(hints: CaptureParser.grammarHints)
    }

    // MARK: - Lifecycle

    private func prepare() {
        guard !hasPrepared else { return }
        hasPrepared = true
        titleText = storedTitle
        notesText = storedNotes
        focusedField = .title

        guard let services else { return }
        vocabulary = (try? services.capture.vocabulary()) ?? .empty
        tagColors = Dictionary(
            ((try? services.tags.allTags()) ?? []).compactMap { tag in
                tag.colorName.map { (tag.slug, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func stash() {
        storedTitle = titleText
        storedNotes = notesText
    }

    private func clear() {
        titleText = ""
        notesText = ""
        storedTitle = ""
        storedNotes = ""
        saveError = nil
    }

    private func save() {
        guard let services, !isEmpty else { return }
        saveError = nil
        do {
            _ = try services.captureText(composedText)
            // Cleared only after the save succeeded — the contract every capture door keeps.
            clear()
            dismiss()
        } catch {
            saveError = error.summary
        }
    }
}
