import AppKit
import ElephruitCore
import ElephruitModel
import ElephruitPersistence
import SwiftUI

/// What Quick Log is asking the user to do.
///
/// An existing timer is a decision boundary, not an editing surface. Keeping that state explicit
/// prevents the shortcut from silently turning "start something new" into "rename what is already
/// running", and gives the view a stable state to render while the current timer remains untouched.
public enum QuickLogPresentation: Sendable, Equatable {
    case editing
    case confirmReplacement
}

/// The floating window that starts a timer from wherever you are.
///
/// A sibling of ``QuickJotPanel`` in every structural respect, and for the same reason: the moment
/// you want it is a moment when Elephruit is not what you are looking at. A sheet cannot appear
/// without its window, and its window cannot appear without taking over the screen you were using.
///
/// `.nonactivatingPanel` is deliberate here for a second reason on top of that one. Starting to time
/// a phone call should not switch you out of the application the call is about — the clock has to
/// begin *behind* what you are doing, not in front of it.
final class QuickLogPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        // Appears over full-screen apps, which is most of when a timer is wanted.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false

        contentView = content
    }

    /// A panel is not key by default, and a name field that cannot be typed into is not naming.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Makes the description the typing destination whenever an editable Quick Log is raised.
    ///
    /// The SwiftUI focus state handles ordinary transitions, but the panel itself is retained when
    /// hidden and its represented AppKit field may materialise a run-loop turn after the hosting
    /// view. The explicit responder handoff is what guarantees the first keystroke lands in the
    /// description on both the first opening and every reopening.
    func focusDescription() {
        contentView?.layoutSubtreeIfNeeded()
        if focusDescriptionIfPresent() { return }

        DispatchQueue.main.async { [weak self] in
            _ = self?.focusDescriptionIfPresent()
        }
    }

    @discardableResult
    private func focusDescriptionIfPresent() -> Bool {
        guard let editor = contentView?.quickLogDescendant(of: CaptureNotesTextView.self) else {
            return false
        }
        return makeFirstResponder(editor)
    }
}

private extension NSView {
    func quickLogDescendant<View: NSView>(of type: View.Type) -> View? {
        if let match = self as? View { return match }
        return subviews.lazy.compactMap { $0.quickLogDescendant(of: type) }.first
    }
}

/// Owns the one panel, the name being typed into it, and where focus goes when it closes.
///
/// ### The promise this makes, which is the whole feature
/// With nothing running, pressing the shortcut **starts the clock first and asks afterwards**.
/// Everything the panel offers — what the time is against, which project it is billed to, who was
/// there, how it is tagged — is filled in while the seconds are already accumulating. When work is
/// already being timed, the panel preserves that entry and asks before stopping and replacing it.
///
/// That is not a new rule invented here. It is exactly what the Start button in the Time module
/// does, and this is the same button reachable from a spreadsheet, a video call, or a terminal.
///
/// ### Why closing does not stop anything
/// Because the panel is a way of *describing* a timer, not the timer itself. Dismissing it leaves
/// the clock running and the name typed so far written down — the menu bar goes on showing the
/// elapsed time, which is where the answer lives once this window is gone. Ending the work is Stop,
/// and throwing it away is Discard; both say so, and neither is Escape.
@MainActor
@Observable
public final class QuickLogController {
    /// What the entry is being called. Held here rather than in the view for the reason Quick Jot
    /// holds its text here: the view is destroyed with its window, and a name half-typed when
    /// somebody dismissed by accident should not be a name lost.
    ///
    /// Written to the running entry by every path that closes the panel, so there is no exit that
    /// silently drops it.
    public var description: String = ""

    public private(set) var isVisible = false

    /// Whether the panel is naming a timer it just started or asking about one already in progress.
    public private(set) var presentation: QuickLogPresentation = .editing

    /// Whether the timer on screen is one this panel started.
    ///
    /// A timer the panel started is editable immediately; a timer already in progress first produces
    /// a replacement confirmation. This flag lets the editable state describe its origin accurately.
    public private(set) var startedTheTimer = false

    private var panel: QuickLogPanel?

    /// What was frontmost when the panel opened, so it can be given focus back.
    ///
    /// Handed back with ``NSApplication/yieldActivation(to:)`` rather than by reaching into that
    /// process — see ``QuickJotController`` for the whole argument, which applies here unchanged and
    /// applies *more*: a timer panel is open precisely while somebody is working in another app, and
    /// that app is free to quit while it stands there.
    private var previousApplication: NSRunningApplication?

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// Starts timing, then shows the panel over whatever you were doing.
    ///
    /// Pressing the shortcut twice brings the panel already on screen forward rather than stacking a
    /// second one behind it, and — because the first press left a timer running — the second press
    /// starts nothing. Both halves matter: a global shortcut that produced a new untitled entry every
    /// time it was pressed would fill a log with rubbish faster than anybody could delete it.
    ///
    /// Returns whether a timer was started, so a caller that wants to say so can.
    @discardableResult
    public func show() -> Bool {
        // Repeating the shortcut while the panel is already open means "bring this forward", not
        // "reconsider the timer beneath it". In particular, do not replace an unfinished name in
        // the field with the last value committed to the store.
        if isVisible, let panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate()
            if presentation == .editing { panel.focusDescription() }
            return false
        }

