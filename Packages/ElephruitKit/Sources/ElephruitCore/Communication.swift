import Foundation

/// Reaching somebody through a channel the app hands off to another application.
///
/// ### Why this is not ``ContactChannel``
/// `ContactChannel` is *every* way of acting on a stored detail, and two of its cases — opening a map,
/// opening a website — are not communication at all. Nobody is on the other end of a map, so nothing
/// about sending, delivery, or confirmation applies to it, and folding it in here would mean every
/// state in ``CommunicationState`` had to carry a meaning for a case that can never reach any of them.
///
/// The five cases here are exactly the ones where a human being receives something, which is the set
/// for which "did it actually arrive" is a question worth being careful about.
public enum CommunicationChannel: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case email
    case message
    case phoneCall
    case facetimeVideo
    case facetimeAudio

    public var id: String { rawValue }

    /// The word a timeline row starts with — "Email sent", "Call logged".
    public var noun: String {
        switch self {
        case .email: "Email"
        case .message: "Message"
        case .phoneCall: "Call"
        case .facetimeVideo: "FaceTime"
        case .facetimeAudio: "FaceTime Audio"
        }
    }

    public var displayName: String { noun }

    /// The application macOS will hand this to, as the user knows it.
    ///
    /// Named rather than inferred, because "handed off to Mail" is a claim about where the message
    /// went and the user's default handler may not be Apple Mail at all — see ``handoffNoun``.
    public var appleAppName: String {
        switch self {
        case .email: "Mail"
        case .message: "Messages"
        case .phoneCall: "Phone"
        case .facetimeVideo, .facetimeAudio: "FaceTime"
        }
    }

    /// What to call the receiving application when the app does not know which one it is.
    ///
    /// A `mailto:` goes to whatever the user set as their mail handler. Saying "handed off to Mail"
    /// when it went to Outlook is a small lie with no upside, so the URL-scheme path says "your mail
    /// app" and only the sharing-service path, which addresses a named service, uses the app's name.
    public var handoffNoun: String {
        switch self {
        case .email: "your mail app"
        case .message: "your messages app"
        case .phoneCall: "your phone app"
        case .facetimeVideo, .facetimeAudio: "FaceTime"
        }
    }

    public var symbolName: String {
        switch self {
        case .email: "envelope"
        case .message: "message"
        case .phoneCall: "phone"
        case .facetimeVideo: "video"
        case .facetimeAudio: "phone.badge.waveform"
        }
    }

    /// Whether `NSSharingService` offers a composer for this channel.
    ///
    /// Only email and Messages. There is no sharing service that places a call, so calls and FaceTime
    /// are URL schemes and can never report more than "initiated" — see ``ContactActionURL``.
    public var hasSharingService: Bool {
        switch self {
        case .email, .message: true
        case .phoneCall, .facetimeVideo, .facetimeAudio: false
        }
    }

    /// Whether anything in the deployment SDK can tell this app that a message reached its recipient.
    ///
    /// **False for every channel, deliberately, and asserted by a test.** There is no supported
    /// macOS API that reports iMessage delivery or read receipts to a third-party app, and the mail
    /// provider APIs this design allows for report *submission*, not arrival. ``CommunicationState``
    /// models ``CommunicationState/delivered`` because the vocabulary needs a name for the thing the
    /// app is refusing to claim — not because anything here can produce it.
    public var canReportDelivery: Bool { false }

    /// Whether an email-style provider could ever verify a send for this channel.
    ///
    /// Email only. Messages has no equivalent, which is why a message never rises above
    /// ``CommunicationState/userConfirmedSent``.
    public var canBeProviderVerified: Bool { self == .email }

    /// The equivalent action on a stored contact detail.
    public var contactChannel: ContactChannel {
        switch self {
        case .email: .email
        case .message: .message
        case .phoneCall: .call
        case .facetimeVideo: .facetimeVideo
        case .facetimeAudio: .facetimeAudio
        }
    }

    /// The communication channel behind a contact action, or `nil` for the ones that reach nobody.
    public init?(contactChannel: ContactChannel) {
        switch contactChannel {
        case .email: self = .email
        case .message: self = .message
        case .call: self = .phoneCall
        case .facetimeVideo: self = .facetimeVideo
        case .facetimeAudio: self = .facetimeAudio
        case .maps, .web: return nil
        }
    }
}

// MARK: - State

