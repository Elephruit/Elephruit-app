import ElephruitCore
import Foundation
import Testing

/// Which actions a person's record can actually support, and in what order.
///
/// The rule these pin down is the one that used to be re-decided in four views: the People
/// workspace, the command bar, a list row's context menu and the meeting brief each worked out for
/// themselves whether Email was available, which is four chances to disagree. Asserting it once, on
/// the data, is what makes them agree.
@Suite("Person action availability")
struct PersonActionAvailabilityTests {
    private func phone(_ value: String, label: String = "mobile", preferred: Bool = false) -> ContactDestination {
        ContactDestination(label: label, value: value, source: .phone, isPreferred: preferred)
    }

    private func email(_ value: String, label: String = "work") -> ContactDestination {
        ContactDestination(label: label, value: value, source: .email)
    }

    private func actions(_ destinations: [ContactDestination]) -> [PersonActionAvailability] {
        PersonActionAvailability.all(destinations: destinations)
    }

    private func action(
        _ id: String,
        in list: [PersonActionAvailability]
    ) throws -> PersonActionAvailability {
        try #require(list.first { $0.id == id })
    }

    // MARK: - Availability follows the data

    @Test("Call needs a number and Email needs an address")
    func availabilityComesFromTheData() throws {
        let phoneOnly = actions([phone("512-555-0192")])

        #expect(try action("contact.call", in: phoneOnly).isAvailable)
        #expect(try action("contact.message", in: phoneOnly).isAvailable)
        #expect(try !action("contact.email", in: phoneOnly).isAvailable)

        let emailOnly = actions([email("maya@example.com")])
        #expect(try !action("contact.call", in: emailOnly).isAvailable)
        #expect(try action("contact.email", in: emailOnly).isAvailable)
    }

    /// A control that is merely grey is indistinguishable from one that is broken.
    @Test("Everything unavailable says why")
    func unavailableActionsExplainThemselves() {
        for entry in actions([]) where !entry.isAvailable {
            #expect(entry.unavailabilityReason?.isEmpty == false, "\(entry.id) is off and silent")
        }
    }

    @Test("Nothing available says why in terms of the missing detail")
    func reasonNamesWhatIsMissing() throws {
        let empty = actions([])
        #expect(try action("contact.call", in: empty).unavailabilityReason == "No number recorded")
        #expect(try action("contact.email", in: empty).unavailabilityReason == "No email address recorded")
        #expect(try action("contact.maps", in: empty).unavailabilityReason == "No address recorded")
    }

    /// Pressing Call should not be a guess about whose phone rings.
    @Test("One number is named; several say a choice is coming")
    func detailNamesTheDestination() throws {
        let single = actions([phone("512-555-0192")])
        #expect(try action("contact.call", in: single).detail == "mobile · (512) 555-0192")

        let two = actions([phone("512-555-0192"), phone("512-555-0100", label: "home")])
        #expect(try action("contact.call", in: two).detail == "2 to choose from")
    }

    // MARK: - Order follows the data too

    /// A row whose first two buttons are permanently unusable teaches the user to look past its
    /// first two buttons.
    @Test("An action that cannot run sinks below every one that can")
    func unavailableActionsSink() {
        let ranked = actions([email("maya@example.com")])
        let lastAvailable = ranked.lastIndex(where: \.isAvailable) ?? 0
        let firstUnavailable = ranked.firstIndex(where: { !$0.isAvailable }) ?? ranked.count

        #expect(lastAvailable < firstUnavailable)
    }

    @Test("Call leads for somebody with a phone; Email leads for somebody with only an address")
    func priorityIsContextual() throws {
        let byPhone = actions([phone("512-555-0192")])
        #expect(byPhone.first?.id == "contact.call")

        let byEmail = actions([email("maya@example.com")])
        #expect(byEmail.first?.id == "contact.email")
    }

    /// The ranking must not depend on dictionary iteration order, or the row reshuffles itself
    /// between launches and nobody can build muscle memory for it.
    @Test("The order is the same every time")
    func orderIsStable() {
        let destinations = [phone("512-555-0192"), email("maya@example.com")]
        let first = PersonActionAvailability.all(destinations: destinations).map(\.id)

        for _ in 0..<50 {
            #expect(PersonActionAvailability.all(destinations: destinations).map(\.id) == first)
        }
    }

    // MARK: - Actions that need no data

    @Test("Writing something down is always available")
    func localActionsNeedNothing() throws {
        let empty = actions([])

        #expect(try action("addNote", in: empty).isAvailable)
        #expect(try action("logInteraction", in: empty).isAvailable)
        #expect(try action("addTask", in: empty).isAvailable)
        #expect(try action("addRelationship", in: empty).isAvailable)
    }

    /// A brief assembled from nothing is a heading and three empty sections.
    @Test("A brief needs something to brief from")
    func briefNeedsHistory() throws {
        let withoutHistory = PersonActionAvailability.all(destinations: [], hasHistory: false)
        #expect(try !action("meetingBrief", in: withoutHistory).isAvailable)

        let withHistory = PersonActionAvailability.all(destinations: [], hasHistory: true)
        #expect(try action("meetingBrief", in: withHistory).isAvailable)
    }

    @Test("Add Relationship asks a different question depending on whether there are any")
    func relationshipCopyChanges() throws {
        let none = PersonActionAvailability.all(destinations: [], hasRelationships: false)
        let some = PersonActionAvailability.all(destinations: [], hasRelationships: true)

        #expect(try action("addRelationship", in: none).detail != action("addRelationship", in: some).detail)
    }

    // MARK: - Confirmation

    /// The line that decides what needs confirming: opening a map is nobody's business but the
    /// user's, and placing a call is.
    @Test("Only the actions that reach another person are externally visible")
    func externalVisibility() throws {
        let all = actions([phone("512-555-0192"), email("maya@example.com")])

        #expect(try action("contact.call", in: all).isExternallyVisible)
        #expect(try action("contact.email", in: all).isExternallyVisible)
        #expect(try !action("contact.maps", in: all).isExternallyVisible)
        #expect(try !action("addNote", in: all).isExternallyVisible)
    }

    // MARK: - Labels

    /// "Message" is what happens; "Messages" is an application, and naming the application makes
    /// the user translate.
    @Test("Every title is a verb and every action has a symbol")
    func titlesAndSymbols() {
        for entry in actions([]) {
            #expect(!entry.title.isEmpty)
            #expect(!entry.symbolName.isEmpty)
            #expect(entry.title.first?.isUppercase == true, "\(entry.id) is not sentence-cased")
        }
    }

    @Test("Every action has a distinct identifier")
    func identifiersAreUnique() {
        let ids = actions([]).map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
