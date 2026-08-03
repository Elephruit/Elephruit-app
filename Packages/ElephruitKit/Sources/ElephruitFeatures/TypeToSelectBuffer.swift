import Foundation

/// Letters typed into a focused browser, accumulated until the user pauses.
public struct TypeToSelectBuffer: Sendable, Hashable {
    public static let interval: TimeInterval = 0.75

    public private(set) var text = ""
    private var lastKeystroke: Date?

    public init() {}

    public mutating func append(_ character: Character, at time: Date) -> String {
        if let lastKeystroke, time.timeIntervalSince(lastKeystroke) > Self.interval {
            text = ""
        }
        lastKeystroke = time
        text.append(character)
        return text
    }

    public func hasExpired(at time: Date) -> Bool {
        guard let lastKeystroke else { return true }
        return time.timeIntervalSince(lastKeystroke) > Self.interval
    }

    public mutating func clear() {
        text = ""
        lastKeystroke = nil
    }
}
