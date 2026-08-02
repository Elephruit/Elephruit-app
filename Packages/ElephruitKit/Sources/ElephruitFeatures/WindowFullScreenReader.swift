import AppKit
import SwiftUI

/// Reports the presentation state of the exact window containing the SwiftUI hierarchy.
///
/// A unified macOS toolbar uses a different leading origin in full screen because the traffic
/// lights disappear. SwiftUI does not expose that state through the environment, so the shell uses
/// this zero-sized marker to keep its title aligned with the content edge in both presentations.
struct WindowFullScreenReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> FullScreenObservingView {
        FullScreenObservingView { value in
            if isFullScreen != value {
                isFullScreen = value
            }
        }
    }

    func updateNSView(_ view: FullScreenObservingView, context: Context) {
        view.onChange = { value in
            if isFullScreen != value {
                isFullScreen = value
            }
        }
        view.reportCurrentState()
    }
}

@MainActor
final class FullScreenObservingView: NSView {
    var onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        NotificationCenter.default.removeObserver(self)
        guard let window else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPresentationChanged),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPresentationChanged),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
        reportCurrentState()
    }

    func reportCurrentState() {
        guard let window else { return }
        onChange(window.styleMask.contains(.fullScreen))
    }

    @objc private func windowPresentationChanged() {
        reportCurrentState()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
