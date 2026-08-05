import UIKit

/// The keyboard, from the shell's side of it: bought early, and put away on the way out.
///
/// Both of these live here because they are the app's business rather than any one field's. A
/// `FocusState` belongs to the view that owns the field; neither warming the keyboard before
/// anybody has typed nor dismissing it because the user is leaving the screen has an owner among
/// the fields themselves.
@MainActor
enum Keyboard {
    // MARK: - Buying it early

    private static var hasWarmed = false

    /// How long to wait before spending anything. Long enough for the first screen to have drawn
    /// and settled: the point is to move this work off the critical path, not to move it onto the
    /// launch path instead.
    private static let warmupDelay = Duration.milliseconds(600)

    /// Pays for the first keyboard before anybody is waiting on it.
    ///
    /// The first `becomeFirstResponder` in a process does far more than raise a keyboard: it
    /// builds UIKit's text-input machinery and connects to the keyboard's own process, and that
    /// connection is slow — a real phone logged `Took 1.12s to get the token` for it. Every
    /// millisecond of it used to be charged to whoever typed first, which on this app is someone
    /// who tapped a reminder and watched the list do nothing for two seconds.
    ///
    /// So the app buys it up front, in the quiet moment after launch while the user is still
    /// reading the first screen. The field is never seen and never typed into: it takes first
    /// responder and gives it up within one turn of the run loop, which is not long enough for a
    /// keyboard to animate and quite long enough for everything behind it to be built and cached.
    ///
    /// Once, and never again — the cost is a first-time cost, and a second helping would only
    /// take focus from someone who by then may be using it.
    static func warmAfterLaunch() async {
        guard !hasWarmed else { return }
        try? await Task.sleep(for: warmupDelay)
        guard !Task.isCancelled else { return }
        warm()
    }

    private static func warm() {
        // No window yet means no first responder is possible; leaving `hasWarmed` alone lets a
        // later call try again rather than silently deciding the job is done.
        guard !hasWarmed, let window = keyWindow else { return }
        // Nobody may be typing: taking the keyboard from a field someone is using would be a much
        // worse bug than the slow tap this exists to fix.
        guard window.firstResponderIsAbsent else { return }

        hasWarmed = true

        let field = UITextField(frame: .zero)
        window.addSubview(field)
        field.becomeFirstResponder()
        field.resignFirstResponder()
        field.removeFromSuperview()
    }

    // MARK: - Putting it away

    /// Dismisses whatever keyboard is up, whoever raised it.
    ///
    /// Asked of the responder chain rather than of a particular field, because the caller is the
    /// shell: it knows the user is leaving, not who was typing. A screen left with the keyboard
    /// still standing is the one arrangement nobody asks for — the drawer arrives, and half of
    /// what it slid over is still covered by a keyboard belonging to a field that is no longer on
    /// screen.
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private extension UIView {
    /// Whether nothing in this view's tree currently holds first responder.
    ///
    /// `UIResponder.currentFirstResponder` is private API; walking the tree is the supported way
    /// to ask, and the tree in question is one window at launch.
    var firstResponderIsAbsent: Bool {
        !isFirstResponder && subviews.allSatisfy(\.firstResponderIsAbsent)
    }
}
