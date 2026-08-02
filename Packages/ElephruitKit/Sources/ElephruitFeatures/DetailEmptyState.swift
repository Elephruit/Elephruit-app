import ElephruitCore
import Foundation

/// What the detail pane says when nothing is selected, for each place it can be empty in.
///
/// ### Why this is not one sentence
/// It was one sentence: *"Nothing selected — Choose something from the list, or press ⌘N to make
/// something new."* — shown in eleven destinations, including the Trash. In the Trash that reads as
/// an instruction to create something in the wastebasket. ⌘N does technically do something there,
/// which is worse rather than better: it silently leaves the Trash and starts a new note somewhere
/// else, so the one hint the screen offers is the one action nobody standing in the Trash wants.
///
/// The same sentence is wrong in People, where ⌘N makes a note rather than a person, and thin
/// everywhere else — a detail pane is the widest thing on screen, and using it to say nothing eleven
/// times over is the largest piece of unspent space in the app.
///
/// So each destination says what *it* is empty of, and mentions a shortcut only where that shortcut
/// does the thing the sentence implies. A hint that has to be qualified is not a hint.
///
/// Pure, and switched over the selection rather than over the module, because the selection is what
/// the pane is actually empty *of* — and because it makes every line of copy in the app assertable
/// in a test rather than discoverable only by navigating to it.
public struct DetailEmptyState: Sendable, Hashable {
    public var symbolName: String
    public var headline: String
    public var message: String

    public init(symbolName: String, headline: String, message: String) {
        self.symbolName = symbolName
        self.headline = headline
        self.message = message
    }

    /// The generic one, for destinations that are genuinely just a list of items.
    ///
    /// Still names ⌘N, because in these places ⌘N does what the sentence says.
    static let generic = DetailEmptyState(
        symbolName: "square.text.square",
        headline: "Nothing selected",
        message: "Choose something from the list, or press ⌘N to make something new."
    )

    public static func forSelection(_ selection: SidebarSelection) -> DetailEmptyState {
        switch selection {
        // The two places where the question is "should this be kept", and where creating is not
        // among the answers.
        case .trash:
            DetailEmptyState(
                symbolName: "trash",
                headline: "Nothing selected",
                message: "Choose a deleted item to see what it was. Anything here can be put back."
            )

        case .archive:
            DetailEmptyState(
                symbolName: "archivebox",
                headline: "Nothing selected",
                message: "Choose something to read it, or put it back in your library."
            )

        // A project draws its own workspace across the whole width, so nothing here is ever shown.
        // The arm exists because the switch is exhaustive and a fallthrough would offer to open a
        // detail pane the layout has already declared unavailable.
        case .project, .projectInbox:
            .generic

        // People. ⌘N makes a note, not a person, so it is not offered — the way to add somebody is
        // the + button above the list, and naming the wrong shortcut would teach the wrong habit.
        case .people:
            DetailEmptyState(
                symbolName: "person.2",
                headline: "Nobody selected",
                message: "Choose someone to see their profile, what you have recorded, and when you last spoke."
            )

        case .inbox:
            DetailEmptyState(
                symbolName: "tray",
                headline: "Nothing selected",
                message: "Choose a capture to file it, or press ⌘N to add one."
            )

        // The Tasks module's own destinations, which share a vocabulary with each other and not with
        // the library's kinds.
        case .taskView, .smartList, .builtInSmartList:
            DetailEmptyState(
                symbolName: "checkmark.circle",
                headline: "No task selected",
                message: "Choose a task to see its dates, its project, and what it is waiting on."
            )

        case .kind(let kind):
            forKind(kind)

        case .savedSearch:
            DetailEmptyState(
                symbolName: "magnifyingglass",
                headline: "Nothing selected",
                message: "Choose a result to read it."
            )

        case .tag:
            DetailEmptyState(
                symbolName: "tag",
                headline: "Nothing selected",
                message: "Choose something filed under this tag to read it."
            )

        // The destinations that own their whole pane. Nothing reaches this state in them, and a
        // sentence is better than a crash if something ever does. Today is here rather than beside
        // Inbox for exactly that reason: it stopped being a list the moment it became the day.
        case .today, .home, .upcoming, .calendar, .time:
            .generic

        case .item:
            .generic
        }
    }

    private static func forKind(_ kind: ItemKind) -> DetailEmptyState {
        switch kind {
        case .note, .idea, .reference, .dailyEntry:
            DetailEmptyState(
                symbolName: "note.text",
                headline: "No note selected",
                message: "Choose a note to read it, or press ⌘N to write one."
            )

        case .task, .goal, .decision:
            DetailEmptyState(
                symbolName: "checkmark.circle",
                headline: "No task selected",
                message: "Choose a task to see its dates and where it belongs, or press ⌘N to add one."
            )

        case .bug:
            DetailEmptyState(
                symbolName: "ant",
                headline: "No bug selected",
                message: "Choose a bug to see how to reproduce it and which build it affects."
            )

        case .feature:
            DetailEmptyState(
                symbolName: "sparkles",
                headline: "No feature selected",
                message: "Choose a feature to see what it covers and where it stands."
            )

        case .milestone, .release:
            DetailEmptyState(
                symbolName: "flag",
                headline: "Nothing selected",
                message: "Choose a milestone or a release to see the work aimed at it."
            )

        case .project:
            DetailEmptyState(
                symbolName: "square.stack.3d.up",
                headline: "No project selected",
                message: "Choose a project to see its brief and everything filed under it."
            )

        case .area:
            DetailEmptyState(
                symbolName: "square.grid.2x2",
                headline: "No area selected",
                message: "Choose an area to see the projects and notes it holds."
            )

        case .bookmark:
            DetailEmptyState(
                symbolName: "bookmark",
                headline: "No bookmark selected",
                message: "Choose a bookmark to see where it points and why you kept it."
            )

        case .person, .organization:
            DetailEmptyState(
                symbolName: "person.2",
                headline: "Nobody selected",
                message: "Choose someone to see their profile."
            )

        case .interaction, .meeting:
            DetailEmptyState(
                symbolName: "bubble.left.and.bubble.right",
                headline: "Nothing selected",
                message: "Choose a conversation to see what was said and what you agreed."
            )

        case .list, .heading:
            .generic
        }
    }
}
