import AppKit
import ElephruitCore
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
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
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
            return false
        }

        let started = startTimerIfIdle()

        if let panel {
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            NSApp.activate()
            return started
        }

        previousApplication = NSWorkspace.shared.frontmostApplication

        let hosting = NSHostingView(
            rootView: QuickLogView(controller: self).appServices(services)
        )
        hosting.sizingOptions = [.preferredContentSize]

        // A `.titled` window has a title bar whether or not one is drawn, and AppKit reports a
        // 32-point top safe-area inset for it even with the bar hidden, transparent, and the content
        // told to fill the frame. SwiftUI honours that, so everything in the panel sat a title bar's
        // height below where this file says it does. Nothing is clipped here — the window is roomier
        // than its contents — but the panel was hanging low in its own window for no reason anybody
        // reading the layout could have seen. See ``MiniTimerController``, where the same inset cost
        // the collapsed timer its bottom edge.
        hosting.safeAreaRegions = []

        let panel = QuickLogPanel(content: hosting)
        panel.center()
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        // Without this the panel is key but the app is not active, so the caret does not blink and
        // the first keystroke can be swallowed — which on a field somebody is typing a name into as
        // fast as they can think of one is the difference between working and infuriating.
        NSApp.activate()
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
        return true
    }

    /// Fills the name from whatever is running, so replacement confirmation describes the current
    /// work rather than whatever was last typed here.
    public func syncFromRunning() {
        description = services.timer.running?.entryDescription ?? ""
    }

    /// Writes the name down and closes, leaving the clock running.
    public func hide() {
        commitDescription()
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
        services.timer.setDescription(description)
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
