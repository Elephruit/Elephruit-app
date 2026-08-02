import Foundation

/// Where a task can be found, for somebody arriving at it from outside the task list.
///
/// ### Why this question exists at all
/// A task used to be openable anywhere: select it, and a detail pane drew it. Now it opens by making
/// its own row taller in the list it lives in, which means following a link to a task is a
/// *navigation* — you have to end up somewhere the task is drawn. This decides where.
///
/// It answers only the case where the task has no container of its own. A task filed under a project
/// or a list is opened in that project or list, which the caller can see without asking; a loose
/// task is in whichever system view its dates and marks put it in, which is this.
public enum TaskHome {
    /// The system view a container-less task will actually appear in.
    ///
    /// ### Why Upcoming is never the answer
    /// Upcoming is drawn as an agenda of days rather than as a list of rows, and a card cannot open
    /// in it. A task whose start date is in the future is genuinely *in* Upcoming — but sending
    /// somebody there to open it would land them on a surface that cannot. Anytime is the honest
    /// second answer: the task is there too, as soon as its date arrives, and the list can open it
    /// today.
    ///
    /// ``TaskSystemView/all`` is the last resort, and it holds everything by definition, so this
    /// never fails to name somewhere the task really is.
    public static func systemView(
        for facts: TaskFacts,
        now: Date,
        calendar: Calendar
    ) -> TaskSystemView {
        if !facts.lifecycle.isOpen { return .completed }
        if TaskViewRules.isInInbox(facts) { return .inbox }
        if TaskViewRules.isInSomeday(facts) { return .someday }
        if TaskViewRules.todaySection(for: facts, now: now, calendar: calendar) != nil { return .today }
        if TaskViewRules.isInAnytime(facts, now: now, calendar: calendar) { return .anytime }
        return .all
    }
}
