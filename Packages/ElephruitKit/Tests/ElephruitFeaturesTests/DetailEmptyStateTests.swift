import ElephruitCore
import Foundation
import Testing

@testable import ElephruitFeatures

/// What the detail pane says when it has nothing to show.
///
/// Copy is testable here because ``DetailEmptyState`` is a pure function of the selection, and it is
/// worth testing because the failure it replaces was invisible to everyone who did not happen to
/// open the Trash with nothing selected. A sentence shown in eleven places is read in eleven
/// contexts, and it was only ever checked in one.
@Suite("Detail empty state")
struct DetailEmptyStateTests {
    /// The destinations where ⌘N does not make the thing the pane is empty of.
    ///
    /// In the Trash and the Archive, creating is not among the answers to "should this be kept". In
    /// People, ⌘N makes a *note* — it does not make a person — so naming it would teach a habit that
    /// produces the wrong object. ⌘N is not disabled in any of them; it is simply not the hint this
    /// screen should be giving, and a hint that needs a footnote is not a hint.
    static let mustNotOfferNewItem: [SidebarSelection] = [
        .trash,
        .archive,
        .people(.all),
        .people(.favorites),
        .kind(.person),
    ]

    @Test("Where making something new is the wrong answer, it is not offered", arguments: mustNotOfferNewItem)
    func doesNotOfferNewItemWhereItWouldMislead(selection: SidebarSelection) {
        let state = DetailEmptyState.forSelection(selection)
        #expect(!state.message.contains("⌘N"))
    }

    /// The converse, so this cannot be satisfied by removing the hint everywhere. A list of notes
    /// with nothing chosen is exactly where somebody wants to be told how to start one.
    static let mustOfferNewItem: [SidebarSelection] = [
        .inbox,
        .kind(.note),
        .kind(.task),
    ]

    /// Destinations that own their whole pane and therefore never reach an empty state at all.
    ///
    /// Listed so that the sentence they fall back to is still checked for being a sentence — the
    /// generic copy is what a bug would land somebody on, and it should read as English rather than
    /// as a placeholder.
    static let ownTheirPane: [SidebarSelection] = [.today, .home, .upcoming, .calendar, .time]

    @Test("A destination that owns its pane falls back to the generic sentence", arguments: ownTheirPane)
    func canvasDestinationsFallBackGracefully(selection: SidebarSelection) {
        #expect(DetailEmptyState.forSelection(selection) == .generic)
    }

    @Test("Where making something new is the obvious next move, it is offered", arguments: mustOfferNewItem)
    func offersNewItemWhereItHelps(selection: SidebarSelection) {
        let state = DetailEmptyState.forSelection(selection)
        #expect(state.message.contains("⌘N"))
    }

    @Test("The Trash talks about restoring rather than creating")
    func trashSaysWhatTheTrashIsFor() {
        let state = DetailEmptyState.forSelection(.trash)
        #expect(state.symbolName == "trash")
        #expect(state.message.contains("put back"))
    }

    @Test("People says nobody rather than nothing")
    func peopleSaysNobody() {
        #expect(DetailEmptyState.forSelection(.people(.all)).headline == "Nobody selected")
    }

    /// Every destination gets a sentence, and none of them gets an empty one. Enumerated rather than
    /// spot-checked so that widening `SidebarSelection` cannot quietly leave a new destination with
    /// a blank pane.
    @Test("Every destination has something to say", arguments: DetailEmptyStateTests.everyDestination)
    func everyDestinationHasCopy(selection: SidebarSelection) {
        let state = DetailEmptyState.forSelection(selection)
        #expect(!state.headline.isEmpty)
        #expect(!state.message.isEmpty)
        #expect(!state.symbolName.isEmpty)
        // A headline that ends in a full stop reads as a sentence fragment beside the message.
        #expect(!state.headline.hasSuffix("."))
        #expect(state.message.hasSuffix("."))
    }

    static var everyDestination: [SidebarSelection] {
        var destinations: [SidebarSelection] = [
            .today, .upcoming, .inbox, .archive, .trash, .home, .calendar, .time,
            .tag(slug: "work"), .savedSearch(id: UUID()), .item(id: UUID()),
            .taskView(.inbox), .smartList(id: UUID()), .builtInSmartList(id: "overdue"),
            .people(.all), .people(.celebrations), .people(.group(id: UUID())),
        ]
        destinations.append(contentsOf: ItemKind.allCases.map { SidebarSelection.kind($0) })
        return destinations
    }
}
