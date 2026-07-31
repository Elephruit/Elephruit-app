import SwiftUI

/// How an inspector row arranges its label and its control.
///
/// The previous inspector gave the label a fixed 78pt column and let the control have whatever was
/// left. At the pane's own 280pt ideal width that left roughly 162pt, and a three-way segmented
/// control needs about 240 — so "Cancelled" was cut off and the tag field ran past the edge. The
/// control had a larger intrinsic width than the space it was given, and nothing yielded.
///
/// The fix is to let the *arrangement* change rather than the content be cut.
public enum InspectorLayoutStyle: Sendable, Hashable, CaseIterable {
    /// Label beside control. Comfortable, scannable — the eye follows one column of values.
    case inline

    /// Label above control, control at full width. Used when a side-by-side row would squeeze the
    /// control below its intrinsic size.
    case stacked
}

/// Chooses the arrangement, and states what each one costs.
public enum InspectorLayout {
    /// Below this width, a label column plus a control no longer both fit comfortably.
    ///
    /// Derived rather than guessed: the widest control in the inspector is the status picker, the
    /// label column is ``labelColumnWidth``, and the insets are known. 300 is where those stop
    /// fitting side by side at the standard text size, with a little headroom.
    public static let stackingBreakpoint: CGFloat = 300

    /// The label column in ``InspectorLayoutStyle/inline``.
    public static let labelColumnWidth: CGFloat = 78

    /// Gap between label and control when inline.
    public static let labelGap: CGFloat = 8

    /// The inspector's own horizontal padding, both edges combined.
    public static let horizontalPadding: CGFloat = 32

    /// The narrowest the inspector pane may be.
    public static let minimumWidth: CGFloat = 240
    public static let idealWidth: CGFloat = 300
    public static let maximumWidth: CGFloat = 420

    /// The arrangement for a given pane width.
    ///
    /// Pure, so the decision is testable without rendering anything.
    public static func style(forWidth width: CGFloat) -> InspectorLayoutStyle {
        width >= stackingBreakpoint ? .inline : .stacked
    }

    /// How much width a control actually gets, given the pane width and the arrangement.
    public static func availableControlWidth(paneWidth: CGFloat, style: InspectorLayoutStyle) -> CGFloat {
        switch style {
        case .inline:
            max(0, paneWidth - horizontalPadding - labelColumnWidth - labelGap)
        case .stacked:
            max(0, paneWidth - horizontalPadding)
        }
    }

    /// Whether a three-way segmented control fits at this width.
    ///
    /// It does not, below the breakpoint — which is why the status control becomes a menu there
    /// rather than being drawn at a size it cannot honour.
    public static func canUseSegmentedControl(paneWidth: CGFloat) -> Bool {
        availableControlWidth(paneWidth: paneWidth, style: style(forWidth: paneWidth)) >= 220
    }
}

extension EnvironmentValues {
    /// The arrangement rows should use.
    ///
    /// Measured once by the inspector's root and propagated, rather than each row running its own
    /// `GeometryReader` — which would be a dozen redundant measurements and a source of layout
    /// feedback loops.
    @Entry public var inspectorLayoutStyle: InspectorLayoutStyle = .inline

    /// The pane's current width, so a row can decide between control *variants* rather than only
    /// between arrangements.
    @Entry public var inspectorPaneWidth: CGFloat = InspectorLayout.idealWidth
}

extension View {
    /// Measures the inspector pane and publishes the arrangement to its rows.
    public func measuresInspectorLayout() -> some View {
        modifier(InspectorLayoutMeasurement())
    }
}

private struct InspectorLayoutMeasurement: ViewModifier {
    @State private var width: CGFloat = InspectorLayout.idealWidth

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                guard newWidth > 0 else { return }
                width = newWidth
            }
            .environment(\.inspectorLayoutStyle, InspectorLayout.style(forWidth: width))
            .environment(\.inspectorPaneWidth, width)
    }
}
