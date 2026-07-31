import ElephruitCore
import ElephruitDesign
import ElephruitModel
import ElephruitPersistence
import SwiftUI

// MARK: - Starting one, from what a view already has

extension InteractionConfirmationCoordinator {
    /// Reaches one person at one destination.
    ///
    /// The bridge between what the interface holds — a person and a chosen
    /// ``ElephruitCore/ContactDestination`` — and what the tracking layer needs. Returns `nil` for a
    /// channel that reaches nobody, because a map is not a communication and giving it an intent
    /// would put "Maps composer opened" in somebody's timeline.
    @discardableResult
    func start(
        contactChannel: ContactChannel,
        person: Item,
        destination: ContactDestination,
        source: CommunicationSourceContext = .none
    ) -> CommunicationIntent? {
        guard let channel = CommunicationChannel(contactChannel: contactChannel) else { return nil }

        return start(
            channel: channel,
            people: [person],
            recipients: [
                CommunicationRecipient(
                    handle: destination.value,
                    personID: person.id,
                    displayName: person.displayTitle
                )
            ],
            source: source
        )
    }

    /// Reaches everybody a group action would reach.
    ///
    /// The blind-copy decision is the group service's, and is carried through rather than re-made:
    /// a group email that discloses everyone's address to everyone else is a privacy failure, and
    /// having two places decide it is how the two come to disagree.
    @discardableResult
    func start(
        groupAction: GroupAction,
        preview: GroupActionPreview,
        people: [Item],
        source: CommunicationSourceContext = .none
    ) -> CommunicationIntent? {
        let channel: CommunicationChannel
        switch groupAction {
        case .email, .invite: channel = .email
        case .message: channel = .message
        case .tag, .export: return nil
        }

        let recipients = preview.recipients.map { recipient in
            CommunicationRecipient(
                handle: recipient.destination,
                personID: recipient.id,
                displayName: recipient.name,
                isBlindCopy: preview.usesBlindCopy
            )
        }
        guard !recipients.isEmpty else { return nil }

        return start(channel: channel, people: people, recipients: recipients, source: source)
    }
}

// MARK: - The question

/// "Did you send this message to Maya?", and the five honest answers to it.
///
/// ### Why this is a bar and not an alert
/// An alert stops the user to demand an answer about something they may have deliberately
/// abandoned. This is a strip they can answer, ignore, or wave away — which matches how much the
/// app actually needs to know. The whole feature is a convenience for the user's memory; behaving as
/// though it were urgent would make it a nuisance instead.
struct CommunicationConfirmationBar: View {
    let intent: CommunicationIntent
    let onAnswer: (CommunicationService.Confirmation) -> Void
    let onSetAside: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Image(systemName: intent.channel.symbolName)
                .foregroundStyle(Theme.Colors.secondaryText)

            VStack(alignment: .leading, spacing: Theme.Spacing.hairline) {
                Text(intent.confirmationQuestion())
                    .font(Theme.Text.rowTitle)

                Text(CommunicationStatusLabel.make(for: intent).sentence)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(2)
            }

            Spacer(minLength: Theme.Spacing.medium)

            Button("Sent") { onAnswer(.sent) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            Button("Not sent") { onAnswer(.notSent) }
                .controlSize(.small)

            Button("Still working on it") { onAnswer(.stillWorkingOnIt) }
                .controlSize(.small)

            Button {
                onAnswer(.dismissed)
            } label: {
                Image(systemName: "xmark")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("Stop asking about this one")
            .accessibilityLabel("Stop asking about this one")
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.small)
        .background(.regularMaterial)
        .accessibilityIdentifier(AccessibilityID.Communications.confirmationBar)
        .onExitCommand(perform: onSetAside)
    }
}

// MARK: - Calls

/// What happened on the call, asked afterwards because there is no other way to know.
///
/// Every field here is the user's testimony. macOS reports nothing to this app about a call it did
/// not place itself — not whether it connected, not for how long — so the sheet asks, records what
/// it is told, and the timeline says "confirmed manually".
struct CallOutcomeSheet: View {
    let intent: CommunicationIntent
    let personName: String?
    let onLog: (CallOutcome, TimeInterval?, String) -> Void
    let onDismiss: () -> Void

    @State private var outcome: CallOutcome = .connected
    @State private var minutes = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(title)
                .font(Theme.Text.title)

            Text("Elephruit opened \(intent.channel.handoffNoun) and knows nothing more than that.")
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                Picker("How did it go", selection: $outcome) {
                    ForEach(CallOutcome.allCases) { option in
                        Label(option.displayName, systemImage: option.symbolName).tag(option)
                    }
                }

                if outcome.countsAsContact {
                    TextField("Minutes (optional)", text: $minutes)
                }

                if outcome != .canceled {
                    TextField("What was said (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...5)
                }
            }
            .formStyle(.grouped)

            if !outcome.countsAsContact, outcome != .canceled {
                Label(
                    "This is recorded, and it does not count as having spoken.",
                    systemImage: "info.circle"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Not now", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Log it") {
                    onLog(outcome, duration, notes.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.section)
        .frame(width: 420)
        .accessibilityIdentifier(AccessibilityID.Communications.callOutcomeSheet)
    }

    private var title: String {
        guard let personName, !personName.isEmpty else { return "Log this call?" }
        return "Log a \(intent.channel.noun.lowercased()) with \(personName)?"
    }

    /// Minutes as seconds, or nothing. A field that will not parse is a field the user left in a
    /// state they did not mean, and inventing a duration from it would be worse than having none.
    private var duration: TimeInterval? {
        guard let value = Double(minutes.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return value * 60
    }
}

// MARK: - Status

/// One line saying what is known about a message, and how it is known.
///
/// The headline and the evidence are drawn differently on purpose: "Email sent" is the fact and
/// "confirmed by you" is who says so, and a row that ran them together in one weight would read as
/// though the app had established both.
struct CommunicationStatusLine: View {
    let label: CommunicationStatusLabel

    var body: some View {
        HStack(spacing: Theme.Spacing.tight) {
            Image(systemName: label.symbolName)
                .font(Theme.Text.metadata)

            Text(label.headline)
                .font(Theme.Text.metadata)

            if let detail = label.detail {
                Text("·")
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)

                Text(detail)
                    .font(Theme.Text.metadata)
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .lineLimit(1)
            }
        }
        .rowForeground(label.needsAttention ? .primary : .secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.sentence)
    }
}

// MARK: - Privacy

/// What the app keeps of a message, and what each choice means, said before it is chosen.
public struct CommunicationPrivacySection: View {
    @Environment(\.services) private var services

    @State private var preference: CommunicationPrivacyPreference = .metadataOnly

    public init() {}

    public var body: some View {
        Section("Messages") {
            Picker("Keep", selection: $preference) {
                ForEach(CommunicationPrivacyPreference.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: preference) { _, newValue in
                services?.communications.privacyPreference = newValue
            }

            Text(preference.explanation)
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            if preference != .metadataOnly {
                Label(
                    """
                    This applies to messages recorded from now on. Anything already written keeps \
                    the setting it was written under.
                    """,
                    systemImage: "clock.arrow.circlepath"
                )
                .font(Theme.Text.metadata)
                .foregroundStyle(Theme.Colors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier(AccessibilityID.Communications.privacySection)
        .onAppear {
            preference = services?.communications.privacyPreference ?? .metadataOnly
        }
    }
}
