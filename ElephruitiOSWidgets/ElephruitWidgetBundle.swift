import SwiftUI
import WidgetKit

/// The extension's one entry point.
///
/// A bundle with a single member today. It exists rather than a bare `@main` widget because
/// the next thing this extension is asked for — a Home Screen widget showing today's tracked
/// total — is added by putting a line in here, not by rebuilding the target.
@main
struct ElephruitWidgetBundle: WidgetBundle {
    var body: some Widget {
        TimerLiveActivity()
    }
}
