import ElephruitCore
import Foundation
import Testing

@Suite("Links into the calendar")
struct CalendarDeepLinkTests {
    private static func parse(_ text: String) -> CalendarDeepLink? {
        guard let url = URL(string: text) else { return nil }
        return CalendarDeepLink.parse(url)
    }

    @Test("The calendar itself")
    func plainCalendar() {
        #expect(Self.parse("elephruit://calendar") == .calendar)
    }

    @Test("A day is named as a day, not as an instant")
    func days() {
        guard case .day(let components)? = Self.parse("elephruit://calendar/day/2026-08-14") else {
            Issue.record("A day link should parse")
            return
        }
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 14)
    }

    @Test("A day resolves in whichever zone the calendar is drawn in")
    func daysResolveInTheDisplayZone() {
        guard case .day(let components)? = Self.parse("elephruit://calendar/day/2026-08-14") else {
            Issue.record("A day link should parse")
            return
        }

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York") ?? .gmt

        let inTokyo = components.resolve(in: tokyo)
        let inNewYork = components.resolve(in: newYork)

        #expect(inTokyo != inNewYork, """
            The fourteenth of August starts at different instants in different places, which is why \
            the link carries components rather than a date the parser resolved in whatever zone it \
            happened to run in
            """)
        #expect(tokyo.component(.day, from: inTokyo ?? Date()) == 14)
        #expect(newYork.component(.day, from: inNewYork ?? Date()) == 14)
    }

    @Test("An event link carries its occurrence")
    func events() {
        let identity = EventIdentity(
            externalIdentifier: "abc",
            occurrenceDate: Date(timeIntervalSinceReferenceDate: 800_000_000)
        )
        let link = CalendarDeepLink.event(identity)

        guard let url = link.url, case .event(let restored)? = CalendarDeepLink.parse(url) else {
            Issue.record("An event link should round-trip")
            return
        }
        #expect(restored == identity)
    }

    @Test("A set is named by its name")
    func sets() {
        #expect(Self.parse("elephruit://calendar/set/Work") == .set(name: "Work"))
        #expect(Self.parse("elephruit://calendar/set/Current%20Project") == .set(name: "Current Project"))
    }

    @Test("An unrecognised path is refused rather than falling back")
    func unknownPathsAreRefused() {
        // A link that silently does something other than what it says is worse than one that does
        // nothing at all.
        #expect(Self.parse("elephruit://calendar/delete/everything") == nil)
        #expect(Self.parse("elephruit://calendar/day/not-a-date") == nil)
        #expect(Self.parse("elephruit://calendar/day") == nil)
        #expect(Self.parse("elephruit://calendar/set/") == nil)
    }

    @Test("Another app's scheme is not ours")
    func otherSchemes() {
        #expect(Self.parse("https://calendar/day/2026-08-14") == nil)
        #expect(Self.parse("elephruit://people/maya") == nil)
    }

    @Test("A malformed date is refused rather than clamped")
    func malformedDates() {
        #expect(Self.parse("elephruit://calendar/day/2026-13-01") == nil)
        #expect(Self.parse("elephruit://calendar/day/2026-08-99") == nil)
        #expect(Self.parse("elephruit://calendar/day/26-08-14") == nil, "A two-digit year is ambiguous")
    }

    @Test("Every link round-trips through its own URL")
    func roundTrips() {
        let links: [CalendarDeepLink] = [
            .calendar,
            .day(.init(year: 2026, month: 8, day: 14)),
            .set(name: "Work"),
        ]

        for link in links {
            guard let url = link.url, let restored = CalendarDeepLink.parse(url) else {
                Issue.record("\(link) should round-trip")
                continue
            }
            #expect(restored == link)
        }
    }

    @Test("No link can write anything")
    func linksOnlyNavigate() throws {
        // A source check, because the risk is not today's cases — it is the reasonable-looking
        // `case createEvent(title:at:)` somebody adds later, which would be a write triggered by a
        // URL in an email with no confirmation in front of it.
        var url = URL(filePath: #filePath)
        while url.lastPathComponent != "Tests", url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        let file = url.deletingLastPathComponent()
            .appending(path: "Sources/ElephruitCore/CalendarDeepLink.swift")

        let contents = try String(contentsOf: file, encoding: .utf8)
        var declared: [String] = []

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case ") else { continue }
            let name = trimmed.dropFirst("case ".count).prefix { $0.isLetter || $0.isNumber }
            if !name.isEmpty { declared.append(String(name)) }
        }

        #expect(Set(declared) == ["calendar", "day", "event", "set"], """
            A link arrives from outside — an email, a web page — with nothing in front of it. Adding \
            a case here is adding something the outside world can make the app do: \(declared)
            """)
    }
}
