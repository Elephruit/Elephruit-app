import Foundation

/// A way of reaching somebody.
public enum ContactChannel: String, Sendable, Hashable, CaseIterable, Identifiable {
    case call
    case message
    case email
    case facetimeVideo
    case facetimeAudio
    case maps
    case web

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .call: "Call"
        case .message: "Message"
        case .email: "Email"
        case .facetimeVideo: "FaceTime"
        case .facetimeAudio: "FaceTime Audio"
        case .maps: "Open in Maps"
        case .web: "Open Website"
        }
    }

    /// "Call" · "Send an email to" — for a preview sentence.
    public var verbPhrase: String {
        switch self {
        case .call: "Call"
        case .message: "Message"
        case .email: "Email"
        case .facetimeVideo: "FaceTime"
        case .facetimeAudio: "FaceTime Audio"
        case .maps: "Map"
        case .web: "Open the site for"
        }
    }

    /// What the destination is called, for "Which number?".
    public var destinationNoun: String {
        switch self {
        case .call, .message, .facetimeAudio: "number"
        case .email: "email address"
        case .facetimeVideo: "number or address"
        case .maps: "address"
        case .web: "website"
        }
    }

    public var symbolName: String {
        switch self {
        case .call: "phone"
        case .message: "message"
        case .email: "envelope"
        case .facetimeVideo: "video"
        case .facetimeAudio: "phone.badge.waveform"
        case .maps: "map"
        case .web: "safari"
        }
    }

    /// Which kind of stored detail this channel consumes.
    public var destinationSource: ContactDestinationSource {
        switch self {
        case .call, .message, .facetimeAudio: .phone
        case .email: .email
        case .facetimeVideo: .phoneOrEmail
        case .maps: .address
        case .web: .website
        }
    }

    /// Whether using this reaches another human being.
    ///
    /// The line that decides what needs confirming. Opening a map is nobody's business but the
    /// user's; placing a call is.
    public var isExternallyVisible: Bool {
        switch self {
        case .call, .message, .email, .facetimeVideo, .facetimeAudio: true
        case .maps, .web: false
        }
    }
}

public enum ContactDestinationSource: Sendable, Hashable {
    case phone
    case email
    case phoneOrEmail
    case address
    case website
}

/// One thing that could be dialled, written to, or opened.
public struct ContactDestination: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var label: String
    public var value: String
    public var source: ContactDestinationSource

    /// Whether this is the one to use when the user did not say.
    public var isPreferred: Bool

    public init(
        id: UUID = UUID(),
        label: String,
        value: String,
        source: ContactDestinationSource,
        isPreferred: Bool = false
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.source = source
        self.isPreferred = isPreferred
    }

    /// "mobile · (512) 555-0192". A phone number is shown the way somebody would write it down;
    /// the stored value, which is what dials, is untouched.
    public var displayText: String {
        let shown = source == .phone ? PhoneNumberFormatting.display(value) : value
        return label.isEmpty ? shown : "\(label) · \(shown)"
    }
}

/// Builds the URL that hands an action to the system.
///
/// ### Why URLs rather than frameworks
/// `tel:` and `mailto:` are handed to `NSWorkspace`, which opens the user's own chosen app with the
/// fields filled in and **stops there** — the user still presses send. A framework that composed and
/// sent on the app's behalf would be a far larger promise than this app wants to make, and it would
/// need entitlements it deliberately does not have.
///
/// Every builder is a pure function returning an optional, so the whole surface is unit-testable and
/// a malformed number produces no URL rather than an unexpected one.
public enum ContactActionURL {
    public static func url(for channel: ContactChannel, destination: String) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch channel {
        case .call:
            return telephoneURL(scheme: "tel", number: trimmed)
        case .message:
            return telephoneURL(scheme: "sms", number: trimmed) ?? addressURL(scheme: "sms", value: trimmed)
        case .email:
            return mailtoURL(recipients: [trimmed])
        case .facetimeVideo:
            return telephoneURL(scheme: "facetime", number: trimmed) ?? addressURL(scheme: "facetime", value: trimmed)
        case .facetimeAudio:
            return telephoneURL(scheme: "facetime-audio", number: trimmed)
                ?? addressURL(scheme: "facetime-audio", value: trimmed)
        case .maps:
            return mapsURL(address: trimmed)
        case .web:
            return websiteURL(trimmed)
        }
    }

    /// A `mailto:` with everyone on it.
    ///
    /// - Parameter useBlindCopy: Puts every recipient in `bcc` and leaves `to` empty. **The default
    ///   for any group of more than one**, because a group email that discloses everyone's address to
    ///   everyone else is a privacy failure the sender usually notices only afterwards.
    public static func mailtoURL(
        recipients: [String],
        useBlindCopy: Bool = false,
        subject: String? = nil,
        body: String? = nil
    ) -> URL? {
        let cleaned = recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = useBlindCopy ? "" : cleaned.joined(separator: ",")

        var query: [URLQueryItem] = []
        if useBlindCopy {
            query.append(URLQueryItem(name: "bcc", value: cleaned.joined(separator: ",")))
        }
        if let subject, !subject.isEmpty {
            query.append(URLQueryItem(name: "subject", value: subject))
        }
        if let body, !body.isEmpty {
            query.append(URLQueryItem(name: "body", value: body))
        }
        if !query.isEmpty { components.queryItems = query }

        return components.url
    }

    /// `sms:` addressed to several people.
    public static func groupMessageURL(recipients: [String]) -> URL? {
        let numbers = recipients
            .map { $0.filter { character in character.isNumber || character == "+" } }
            .filter { !$0.isEmpty }
        guard !numbers.isEmpty else { return nil }

        return URL(string: "sms:" + numbers.joined(separator: ","))
    }

    public static func mapsURL(address: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "q", value: address)]
        return components.url
    }

    /// A website, tolerating a missing scheme.
    public static func websiteURL(_ text: String) -> URL? {
        if text.hasPrefix("http://") || text.hasPrefix("https://") {
            return URL(string: text)
        }
        guard !text.contains(" "), text.contains(".") else { return nil }
        return URL(string: "https://" + text)
    }

    /// A `tel:`-family URL, or `nil` when the text is not a number.
    private static func telephoneURL(scheme: String, number: String) -> URL? {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard digits.filter(\.isNumber).count >= 5 else { return nil }
        return URL(string: "\(scheme):\(digits)")
    }

    /// The same schemes, addressed to an Apple ID rather than a number.
    private static func addressURL(scheme: String, value: String) -> URL? {
        guard ContactDetailRecognizer.isEmail(value) else { return nil }
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(scheme):\(encoded)")
    }
}