/// How much is actually known about a communication.
///
/// ### The distinction this whole module exists to keep
/// The app can see that it asked macOS to open a composer. It cannot see whether a message was
/// written, whether the recipients were changed, whether Send was pressed, whether the server
/// accepted it, or whether anybody received it. Every one of those is a different fact, and merging
/// them into one word — "Sent" — produces a timeline that reads as evidence and is not.
///
/// So the states are separate, they are ordered by how strong a claim each makes, and a signal can
/// only ever move a record *up* that order. See ``CommunicationTransitionPolicy``.
public enum CommunicationState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Composed inside Elephruit; nothing has been handed anywhere.
    case draftPrepared

    /// An external composer was opened with the intended values filled in.
    case composerOpened

    /// `NSSharingService` reported that sharing finished. **Not** proof that anything was sent.
    case shareCompleted

    /// A provider accepted the message for delivery, or the user's mail app reported it queued.
    case submitted

    /// The user said they sent it.
    case userConfirmedSent

    /// A provider returned a successful submission or a matching sent-message record.
    case providerVerifiedSent

    /// A provider reported that the recipient received it.
    ///
    /// Nothing in this build can produce this. It exists so that the absence of delivery evidence is
    /// a *modelled* absence rather than an unnamed gap — see ``CommunicationChannel/canReportDelivery``.
    case delivered

    /// The send was attempted and did not succeed.
    case failed

    /// The user, or the composer, abandoned it.
    case canceled

    /// Handed off, and never resolved. The honest resting state for a URL-scheme launch the user
    /// never answered a question about.
    case unknown

    /// How strong a claim this state makes about the message having gone somewhere.
    ///
    /// The two negative outcomes claim nothing, so they sit at zero rather than at the top: a failure
    /// is not a stronger version of a success. Whether one may replace the other is decided by
    /// ``CommunicationTransitionPolicy``, which weighs the *evidence* as well as the claim.
    public var claimStrength: Int {
        switch self {
        case .unknown, .canceled, .failed: 0
        case .draftPrepared: 1
        case .composerOpened: 2
        case .shareCompleted: 3
        case .submitted: 4
        case .userConfirmedSent: 5
        case .providerVerifiedSent: 6
        case .delivered: 7
        }
    }

    /// Whether this state asserts that the message left the machine.
    ///
    /// The line between "we handed it over" and "it went". ``shareCompleted`` is deliberately below
    /// it: a sharing service reporting completion means the *service* finished, which happens whether
    /// or not the user pressed Send.
    public var claimsTheMessageLeft: Bool {
        switch self {
        case .submitted, .userConfirmedSent, .providerVerifiedSent, .delivered: true
        case .draftPrepared, .composerOpened, .shareCompleted, .failed, .canceled, .unknown: false
        }
    }

    /// Whether this asserts that somebody received it. ``delivered`` alone.
    public var claimsDelivery: Bool { self == .delivered }

    /// Whether there is still an open question worth asking the user.
    public var isSettled: Bool {
        switch self {
        case .userConfirmedSent, .providerVerifiedSent, .delivered, .failed, .canceled: true
        case .draftPrepared, .composerOpened, .shareCompleted, .submitted, .unknown: false
        }
    }

    /// Whether this counts as having reached out for the last-contact line.
    ///
    /// Only the states where somebody stated or verified that the message went. Opening a composer is
    /// not contact, and letting it count would make the one number the People module is trusted for
    /// quietly wrong — the same rule ``InteractionProvenance/countsAsContact`` already applies to a
    /// button press.
    public var countsAsReachingOut: Bool {
        switch self {
        case .userConfirmedSent, .providerVerifiedSent, .delivered: true
        case .draftPrepared, .composerOpened, .shareCompleted, .submitted, .failed, .canceled, .unknown: false
        }
    }
}

// MARK: - Evidence

/// Where a status came from.
///
/// Recorded on every transition, so a row can always answer "who says so". A status with no evidence
/// behind it is a status the app made up, and there is nowhere in this module for one to come from.
public enum CommunicationEvidence: String, Codable, Sendable, Hashable, CaseIterable {
    /// A delegate callback or a return value from a system framework.
    case systemCallback

    /// The user answered a question.
    case userConfirmation

    /// A provider API returned a record.
    case providerAPI

    /// Reconciled against a sent-message record the user authorised the app to read.
    case importedRecord

    /// The app worked it out. The weakest kind, and never enough on its own to claim a send.
    case inference

    /// How far this source is allowed to overrule another.
    ///
    /// A provider holds the actual record, so it outranks a person's recollection; a person watched
    /// themselves press Send, so they outrank a framework callback that only saw a sheet close.
    /// Inference outranks nothing.
    public var authority: Int {
        switch self {
        case .inference: 0
        case .systemCallback: 1
        case .userConfirmation: 2
        case .providerAPI, .importedRecord: 3
        }
    }

    public var displayName: String {
        switch self {
        case .systemCallback: "Reported by macOS"
        case .userConfirmation: "Confirmed by you"
        case .providerAPI: "Verified by your provider"
        case .importedRecord: "Matched to a sent message"
        case .inference: "Inferred"
        }
    }
}

// MARK: - Launch mechanism

/// How the app handed the communication over, which decides what it can ever learn back.
public enum CommunicationLaunchMechanism: String, Codable, Sendable, Hashable, CaseIterable {
    /// `NSSharingService`, which calls back.
    case sharingService

    /// `mailto:`, `sms:`, `tel:`, `facetime:` — opened, with no completion callback of any kind.
    case urlScheme

    /// Submitted through a provider API after an explicit preview and confirmation.
    case providerAPI

    /// The user did it themselves and wrote it down afterwards.
    case manual

