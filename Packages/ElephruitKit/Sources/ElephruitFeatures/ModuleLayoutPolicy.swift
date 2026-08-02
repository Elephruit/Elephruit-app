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
            // A document module whose document is the profile, and the *only* one whose profile is
            // unbounded.
            //
            // ### Why the profile has no maximum any more
            // Because it had one, and it was the narrowest usable thing on the screen. A populated
            // profile carries an identity header, a row of actions, structured facts, contact
            // methods, relationships and a history; every one of those degrades into a column of
            // wrapped fragments below about 480, and it was capped at 820 while the list beside it
            // grew to 380 and an inspector took another 420. On a wide window the spare width went
            // to the list first — a column of names and companies, which is a longer line of the
            // same two fields — and then stopped, because everything had a ceiling and nothing
            // absorbed the remainder.
            //
            // An unbounded column is what the shell already gives a canvas module: it is settled
            // after the others have said what they need, and takes what is left. That is the right
            // description of a profile *in this module*, because the profile is what the module is
            // for. It caps its own reading measure rather than stretching — see
            // ``PersonWorkspaceView`` — so "no maximum" means margins grow, not paragraphs.
            //
            // The list is narrower and firmly bounded. Two hundred and eighty is a comfortable
            // avatar, name and company; three hundred and forty is as wide as that can usefully get,
            // and past it the column is spending the profile's width on whitespace beside a name.
            //
            // The minimum is what a 900-point window — the smallest this app opens at — can spare
            // once the sidebar and the list have theirs. It is not where a profile is *comfortable*;
            // that is nearer the ideal, and the whole point of removing the maximum is that a
            // profile reaches it and keeps going.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 220, ideal: 280, maximum: 340),
                detail: DetailPanePolicy(
                    hidesWhenNothingSelected: false,
                    width: PaneWidth(minimum: 450, ideal: 680),
                    // The app's own minimum window. The profile column appears as soon as there is a
                    // window that can hold it, because a People module with no profile in it is a
                    // list of names.
                    compactWindowWidth: 900
                ),
                inspector: DetailPanePolicy(
                    // ### Why selecting somebody no longer opens the inspector
                    // It did, and that is why the third column read as permanent: `.people` said
                    // `opensAfterSelection`, so clicking any name reopened a pane the user may have
                    // closed twenty names ago. A pane that reappears whenever you navigate is not a
                    // contextual inspector; it is a fourth column with a dismiss button.
                    //
                    // It is worth having on demand — ⌥⌘I, or the toolbar — because it answers a
                    // question the profile does not: what is *scheduled*, what is open, what is
                    // worth checking. What it no longer does is assume you want it every time.
                    opensAfterSelection: false,
                    hidesWhenNothingSelected: true,
                    width: PaneWidth(minimum: 260, ideal: 300, maximum: 360),
                    // Higher than it was. The inspector may only appear once the profile already has
                    // the room it needs; below this the arithmetic can satisfy every minimum and
                    // still leave the main content the narrowest thing on screen.
                    compactWindowWidth: 1280
                )
            )

        case .tasks:
            // ### Why Tasks became a canvas
            // It was a document module: a list of tasks on the left, one task at length on the
            // right. The right-hand column had to answer "which task is this?" all over again —
            // a title bar, the container, the dates — because by the time you were reading it the
            // list was three hundred points away and might have scrolled. Everything on it was a
            // restatement of something already on screen.
            //
            // A task now opens by making its own row taller — see ``TaskCard`` — so the detail
            // column has nothing left to hold. It goes, and the list takes the width: a list of
            // tasks *is* the module, the same way a month is the Calendar.
            ModuleShellLayout(
                primary: PaneWidth(minimum: 420, ideal: 900),
                detail: .unavailable,
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

/// What Today asks of the shell.
///
/// ### Why Today is a canvas and Inbox is not
/// They are both primary navigation and they want opposite shapes. Inbox is a list of captured
/// records that you open one at a time, so it wants a narrow column and a wide reading surface
/// beside it. Today is not a list of anything — it is a briefing, a timeline, work, and people,
/// arranged together — and every one of those degrades into a column of wrapped fragments at the
/// 340 points a list column gets. Squeezing it into the middle of a three-column shell would be the
/// calendar's old bug again: the thing the destination exists to show, drawn in a third of the
/// window, beside 720 points of "Nothing selected".
///
/// So the primary column is unbounded and takes the window, exactly as the calendar's and the time
/// sheet's do. The page constrains its own measure from the inside — see ``TodayView`` — because a
/// briefing stretched across an ultrawide display is not a better briefing.
///
/// The detail column is gone and the inspector stays. There is nothing for a third column to be
/// *about* until something is selected, and when something is, the inspector is the right size for
/// it: a task has a title, three dates, a project and some tags, none of which is prose.
public enum TodayLayout {
    public static let shell = ModuleShellLayout(
        // No maximum, which is what makes it a canvas: it asks for whatever is left rather than for
        // a number. The minimum is what the day's two columns — the date rail and the day — need
        // before the rail folds away.
        primary: PaneWidth(minimum: 420, ideal: 980),
        detail: .unavailable,
        inspector: DetailPanePolicy(
            hidesWhenNothingSelected: true,
            width: PaneWidth(
                minimum: InspectorLayout.minimumWidth,
                ideal: InspectorLayout.idealWidth,
                maximum: InspectorLayout.maximumWidth
            ),
            compactWindowWidth: 1100
        )
    )
}

/// The layout used where no module is active and the destination is an ordinary list — Inbox, a tag,
/// a saved search.
///
/// Its own value rather than a module's, because primary navigation is not inside any module and
/// borrowing one module's judgement for it would mean Inbox silently inheriting whatever People
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

extension NavigationModel {
    /// The layout the shell should be wearing right now.
    ///
    /// ### Why this asks the selection and not only the module
    /// Because the module was the only thing asked, and outside a module there is exactly one
    /// answer — which was fine while every module-less destination was a list. Today is not, and a
    /// window that reads the module alone gives the day a 340-point column. The module still decides
    /// wherever there is one; this is the one destination that has an opinion of its own.
    public var shellLayout: ModuleShellLayout {
        guard activeModule == nil else { return activeModule.shellLayout }
        return selection.canonical == .today ? TodayLayout.shell : PrimaryNavigationLayout.shell
    }
}