// MARK: - What actually happened

/// How the app came to know about an interaction.
///
/// ### Why this distinction is in the data model
/// The app can see that the user pressed *Call*. It cannot see whether the call connected, whether
/// anyone answered, or whether the two of them spoke for an hour. Recording "spoke to Maya" on the
/// strength of a button press would put a fact in the timeline that nobody stated and that the
/// user would later read as true.
///
/// So a button press records `initiated` and says so. Turning that into a conversation is a
/// deliberate act with a summary attached — and the timeline shows which of the three it was.
public enum InteractionProvenance: String, Codable, Sendable, Hashable, CaseIterable {
    /// The user wrote it down. The strongest claim.
    case logged

    /// The user pressed a button that opened Mail or FaceTime. Nothing is known beyond that.
    case initiated

    /// Derived from a calendar event or another system record.
    case detected

    public var displayName: String {
        switch self {
        case .logged: "Logged"
        case .initiated: "Started"
        case .detected: "From your calendar"
        }
    }

    /// The phrase used in a timeline row.
    public func phrase(channel: ContactChannel?) -> String {
        switch self {
        case .logged:
            channel.map { "\($0.displayName.lowercased()) — logged" } ?? "logged"
        case .initiated:
            channel.map { "\($0.displayName.lowercased()) started from Elephruit" } ?? "started"
        case .detected:
            "detected from your calendar"
        }
    }

    /// Whether this counts as "we actually spoke" for the last-contact line.
    ///
    /// Only a logged interaction does. Pressing Call and getting voicemail is not contact, and
    /// letting it count would make the one number this module is trusted for quietly wrong.
    public var countsAsContact: Bool {
        self == .logged
    }
}

/// An action about to be taken, ready to be shown to the user before it is.
public struct ContactActionPreview: Sendable, Hashable {
    public var channel: ContactChannel
    public var personName: String
    public var destination: ContactDestination
    public var url: URL?

    public init(channel: ContactChannel, personName: String, destination: ContactDestination, url: URL?) {
        self.channel = channel
        self.personName = personName
        self.destination = destination
        self.url = url
    }

    /// "Call Maya Chen at mobile · (512) 555-0192".
    public var sentence: String {
        "\(channel.verbPhrase) \(personName) at \(destination.displayText)"
    }

    public var isRunnable: Bool { url != nil }
}

/// Choosing which number to ring.
public enum ContactDestinationPolicy {
    /// The destinations a channel can use, preferred first.
    public static func candidates(
        for channel: ContactChannel,
        from destinations: [ContactDestination]
    ) -> [ContactDestination] {
        let matching = destinations.filter { destination in
            switch channel.destinationSource {
            case .phone: destination.source == .phone
            case .email: destination.source == .email
            case .phoneOrEmail: destination.source == .phone || destination.source == .email
            case .address: destination.source == .address
            case .website: destination.source == .website
            }
        }
        return matching.sorted { left, right in
            left.isPreferred == right.isPreferred ? left.label < right.label : left.isPreferred
        }
    }

    /// The one to use without asking, or `nil` when the user has to choose.
    ///
    /// Exactly one candidate, or one marked preferred. Two unmarked numbers means asking — the app
    /// does not get to decide which of somebody's phones is the right one to ring.
    public static func automatic(
        for channel: ContactChannel,
        from destinations: [ContactDestination]
    ) -> ContactDestination? {
        let candidates = candidates(for: channel, from: destinations)
        if candidates.count == 1 { return candidates.first }
        return candidates.first { $0.isPreferred }
    }
}