    /// Whether this mechanism can report anything back at all.
    ///
    /// `false` for a URL scheme, and that single fact is why the confirmation prompt exists: there is
    /// no callback to wait for, so the only way to learn the outcome is to ask.
    public var reportsCompletion: Bool {
        switch self {
        case .sharingService, .providerAPI: true
        case .urlScheme, .manual: false
        }
    }

    public var displayName: String {
        switch self {
        case .sharingService: "Share sheet"
        case .urlScheme: "Handoff"
        case .providerAPI: "Provider"
        case .manual: "Logged by you"
        }
    }
}

// MARK: - Privacy

/// How much of a message the app keeps.
///
/// ### Why the default keeps none of it
/// The metadata — channel, recipient, time, subject, status — answers the question this module was
/// built for: *did I get back to Maya, and when*. The body answers no additional question the user
/// asked for, and it is the single most sensitive thing the app could hold: a message body may
/// contain a medical result, a resignation, a legal matter, or somebody else's secret.
///
/// So retention is opt-in, per the user's own choice, and the interface says plainly what opting in
/// means before it takes effect.
public enum CommunicationPrivacyPreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    /// Channel, recipient, subject, time, source, and status. **The default.**
    case metadataOnly

    /// The above, plus a digest of the body used only to tell two messages apart when reconciling.
    case fingerprintForMatching

    /// The above, plus the drafted body itself.
    case retainContent

    public var id: String { rawValue }

    public var storesBody: Bool { self == .retainContent }

    /// Whether a content digest may be computed and stored.
    ///
    /// Retaining the content implies permission to derive a digest from it; the middle case exists
    /// for a user who wants better duplicate matching without the body on disk.
    public var storesFingerprint: Bool {
        switch self {
        case .metadataOnly: false
        case .fingerprintForMatching, .retainContent: true
        }
    }

    public var displayName: String {
        switch self {
        case .metadataOnly: "Metadata only"
        case .fingerprintForMatching: "Metadata and a matching digest"
        case .retainContent: "Metadata and message text"
        }
    }

    /// Said in full before the setting changes, because the consequence is not reversible for
    /// anything already written.
    public var explanation: String {
        switch self {
        case .metadataOnly:
            """
            Who you wrote to, through which channel, when, about what subject, and what is known \
            about whether it went. The message itself is never stored.
            """
        case .fingerprintForMatching:
            """
            The same, plus a one-way digest of the text so that two similar messages sent minutes \
            apart are not mistaken for one. The text itself is never stored, but a digest of a short \
            message can be checked against a guess.
            """
        case .retainContent:
            """
            The same, plus the text you drafted. Message content can hold medical, legal, financial, \
            or personal information about you and about other people, and it becomes part of your \
            library, your backups, and your exports.
            """
        }
    }
}

// MARK: - Failure

/// Why a communication did not happen, in terms a person can read.
///
/// Carries the underlying code separately from the sentence shown, so a timeline row stays plain
/// language while a diagnostic still has the detail — the requirement that the interface uses
/// "subtle status labels rather than technical error codes".
public struct CommunicationFailure: Sendable, Hashable, Codable {
    /// What to show. One sentence, no codes.
    public var summary: String

    /// The underlying domain and code, for diagnostics only.
    public var technicalDetail: String?

    /// Whether the user stopped it rather than something going wrong.
    public var wasCanceledByUser: Bool

    public init(summary: String, technicalDetail: String? = nil, wasCanceledByUser: Bool = false) {
        self.summary = summary
        self.technicalDetail = technicalDetail
        self.wasCanceledByUser = wasCanceledByUser
    }

    public static let userCanceled = CommunicationFailure(
        summary: "You closed the composer before sending.",
        wasCanceledByUser: true
    )

    public static let noHandler = CommunicationFailure(
        summary: "No app on this Mac is set up to handle that."
    )
}

// MARK: - Calls

/// What happened on a call, as the user reports it.
///
/// ### Why every one of these is manual
/// macOS tells a third-party app nothing about a call it did not place itself — not that it
/// connected, not how long it lasted, not whether it was answered. Opening a `tel:` URL is the end of
/// what the app observes. Every value here therefore arrives by the user saying so, and the timeline
/// says "confirmed manually" because that is the only thing it could honestly say.
public enum CallOutcome: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case connected
    case noAnswer
    case leftVoicemail
    case canceled

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .connected: "Connected"
        case .noAnswer: "No answer"
        case .leftVoicemail: "Left voicemail"
        case .canceled: "Canceled"
        }
    }

    /// Whether this counts as having spoken, for the last-contact line.
    ///
    /// Only ``connected``. Reaching somebody's voicemail is reaching their voicemail, and the People
    /// module's existing rule — stated on ``InteractionProvenance/countsAsContact`` — already says
    /// that a call which got voicemail is not contact. One rule, applied here too, so a call logged
    /// through this module and a call logged by hand cannot disagree.
    public var countsAsContact: Bool { self == .connected }

    public var symbolName: String {
        switch self {
        case .connected: "phone.connection"
        case .noAnswer: "phone.down"
        case .leftVoicemail: "recordingtape"
        case .canceled: "xmark.circle"
        }
    }
}
