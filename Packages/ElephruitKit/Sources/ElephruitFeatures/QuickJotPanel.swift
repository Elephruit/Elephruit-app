import AppKit
import ElephruitCore
import ElephruitModel
import SwiftUI

/// The floating capture window.
///
/// An `NSPanel` rather than a sheet on the main window, because the whole point is to work when
/// Elephruit is not what you are looking at. A sheet cannot appear without its window, and its
/// window cannot appear without taking over the screen you were using.
///
/// `.nonactivatingPanel` is deliberate: the panel takes key focus for typing without making
/// Elephruit the active application, so dismissing it returns you to what you were doing rather
/// than to an app you did not ask to switch to.
final class QuickJotPanel: NSPanel {
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
        // Appears over full-screen apps, which is most of when capture is wanted.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false

        contentView = content
    }

    /// Panels are not key by default, and a capture field that cannot be typed into is not capture.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Makes the title the typing destination whenever the shortcut raises this panel.
    ///
    /// The panel is retained when hidden, so the title's `viewDidMoveToWindow` hook only covers its
    /// first presentation. A later invocation must take focus back from whichever chip or button
    /// was last used before the panel disappeared.
    func focusTitle() {
        contentView?.layoutSubtreeIfNeeded()
        if focusTitleIfPresent() { return }

        // `NSHostingView` may finish materialising its represented views on the next run-loop turn.
        // Retry once after that work rather than assuming the hierarchy is already complete.
        DispatchQueue.main.async { [weak self] in
            _ = self?.focusTitleIfPresent()
        }
    }

    @discardableResult
    private func focusTitleIfPresent() -> Bool {
        guard let title = contentView?.firstDescendant(of: TokenisedTextView.self) else { return false }
        return makeFirstResponder(title)
    }
}

private extension NSView {
    func firstDescendant<View: NSView>(of type: View.Type) -> View? {
        if let match = self as? View { return match }
        return subviews.lazy.compactMap { $0.firstDescendant(of: type) }.first
    }
}

/// Owns the one panel, what has been composed in it, and where focus goes when it closes.
///
/// ### Why the draft lives here rather than in the view
/// The view is destroyed when the panel closes, so `@State` on it means the work is gone the moment
/// the panel loses its window — which turns an accidental dismissal into lost work. Holding it here
/// makes "reopening gets your text back" the default rather than a feature.
///
/// That argument got stronger when the composer stopped being a string. What is now at stake on an
/// accidental dismissal is a title, a body, and a set of chips that may have taken four trips through
/// a menu to assemble.
@MainActor
@Observable
public final class QuickJotController {
    /// What has been composed. Survives the panel being closed.
    public var composition = QuickJotComposition()

    /// The most recent failure, kept so the panel can stay open and explain itself.
    public var lastError: AppError?

    /// What the last save did, shown briefly before the panel excuses itself.
    ///
    /// The panel used to close in silence — the product's headline flow ended with no
    /// confirmation, no destination, and no way to notice a mistyped project had filed the
    /// thought to the Inbox. The error path was better instrumented than the success path.
    public private(set) var confirmation: CaptureConfirmation?

    /// The scheduled hide, cancellable so rapid-fire capture keeps the panel open.
    private var confirmationDismiss: Task<Void, Never>?

    public private(set) var isVisible = false

    private var panel: QuickJotPanel?

