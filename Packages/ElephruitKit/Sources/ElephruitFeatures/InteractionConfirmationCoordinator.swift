import ElephruitCore
import ElephruitIntegrations
import ElephruitModel
import ElephruitPersistence
import Foundation
import Observation
import SwiftUI

/// Starts communications, listens for whatever comes back, and asks the user when nothing does.
///
/// ### Why the asking is a coordinator and not a view
/// The question — *did you send that?* — belongs to a moment that no single view owns. The user
/// pressed Email on somebody's page, went to Mail, came back, and may now be looking at the Inbox.
/// A prompt owned by the person's page would never appear; one owned by every view would appear
/// several times.
///
/// So one object holds the outstanding question, one place decides whether it is worth asking, and
/// the shell shows it wherever the user happens to be. The decision itself is
/// ``ElephruitCore/CommunicationIntent/shouldAskForConfirmation(now:minimumInterval:)``, which is a
/// pure function and tested as one.
///
/// ### Why it will not nag
/// A dismissal is permanent, a deferral buys exactly one more ask, and nothing is ever asked twice
/// within five minutes. Those bounds live on the intent rather than in this object's memory,
/// so they survive a relaunch — an app that forgets it already asked is an app that asks forever.
@Observable
@MainActor
public final class InteractionConfirmationCoordinator {
    private let communications: CommunicationService
    private let launcher: any CommunicationLaunching
    private let dateProvider: any DateProvider

    /// The question currently worth putting, or `nil` when there is none.
    public private(set) var pendingQuestion: CommunicationIntent?

    /// The communication whose outcome the user is being asked to record — a call that was placed
    /// and whose result only they can know.
    public private(set) var pendingCallOutcome: CommunicationIntent?

    /// The most recent launch, so a view can show what was handed off without re-fetching it.
    public private(set) var lastLaunch: CommunicationIntent?

    @ObservationIgnored private var observation: Task<Void, Never>?

    public init(
        communications: CommunicationService,
        launcher: any CommunicationLaunching,
        dateProvider: any DateProvider
    ) {
        self.communications = communications
        self.launcher = launcher
        self.dateProvider = dateProvider
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Listening

    /// Begins consuming launcher reports. Called once, by the shell.
    ///
    /// Idempotent: a second call while the first is still running is ignored rather than starting a
    /// second consumer of a stream that only supports one.
    public func beginObserving() {
        guard observation == nil else { return }

        observation = Task { [weak self] in
            guard let stream = self?.launcher.reports else { return }
            for await report in stream {
                guard let self else { return }
                self.receive(report)
            }
        }
    }

    public func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    /// Applies a report from the launcher.
    ///
    /// Failures are logged rather than surfaced. A share callback that could not be written down is
    /// a lost piece of evidence, not something the user did — putting an alert in front of somebody
    /// who has just closed a compose window would be blaming them for the app's bookkeeping.
    func receive(_ report: CommunicationLaunchReport) {
        do {
            if let record = try communications.record(report) {
                lastLaunch = record.asValue()
            }
        } catch {
            Diagnostics.features.error(
                "A communication report could not be recorded: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Starting one

    /// Prepares an intent, hands it to the launcher, and records what came back.
    ///
    /// The three steps are one call because doing two of them is always a bug: an intent with no
    /// launch is a draft nobody asked for, and a launch with no intent is the timeline entry this
    /// module exists to prevent.
    ///
    /// Returns the intent as it stands after the handoff — ``CommunicationState/composerOpened`` in
    /// the ordinary case — or `nil` when nothing could be written down.
    @discardableResult
    public func start(
        channel: CommunicationChannel,
        people: [Item],
        recipients: [CommunicationRecipient],
        subject: String? = nil,
        body: String? = nil,
        attachments: [CommunicationAttachmentReference] = [],
        attachmentURLs: [URL] = [],
        source: CommunicationSourceContext = .none
    ) -> CommunicationIntent? {
        do {
            let record = try communications.prepare(
                channel: channel,
                people: people,
                recipients: recipients,
                subject: subject,
                body: body,
                attachments: attachments,
                source: source
            )

            let report = launcher.launch(
                CommunicationLaunchRequest(
                    id: record.id,
                    channel: channel,
                    recipients: recipients,
                    subject: subject,
                    body: body,
                    attachmentURLs: attachmentURLs,
                    preferredMechanism: launcher.mechanism(for: channel)
                )
            )

            // The record is corrected from what the launcher actually did — including the mechanism,
            // which decides what can ever be known about this message. That correction belongs to the
            // service rather than here; see `CommunicationService.record(_:)`.
            try communications.record(report)

            let value = record.asValue()
            lastLaunch = value

            if channel == .phoneCall || channel == .facetimeVideo || channel == .facetimeAudio,
               case .composerOpened = report.outcome {
                pendingCallOutcome = value
            }

            refreshPendingQuestion()
            return value
        } catch {
            Diagnostics.features.error(
                "A communication could not be started: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Asking

    /// Re-reads whether there is a question worth putting.
    ///
    /// Called when the app comes back to the front, which is the only moment the question makes
    /// sense: the user has just been in Mail or Messages, and they either sent it or they did not.
    public func refreshPendingQuestion() {
        do {
            guard let next = try communications.pendingConfirmations(limit: 1).first else {
                pendingQuestion = nil
                return
            }

            // Asking is itself recorded, so that a question put and left unanswered counts against
            // the two-ask budget rather than being asked afresh on every return to the app.
            try communications.markAsked(next)
            pendingQuestion = next.asValue()
        } catch {
            Diagnostics.features.error(
                "Pending communications could not be read: \(String(describing: error), privacy: .public)"
            )
            pendingQuestion = nil
        }
    }

    /// Records the user's answer and clears the question.
    public func answer(_ confirmation: CommunicationService.Confirmation) {
        guard let question = pendingQuestion else { return }
        pendingQuestion = nil

        do {
            guard let record = try communications.record(id: question.id) else { return }
            try communications.confirm(confirmation, for: record)
        } catch {
            Diagnostics.features.error(
                "A communication confirmation could not be recorded: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Puts the question aside for now without recording anything about it.
    ///
    /// Distinct from ``CommunicationService/Confirmation/dismissed``: this closes the prompt on
    /// screen, and the intent's own ask budget decides whether it ever comes back.
    public func setQuestionAside() {
        pendingQuestion = nil
    }

    // MARK: - Calls

    /// Records how a call went, on the user's word alone.
    public func logCall(_ outcome: CallOutcome, duration: TimeInterval? = nil, notes: String = "") {
        guard let pending = pendingCallOutcome else { return }
        pendingCallOutcome = nil

        do {
            guard let record = try communications.record(id: pending.id) else { return }
            try communications.logCall(outcome, for: record, duration: duration, notes: notes)
        } catch {
            Diagnostics.features.error(
                "A call outcome could not be recorded: \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func dismissCallOutcome() {
        pendingCallOutcome = nil
    }
}
