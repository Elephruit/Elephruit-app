@testable import ElephruitFeatures
import Testing

/// The filter rail's selection rules, pinned.
///
/// Worth tests despite being a small value type, because the rules are conventions borrowed from
/// macOS selection at large — plain click replaces, command-click extends, clicking the only
/// selection clears — and a filter that drifts from platform selection behaviour feels broken in
/// a way nobody can name.
@Suite("Reminder tag selection")
struct ReminderTagSelectionTests {
    @Test("A plain click replaces the filter and clicking it again shows all")
    func plainClickSelectsOne() {
        var selection = ReminderTagSelection()

        selection.select("work", extending: false)
        selection.select("home", extending: false)
        #expect(selection.slugs == ["home"])

        selection.select("home", extending: false)
        #expect(selection.showsAll)
    }

    @Test("Command-click adds and removes individual filters")
    func commandClickExtendsSelection() {
        var selection = ReminderTagSelection()

        selection.select("work", extending: false)
        selection.select("home", extending: true)
        #expect(selection.slugs == ["work", "home"])

        selection.select("work", extending: true)
        #expect(selection.slugs == ["home"])
    }

    @Test("Multiple tags include reminders matching any selected filter")
    func multipleTagsAreInclusive() {
        var selection = ReminderTagSelection()
        selection.select("work", extending: false)
        selection.select("home", extending: true)

        #expect(selection.includes(tagSlugs: ["work", "urgent"]))
        #expect(selection.includes(tagSlugs: ["home"]))
        #expect(!selection.includes(tagSlugs: ["errands"]))
        #expect(!selection.includes(tagSlugs: []))
    }

    @Test("Unavailable tags leave the selection")
    func unavailableTagsAreReconciled() {
        var selection = ReminderTagSelection()
        selection.select("work", extending: false)
        selection.select("home", extending: true)

        selection.reconcile(availableSlugs: ["home", "errands"])

        #expect(selection.slugs == ["home"])
    }

    @Test("Showing all includes everything, tagged or not")
    func showAllIncludesEverything() {
        let selection = ReminderTagSelection()
        #expect(selection.includes(tagSlugs: []))
        #expect(selection.includes(tagSlugs: ["anything"]))
    }
}

/// How completion visibility and tag filtering compose.
@Suite("Reminder visibility")
struct ReminderVisibilityTests {
    @Test("Completed reminders are hidden by default")
    func completedHiddenByDefault() {
        let visibility = ReminderVisibility()

        #expect(visibility.includes(isCompleted: false, tagSlugs: []))
        #expect(!visibility.includes(isCompleted: true, tagSlugs: []))
    }

    @Test("Enabling Completed reveals them")
    func showingCompletedRevealsThem() {
        var visibility = ReminderVisibility()
        visibility.showsCompleted = true

        #expect(visibility.includes(isCompleted: true, tagSlugs: []))
        #expect(visibility.includes(isCompleted: false, tagSlugs: []))
    }

    @Test("Completion visibility and tag filters compose, not override")
    func filtersCompose() {
        var visibility = ReminderVisibility()
        visibility.tags.select("work", extending: false)

        // Open and tagged: visible. Open but untagged: filtered out.
        #expect(visibility.includes(isCompleted: false, tagSlugs: ["work"]))
        #expect(!visibility.includes(isCompleted: false, tagSlugs: ["home"]))

        // Completed and tagged: the tag matches, but completion still hides it.
        #expect(!visibility.includes(isCompleted: true, tagSlugs: ["work"]))

        // Showing completed lets the tag filter speak for completed reminders too.
        visibility.showsCompleted = true
        #expect(visibility.includes(isCompleted: true, tagSlugs: ["work"]))
        #expect(!visibility.includes(isCompleted: true, tagSlugs: ["home"]))
    }
}