    /// What was frontmost when the panel opened, so it can be given focus back.
    ///
    /// ### Why this is not used to activate anything
    /// It used to be. `previousApplication.activate()` reaches *into another process* to bring it
    /// forward, which is the sort of operation the sandbox is entitled to refuse and which fails
    /// outright once that process has quit — and a process quitting while a floating capture panel
    /// is open is not a rare case, it is Tuesday. `NSRunningApplication` also went on being held
    /// after the panel closed, so a terminated application stayed referenced indefinitely.
    ///
    /// macOS 14 added ``NSApplication/yieldActivation(to:)`` for exactly this: the app *gives up*
    /// its own activation and names who should have it, and the window server does the rest. It
    /// asks nothing of the other process, so there is nothing for a dead one to refuse. The
    /// reference is kept only to name the recipient and to check it is still alive, and is released
    /// the moment the panel closes.
    private var previousApplication: NSRunningApplication?

    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    /// Shows the panel, or brings the existing one forward.
    ///
    /// Pressing the shortcut twice must focus the panel that is already open rather than stack a
    /// second one on top of it — the single most obvious way a global capture window goes wrong.
    public func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            panel.focusTitle()
            isVisible = true
            return
        }

        previousApplication = NSWorkspace.shared.frontmostApplication

        let hosting = NSHostingView(
            rootView: QuickJotView(controller: self).appServices(services)
        )
        hosting.sizingOptions = [.preferredContentSize]

        let panel = QuickJotPanel(content: hosting)
        panel.center()
        self.panel = panel

        panel.makeKeyAndOrderFront(nil)
        // Without this the panel is key but the app is not active, so the caret does not blink and
        // the first keystroke can be swallowed.
        NSApp.activate()
        panel.focusTitle()
        isVisible = true
    }

    /// Hides the panel and gives focus back to whatever had it.
    ///
    /// The text is deliberately **not** cleared. Closing is not the same as discarding, and someone
    /// who dismissed by accident should find their sentence still there.
    public func hide() {
        panel?.orderOut(nil)
        isVisible = false
        lastError = nil
        restoreFocus()
    }

    /// Hides and clears — what a successful save does.
    public func hideAfterSaving() {
        composition = QuickJotComposition()
        hide()
    }

    /// Hands activation back to whatever had it, without touching that process.
    ///
    /// Three ways this can be asked and cannot be answered, each handled rather than attempted:
    /// there was nothing frontmost, the thing that was frontmost was *us*, or it has since quit.
    /// The last is the one that matters — a capture panel is open precisely while somebody is doing
    /// something else, and that something else is free to end.
    private func restoreFocus() {
        defer { previousApplication = nil }

        guard let previousApplication,
              previousApplication.bundleIdentifier != Bundle.main.bundleIdentifier,
              !previousApplication.isTerminated
        else { return }

        NSApp.yieldActivation(to: previousApplication)
    }

    /// Captures what has been composed.
    ///
    /// Returns whether anything was saved, so the caller can decide what to do next. On failure the
    /// panel stays open with everything intact — losing someone's sentence because the store was busy
    /// would be the worst possible response to a recoverable error.
    ///
    /// The flush happens first and is kept even if the save then fails. It is the last chance for a
    /// token the user finished typing but never terminated — `Prep due:friday` with the caret still
    /// against the `y` — to become a chip rather than nothing, and having done it there is no reason
    /// to undo it. Whether there is anything worth saving is decided by ``AppServices/captureDraft``,
    /// which returns `nil` for a capture with nothing in it.
    @discardableResult
    public func save() -> Bool {
        let vocabulary = (try? services.capture.vocabulary()) ?? .empty
        composition.flush(knowing: vocabulary)

        do {
            guard let item = try services.captureDraft(composition.captured(knowing: vocabulary))
            else { return false }

            // The composition resets *now*, so a second thought can be typed straight over the
            // confirmation — capture must never make somebody wait to capture again.
            composition = QuickJotComposition()
            lastError = nil
            confirmation = CaptureConfirmation(item: item)

            confirmationDismiss?.cancel()
            confirmationDismiss = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1200))
                guard !Task.isCancelled, let self else { return }
                // Hide only if nothing new is being typed — a panel that vanishes mid-sentence
                // is worse than the silence this replaces.
                if self.composition.isEmpty {
                    self.hide()
                }
                self.confirmation = nil
            }
            return true
        } catch {
            lastError = error
            return false
        }
    }
}

/// Where a capture landed, for the one-line receipt the panel shows before closing.
public struct CaptureConfirmation: Equatable, Sendable {
    /// "Inbox", or the container's own name.
    public let destination: String

    /// The container's palette colour, so the receipt matches the sidebar.
    public let colorName: String?

    /// Whether what was created can turn overdue — a reminder rather than a note.
    public let isReminder: Bool

    @MainActor
    init(item: Item) {
        if let parent = item.parent {
            destination = parent.displayTitle
            colorName = parent.colorName
        } else {
            destination = "Inbox"
            colorName = nil
        }
        isReminder = item.kind == .reminder || item.kind == .task
    }
}