        let started = startTimerIfIdle()

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            NSApp.activate()
            if presentation == .editing { panel.focusDescription() }
            return started
        }

        previousApplication = NSWorkspace.shared.frontmostApplication

        let hosting = NSHostingView(
            rootView: QuickLogView(controller: self).appServices(services)
        )
        hosting.sizingOptions = [.preferredContentSize]

        let panel = QuickLogPanel(content: hosting)
        panel.center()
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        // Without this the panel is key but the app is not active, so the caret does not blink and
        // the first keystroke can be swallowed — which on a field somebody is typing a name into as
        // fast as they can think of one is the difference between working and infuriating.
        NSApp.activate()
        if presentation == .editing { panel.focusDescription() }
        isVisible = true
        return started
    }

    /// Begins timing if nothing is, and says whether it did.
    ///
    /// Untitled, exactly as the Start button in the tracker is: requiring a name before the clock
    /// starts is the friction this whole arrangement exists to remove.
    @discardableResult
    public func startTimerIfIdle() -> Bool {
        guard services.timer.running == nil else {
            startedTheTimer = false
            presentation = .confirmReplacement
            syncFromRunning()
            return false
        }

        // `switchTo` rather than `start`, so this is the same call the tracker's Start button makes
        // and a fresh sitting begins with a clock at zero. Nothing is running, so nothing is stopped.
        services.timer.switchTo(item: nil)
        startedTheTimer = services.timer.running != nil
        presentation = .editing
        description = ""
        return startedTheTimer
    }

    /// Stops the timer the confirmation described and begins a blank replacement.
    ///
    /// `switchTo` is one repository operation: it closes the current entry with its description,
    /// subject, project, people, tags and billable flag intact, then creates the new running entry.
    /// Nothing is cleared until that transition succeeds.
    @discardableResult
    public func replaceRunningTimer() -> Bool {
        guard services.timer.running != nil else { return startTimerIfIdle() }

        guard services.timer.switchTo(item: nil), services.timer.running != nil else { return false }
        startedTheTimer = true
        presentation = .editing
        description = ""

        // The button began in the confirmation hierarchy. Let SwiftUI replace that hierarchy with
        // the editor before asking AppKit for its first responder; `focusDescription()` supplies one
        // further retry if the represented text view materialises on the following turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == .editing else { return }
            self.panel?.focusDescription()
        }
        return true
    }

    /// Fills the name from whatever is running, so replacement confirmation describes the current
    /// work rather than whatever was last typed here.
    public func syncFromRunning() {
        description = services.timer.running?.entryDescription ?? ""
    }

    /// Writes the name down and closes, leaving the clock running.
    public func hide() {
        // The confirmation state is read-only. In particular, a `#` that was already part of the
        // saved description must not suddenly become filing merely because the shortcut was pressed
        // and Keep Timing was chosen.
        if presentation == .editing {
            commitDescription()
        }
        panel?.orderOut(nil)
        isVisible = false
        restoreFocus()
    }

    /// Stops the timer, keeping the time, and closes.
    public func stopTimer() {
        commitDescription()
        services.timer.stop()
        description = ""
        hide()
    }

    /// Throws the entry away as though it had never been started, and closes.
    ///
    /// The answer to a shortcut pressed by accident. Without it, a mistaken ⌘⇧L leaves a stray entry
    /// in the log that has to be found and deleted later, which is a worse tax than the mistake.
    public func discardTimer() {
        services.timer.discard()
        description = ""
        // Nothing to commit — the entry it would have been written to no longer exists.
        panel?.orderOut(nil)
        isVisible = false
        restoreFocus()
    }

    /// Puts what has been typed onto the running entry.
    ///
    /// Called by every exit rather than on every keystroke. A description is something you finish
    /// typing before you care that it is saved, and a write per character would be a thousand saves
    /// for one sentence — but an exit that did not write would be a name typed and thrown away.
    public func commitDescription() {
        guard services.timer.running != nil else { return }

        let vocabulary = (try? services.capture.vocabulary()) ?? .empty
        let parsed = CaptureParser.parse(description, knowing: vocabulary)
        services.timer.setDescription(parsed.title)

        if !parsed.tagSlugs.isEmpty, let running = services.timer.running {
            services.timer.setTags(orderedUnion(running.tagSlugs, parsed.tagSlugs))
        }

        if let projectHint = parsed.projectHint,
           let project = try? services.capture.resolveContainer(named: projectHint) {
            services.timer.setProject(project)
        }

        if !parsed.personHints.isEmpty, let running = services.timer.running {
            let existing = running.people.compactMap { try? services.items.item(id: $0.id) }
            let mentioned = parsed.personHints.compactMap {
                try? services.persons.resolveOrCreatePlaceholder(named: $0)
            }
            let people = (existing + mentioned).reduce(into: [Item]()) { result, person in
                guard !result.contains(where: { $0.id == person.id }) else { return }
                result.append(person)
            }
            services.timer.setPeople(people)
        }

        description = parsed.title
    }

    private func orderedUnion(_ existing: [String], _ additions: [String]) -> [String] {
        additions.reduce(into: existing) { result, value in
            guard !result.contains(value) else { return }
            result.append(value)
        }
    }

    /// Hands activation back to whatever had it, without touching that process.
    private func restoreFocus() {
        defer { previousApplication = nil }

        guard let previousApplication,
              previousApplication.bundleIdentifier != Bundle.main.bundleIdentifier,
              !previousApplication.isTerminated
        else { return }

        NSApp.yieldActivation(to: previousApplication)
    }

    /// Closes the panel and forgets it, for window teardown and tests.
    public func shutDown() {
        panel?.orderOut(nil)
        panel = nil
        isVisible = false
        previousApplication = nil
    }
}
