import AppKit
import ElephruitCore
import Foundation

/// Handing a communication to the application that owns it.
///
/// ### Why `launch` is not `async` and returns immediately
/// The obvious shape — `await launch(request)` returning the final outcome — is wrong for both
/// mechanisms this has to cover, in opposite directions.
///
/// A URL scheme has **no completion callback of any kind**. There is nothing to await; opening the
/// URL is the whole of what happens, and an `async` signature would promise a resolution that never
/// arrives.
///
/// A sharing service does call back, but only if the user finishes with the sheet. Somebody who
/// opens a compose window and leaves it open over lunch never resumes the continuation, and an
/// awaited call would sit there holding it.
///
/// So `launch` returns what is true at the moment of handing over — the composer is open — and
/// anything learned later arrives on ``reports``. That also happens to be exactly the sequence of
/// states the timeline should show.
@MainActor
public protocol CommunicationLaunching: AnyObject, Sendable {
    /// Whether this launcher can serve a channel at all.
    func canLaunch(_ channel: CommunicationChannel) -> Bool

    /// Which mechanism a channel would actually use, so the caller can record it before launching.
    func mechanism(for channel: CommunicationChannel) -> CommunicationLaunchMechanism

    /// Hands the communication over, and reports what is known at that instant.
    @discardableResult
    func launch(_ request: CommunicationLaunchRequest) -> CommunicationLaunchReport

    /// Later reports — a sharing service finishing, failing, or being canceled.
    ///
    /// An `AsyncStream` rather than a delegate the caller has to implement, on the same terms as
    /// ``CalendarProviding/changes``: a consumer neither imports AppKit nor has to remember to
    /// detach.
    var reports: AsyncStream<CommunicationLaunchReport> { get }
}

// MARK: - Inert

/// The default, and what previews, tests, and any unconfigured build use.
///
/// Reports ``CommunicationLaunchOutcome/unavailable`` and opens nothing, so every path through the
/// interface runs against a real implementation from the first launch rather than a `nil` branch
/// that only executes on somebody's Mac.
@MainActor
public final class InertCommunicationLauncher: CommunicationLaunching {
    /// Every request this was handed, so a test can assert on what *would* have been opened without
    /// anything being opened.
    public private(set) var launched: [CommunicationLaunchRequest] = []

    private let continuation: AsyncStream<CommunicationLaunchReport>.Continuation
    public let reports: AsyncStream<CommunicationLaunchReport>

    public init() {
        let (stream, continuation) = AsyncStream<CommunicationLaunchReport>.makeStream()
        self.reports = stream
        self.continuation = continuation
    }

    public func canLaunch(_ channel: CommunicationChannel) -> Bool { false }

    public func mechanism(for channel: CommunicationChannel) -> CommunicationLaunchMechanism {
        channel.hasSharingService ? .sharingService : .urlScheme
    }

    @discardableResult
    public func launch(_ request: CommunicationLaunchRequest) -> CommunicationLaunchReport {
        launched.append(request)
        return CommunicationLaunchReport(
            intentID: request.id,
            channel: request.channel,
            mechanism: mechanism(for: request.channel),
            outcome: .unavailable,
            occurredAt: Date()
        )
    }

    /// Feeds a report as though a framework had produced one. Test-facing, and the reason the
    /// reconciliation path can be exercised without a share sheet.
    public func emit(_ report: CommunicationLaunchReport) {
        continuation.yield(report)
    }
}

// MARK: - URL schemes

/// `mailto:`, `sms:`, `tel:`, and the FaceTime schemes, handed to `NSWorkspace`.
///
/// ### What this can and cannot know
/// `NSWorkspace.open` returns whether macOS found something willing to handle the URL. That is the
/// entire extent of what is observable. There is no callback when the composer closes, none when the
/// user sends, and none when they do not — so this launcher never produces anything above
/// ``CommunicationLaunchOutcome/composerOpened``, and the only way the app ever learns more is by
/// asking the user.
@MainActor
public final class URLSchemeCommunicationLauncher: CommunicationLaunching {
    private let open: @MainActor (URL) -> Bool
    private let now: @MainActor () -> Date

