import CoreGraphics
import ElephruitDesign
import Foundation

extension AppModule {
    /// What this module wants of the shell's columns.
    ///
    /// ### Why the table is here and the mechanism is in the design system
    /// ``ModuleShellLayout`` knows how to clamp a restored width and how to drop a column from a
    /// window too narrow to hold it; it knows nothing about calendars or people. This is the other
    /// half: the editorial decision about *how much room a month needs compared to a profile*, which
    /// is a product judgement and belongs next to the modules it judges. Splitting it that way is
    /// what stops a width being invented inside a view again, and what makes every number below
    /// reviewable in one screenful.
    ///
    /// ### The shape of the judgement
    /// Two kinds of module. A **document** module — Notes, Tasks, Projects, Areas, Bookmarks,
    /// Archive, Trash, People — puts a list in the middle and one thing at length on the right, and
    /// wants the right-hand column wide. A **canvas** module — Calendar, Time — *is* the middle
    /// column, and wants the right-hand column not to exist: it has nothing to put there, and the
    /// pane it used to get was 720 points of "Nothing selected" where the month should have been.
    public var shellLayout: ModuleShellLayout {
        switch self {
        case .calendar:
            // A canvas. The month, the week and the day grid are the module; everything else is
            // commentary. No detail column at all, and an event inspector that is only there while
            // an event is selected — a calendar with nothing chosen should be a calendar, not a
            // calendar and a caption saying nothing is chosen.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 520, ideal: 1000),
                detail: .unavailable,
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    // 300 rather than the 420 a profile gets: an event has a title, a time, a place,
                    // a calendar and a guest list, and none of them is prose.
                    width: PaneWidth(minimum: 260, ideal: 300, maximum: 380),
                    compactWindowWidth: 820
                )
            )

        case .time:
            // The other canvas: a week of recorded hours, read across.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 480, ideal: 900),
                detail: .unavailable,
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 260, ideal: 300, maximum: 360),
                    compactWindowWidth: 820
                )
            )

        case .people:
            // The widest detail pane in the app, and deliberately. A populated profile carries an
            // identity header, actions, facts, notes, contact methods, relationships and a history,
            // and every one of those degrades into a column of wrapped fragments below about 480.
            // The contact list keeps its own width, which is why it is stated separately here rather
            // than taken from whatever the profile left over.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 250, ideal: 300, maximum: 380),
                detail: DetailPanePolicy(
                    hidesWhenNothingSelected: false,
                    width: PaneWidth(minimum: 400, ideal: 560, maximum: 820),
                    compactWindowWidth: 860
                ),
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 260, ideal: 320, maximum: 420),
                    compactWindowWidth: 1180
                )
            )

        case .tasks:
            // Narrower than a profile on purpose. A task is a title, three dates, a project, some
            // tags and a note; giving it 720 points stretches a row of date pickers across a width
            // none of them wants and leaves the note floating in the middle of it.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 280, ideal: 380, maximum: 520),
                detail: DetailPanePolicy(
                    width: PaneWidth(minimum: 360, ideal: 460, maximum: 640),
                    compactWindowWidth: 840
                ),
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 240, ideal: 300, maximum: 400),
                    compactWindowWidth: 1120
                )
            )

        case .notes:
            // The one place the measure rules. `Theme.Size.editorMaxWidth` is roughly eighty
            // characters at the default size, and a column wider than that is a column the eye has
            // to travel back across.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 260, ideal: 340, maximum: 480),
                detail: DetailPanePolicy(
                    width: PaneWidth(minimum: 420, ideal: Theme.Size.editorMaxWidth, maximum: 960),
                    compactWindowWidth: 880
                ),
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 240, ideal: 300, maximum: 400),
                    compactWindowWidth: 1140
                )
            )

        case .projects, .areas:
            // A project is a list of tasks under a brief, so it wants width for the list and not for
            // the prose.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 260, ideal: 340, maximum: 480),
                detail: DetailPanePolicy(
                    width: PaneWidth(minimum: 400, ideal: 560, maximum: 860),
                    compactWindowWidth: 860
                ),
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 240, ideal: 300, maximum: 400),
                    compactWindowWidth: 1140
                )
            )

        case .bookmarks:
            // A URL, a title and a note. There is nothing here that wants six hundred points.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 280, ideal: 380, maximum: 520),
                detail: DetailPanePolicy(
                    width: PaneWidth(minimum: 360, ideal: 460, maximum: 700),
                    compactWindowWidth: 840
                ),
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 240, ideal: 300, maximum: 380),
                    compactWindowWidth: 1120
                )
            )

        case .archive, .trash:
            // Read, decide, restore or empty. Whatever is being looked at is being looked at to find
            // out whether to keep it, which needs enough width to recognise it and no more.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 280, ideal: 380, maximum: 560),
                detail: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 380, ideal: 520, maximum: 800),
                    compactWindowWidth: 880
                ),
                inspector: DetailPanePolicy(
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 240, ideal: 300, maximum: 380),
                    compactWindowWidth: 1120
                )
            )
        }
    }
}

/// The layout used where no module is active — Today, Upcoming, Inbox, a tag, a saved search.
///
/// Its own value rather than a module's, because primary navigation is not inside any module and
/// borrowing one module's judgement for it would mean Today silently inheriting whatever People
/// most recently decided.
public enum PrimaryNavigationLayout {
    public static let shell = ModuleShellLayout(
        primary: PaneWidth(minimum: Theme.Size.listMinWidth, ideal: Theme.Size.listIdealWidth, maximum: 520),
        detail: DetailPanePolicy(
            width: PaneWidth(minimum: Theme.Size.detailMinWidth, ideal: 640, maximum: 900),
            compactWindowWidth: 860
        ),
        inspector: DetailPanePolicy(
            hidesWhenNothingSelected: true,
            width: PaneWidth(
                minimum: InspectorLayout.minimumWidth,
                ideal: InspectorLayout.idealWidth,
                maximum: InspectorLayout.maximumWidth
            ),
            compactWindowWidth: 1140
        )
    )
}

extension Optional where Wrapped == AppModule {
    /// The layout in force, module or not.
    public var shellLayout: ModuleShellLayout {
        self?.shellLayout ?? PrimaryNavigationLayout.shell
    }
}