    private let continuation: AsyncStream<CommunicationLaunchReport>.Continuation
    public let reports: AsyncStream<CommunicationLaunchReport>

    /// - Parameter open: How to hand a URL to the system. Injected so a test can assert on the URL
    ///   built without anything being opened on the machine running the tests.
    public init(
        open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.open = open
        self.now = now
        let (stream, continuation) = AsyncStream<CommunicationLaunchReport>.makeStream()
        self.reports = stream
        self.continuation = continuation
    }

    public func canLaunch(_ channel: CommunicationChannel) -> Bool { true }

    public func mechanism(for channel: CommunicationChannel) -> CommunicationLaunchMechanism { .urlScheme }

    @discardableResult
    public func launch(_ request: CommunicationLaunchRequest) -> CommunicationLaunchReport {
        let outcome: CommunicationLaunchOutcome

        if let url = Self.url(for: request) {
            outcome = open(url) ? .composerOpened : .failed(.noHandler)
        } else {
            outcome = .failed(
                CommunicationFailure(summary: "That \(request.channel.noun.lowercased()) has nowhere to go.")
            )
        }

        return CommunicationLaunchReport(
            intentID: request.id,
            channel: request.channel,
            mechanism: .urlScheme,
            outcome: outcome,
            occurredAt: now()
        )
    }

    /// The URL a request becomes, or `nil` when it cannot become one.
    ///
    /// Built from ``ContactActionURL``, which is already the one place a scheme is assembled and
    /// already tested — a second builder here would be a second set of escaping rules to get wrong.
    static func url(for request: CommunicationLaunchRequest) -> URL? {
        let handles = request.recipientHandles
        guard let first = handles.first else { return nil }

        switch request.channel {
        case .email:
            // Several recipients go in `bcc` by default, because a group email that discloses
            // everyone's address to everyone else is a privacy failure the sender notices afterwards.
            return ContactActionURL.mailtoURL(
                recipients: handles,
                useBlindCopy: handles.count > 1,
                subject: request.subject,
                body: request.body
            )
        case .message:
            return handles.count > 1
                ? ContactActionURL.groupMessageURL(recipients: handles)
                : ContactActionURL.url(for: .message, destination: first)
        case .phoneCall, .facetimeVideo, .facetimeAudio:
            return ContactActionURL.url(for: request.channel.contactChannel, destination: first)
        }
    }
}

// MARK: - Sharing services

/// `NSSharingService`, for the two channels macOS offers a native composer for.
///
/// ### Why this is preferred over a `mailto:`
/// A sharing service addresses a *named* service rather than whatever happens to have registered a
/// scheme, it carries attachments as items rather than as text, it does not require the subject and
/// body to survive percent-encoding, and — the part that matters here — **it calls back**. A
/// `mailto:` tells the app nothing after the moment it is opened; a share tells it whether the sheet
/// finished, failed, or was dismissed.
///
/// ### What the callback is worth
/// `sharingService(_:didShareItems:)` says the sharing service finished. The delegate receives the
/// items *this app* supplied, so it proves nothing about the message the user actually sent: not
/// that a server accepted it, not that the recipients are the ones supplied, not that the body is,
/// and certainly not that anybody received it. It is recorded as
/// ``CommunicationState/shareCompleted`` — "handed off" — and the interface says so in those words.
@MainActor
public final class SharingServiceCommunicationLauncher: NSObject, CommunicationLaunching {
    private let now: @MainActor () -> Date

    /// The request each in-flight service belongs to, so a callback can be attributed.
    ///
    /// A fresh `NSSharingService` per launch, so the mapping is one-to-one and two composers open at
    /// once cannot be confused for each other.
    private var inFlight: [ObjectIdentifier: CommunicationLaunchRequest] = [:]

    private let continuation: AsyncStream<CommunicationLaunchReport>.Continuation
    public let reports: AsyncStream<CommunicationLaunchReport>

    public init(now: @escaping @MainActor () -> Date = { Date() }) {
        self.now = now
        let (stream, continuation) = AsyncStream<CommunicationLaunchReport>.makeStream()
        self.reports = stream
        self.continuation = continuation
        super.init()
    }

    public func canLaunch(_ channel: CommunicationChannel) -> Bool {
        guard let name = Self.serviceName(for: channel) else { return false }
        return NSSharingService(named: name) != nil
    }

    public func mechanism(for channel: CommunicationChannel) -> CommunicationLaunchMechanism {
        canLaunch(channel) ? .sharingService : .urlScheme
    }

    @discardableResult
    public func launch(_ request: CommunicationLaunchRequest) -> CommunicationLaunchReport {
        guard let name = Self.serviceName(for: request.channel),
              let service = NSSharingService(named: name)
        else {
            return report(for: request, outcome: .unavailable)
        }

        service.delegate = self
        service.recipients = request.recipientHandles
        if let subject = request.subject, !subject.isEmpty { service.subject = subject }

        let items = Self.items(for: request)

        guard service.canPerform(withItems: items) else {
            return report(for: request, outcome: .unavailable)
        }

        inFlight[ObjectIdentifier(service)] = request
        service.perform(withItems: items)

        return report(for: request, outcome: .composerOpened)
    }

    /// The items handed to the service: the body, then any files.
    ///
    /// The body goes as a `String` rather than being percent-encoded into a URL, which is the other
    /// reason to prefer this path — a message containing a newline, an ampersand, or an emoji
    /// arrives intact.
    static func items(for request: CommunicationLaunchRequest) -> [Any] {
        var items: [Any] = []
        if let body = request.body, !body.isEmpty { items.append(body) }
        items.append(contentsOf: request.attachmentURLs)

        // A service will not perform with nothing at all, and an empty message is a legitimate thing
        // to want: the user is about to type it.
        if items.isEmpty { items.append("") }
        return items
    }

    static func serviceName(for channel: CommunicationChannel) -> NSSharingService.Name? {
        switch channel {
        case .email: .composeEmail
        case .message: .composeMessage
        case .phoneCall, .facetimeVideo, .facetimeAudio: nil
        }
    }

    private func report(
        for request: CommunicationLaunchRequest,
        outcome: CommunicationLaunchOutcome
    ) -> CommunicationLaunchReport {
        CommunicationLaunchReport(
            intentID: request.id,
            channel: request.channel,
            mechanism: .sharingService,
            outcome: outcome,
            occurredAt: now()
        )
    }

    /// Publishes a later outcome and forgets the service that produced it.
    ///
    /// Keyed by identity rather than by the service itself: `NSSharingService` is not `Sendable`, so
    /// the delegate callbacks — which arrive `nonisolated` — cannot carry it across to the main
    /// actor. `ObjectIdentifier` is a value, crosses freely, and is all this needs.
    fileprivate func finish(_ key: ObjectIdentifier, outcome: CommunicationLaunchOutcome) {
        guard let request = inFlight.removeValue(forKey: key) else { return }
        continuation.yield(report(for: request, outcome: outcome))
    }
}

// MARK: - NSSharingServiceDelegate

extension SharingServiceCommunicationLauncher: NSSharingServiceDelegate {
    /// Sharing is about to begin. Nothing is recorded here.
    ///
    /// The composer-opened state was already written when ``launch(_:)`` returned, and writing a
    /// second identical state from here would put two rows in the event log describing one thing.
    /// The method is implemented because its absence would leave the sequence undocumented, and
    /// because it is the hook a future compose-session integration would extend.
    public nonisolated func sharingService(_ sharingService: NSSharingService, willShareItems items: [Any]) {
        Diagnostics.integrations.debug("Sharing service will share \(items.count, privacy: .public) item(s)")
    }

    /// Sharing finished. **Handed off, not delivered** — see the note on this type.
    public nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        let key = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated {
            finish(key, outcome: .shareCompleted)
        }
    }

    /// Sharing did not finish.
    ///
    /// A user closing the compose window arrives here as a cancellation rather than as a failure, and
    /// the two are recorded differently: cancelling is a decision and failing is a problem. The
    /// distinction is read from the error, because AppKit reports both through this one method.
    public nonisolated func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        let failure = Self.failure(from: error)
        let key = ObjectIdentifier(sharingService)
        MainActor.assumeIsolated {
            finish(key, outcome: failure.wasCanceledByUser ? .canceled(failure) : .failed(failure))
        }
    }

    /// Reads an `NSError` as either a cancellation or a genuine failure.
    ///
    /// `NSUserCancelledError` in `NSCocoaErrorDomain` is how AppKit reports a dismissed sheet. The
    /// check is deliberately narrow: anything not recognisably a cancellation is treated as a
    /// failure, so an unfamiliar error surfaces as a problem the user can see rather than being
    /// quietly filed as "you changed your mind".
    ///
    /// The localised description is kept as ``CommunicationFailure/technicalDetail``, never as the
    /// sentence shown, so a timeline row stays plain language.
    nonisolated static func failure(from error: any Error) -> CommunicationFailure {
        let nsError = error as NSError
        let isCancellation = nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError

        guard !isCancellation else { return .userCanceled }

        return CommunicationFailure(
            summary: "The composer could not be opened.",
            technicalDetail: "\(nsError.domain) \(nsError.code)"
        )
    }
}

// MARK: - The system launcher

/// Sharing services where macOS offers one, URL schemes everywhere else.
///
/// ### The rule this encodes
/// Prefer the native composer. It carries attachments properly, survives characters a URL cannot,
/// and reports back — so an email or a message launched through it produces a real "handed off"
/// state rather than a permanent "status unknown".
///
/// A call and a FaceTime call have no sharing service and never will, so they fall through to a URL
/// scheme and can only ever be recorded as *initiated*. That is not a limitation of this class; it
/// is what macOS makes knowable, and the interface says so in those words.
@MainActor
public final class SystemCommunicationLauncher: CommunicationLaunching {
    private let sharing: SharingServiceCommunicationLauncher
    private let urls: URLSchemeCommunicationLauncher

    public let reports: AsyncStream<CommunicationLaunchReport>

    public init(
        sharing: SharingServiceCommunicationLauncher = SharingServiceCommunicationLauncher(),
        urls: URLSchemeCommunicationLauncher = URLSchemeCommunicationLauncher()
    ) {
        self.sharing = sharing
        self.urls = urls

        // Only the sharing launcher ever produces a later report; the URL launcher has nothing to
        // say after `launch` returns, which is the whole point of it. Forwarding its empty stream as
        // well would suggest otherwise.
        self.reports = sharing.reports
    }

    public func canLaunch(_ channel: CommunicationChannel) -> Bool { true }

    public func mechanism(for channel: CommunicationChannel) -> CommunicationLaunchMechanism {
        sharing.canLaunch(channel) ? .sharingService : .urlScheme
    }

    @discardableResult
    public func launch(_ request: CommunicationLaunchRequest) -> CommunicationLaunchReport {
        guard request.preferredMechanism == .sharingService, sharing.canLaunch(request.channel) else {
            return urls.launch(request)
        }

        let report = sharing.launch(request)

        // A service that reported itself available and then refused the items is a real state, not a
        // dead end: the URL scheme still opens something, and a weaker record beats none.
        guard case .unavailable = report.outcome else { return report }
        Diagnostics.integrations.info(
            "Sharing service declined \(request.channel.rawValue, privacy: .public); falling back to a URL"
        )
        return urls.launch(request)
    }
}
