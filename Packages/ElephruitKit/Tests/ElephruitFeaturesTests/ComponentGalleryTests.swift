import AppKit
import ElephruitCore
import ElephruitDesign
import Foundation
import SwiftUI
import Testing

@testable import ElephruitFeatures

/// Renders real components to PNGs, with no window server involved.
///
/// ### Why this exists
/// Every visual check in this project has gone through a running app photographed with
/// ScreenCaptureKit, and that route is only as reliable as the machine's screen. It refuses while
/// the display sleeps; the app creates no window at all when it launches on a locked screen; and
/// macOS state restoration can persist "the window was closed", after which the app relaunches
/// healthy, with a normal run loop, and nothing to photograph — which is indistinguishable from a
/// crash and cost this project a long detour chasing a regression that did not exist.
///
/// `ImageRenderer` has none of those failure modes. It rasterises a view directly, so a component
/// can be looked at on a locked, sleeping, unattended machine, and the result is deterministic
/// rather than dependent on what the window server felt like doing.
///
/// It is **not** a replacement for looking at the running app: it renders a component, not a window,
/// so it says nothing about split-view behaviour, materials, toolbars, or how the pieces sit
/// together. It is the right tool for the thing it does — comparing a control's typography and
/// colour in both appearances — and the wrong one for everything else.
///
/// ### Running it
/// Off by default, because writing files is not a unit test's job:
/// ```bash
/// ELEPHRUIT_GALLERY=/tmp/gallery swift test --filter ComponentGallery
/// ```
@Suite("Component gallery")
@MainActor
struct ComponentGalleryTests {
    private var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ELEPHRUIT_GALLERY"] else { return nil }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Rasterises `view` in both appearances, side by side, and writes one PNG.
    ///
    /// Both at once because the question is almost never "how does this look in dark mode" — it is
    /// "do these two agree", and that is not answerable from two files opened at different moments.
    private func write(_ name: String, width: CGFloat = 640, @ViewBuilder _ view: () -> some View) throws {
        guard let outputDirectory else { return }

        let pair = VStack(alignment: .leading, spacing: 0) {
            view()
                .padding(Theme.Spacing.large)
                .frame(width: width, alignment: .leading)
                .background(Theme.Colors.contentBackground)
                .environment(\.colorScheme, .light)

            view()
                .padding(Theme.Spacing.large)
                .frame(width: width, alignment: .leading)
                .background(Theme.Colors.contentBackground)
                .environment(\.colorScheme, .dark)
        }

        let renderer = ImageRenderer(content: pair)
        // Retina, so hairlines and tracking are visible rather than averaged away.
        renderer.scale = 2

        guard let image = renderer.nsImage,
              let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            Issue.record("Could not rasterise \(name)")
            return
        }

        try png.write(to: outputDirectory.appending(path: "\(name).png"))
    }

    // MARK: - The person action row

    /// The row that was three saturated pills, then a row of identical grey buttons, and is now
    /// neutral controls with a coloured glyph each.
    @Test("Person action row")
    func personActionRow() throws {
        let actions = PersonActionAvailability.all(
            destinations: [
                ContactDestination(label: "mobile", value: "512-555-0192", source: .phone, isPreferred: true),
                ContactDestination(label: "work", value: "sam@example.com", source: .email, isPreferred: true),
            ],
            hasRelationships: true,
            hasHistory: true
        )

        try write("person-action-row", width: 620) {
            HStack(spacing: Theme.Spacing.small) {
                ForEach(Array(actions.prefix(4)).indices, id: \.self) { index in
                    let entry = Array(actions.prefix(4))[index]
                    PersonDockButton(entry: entry, showsTitle: true, isProminent: index == 0) {}
                }
            }
        }
    }

    // MARK: - List rows

    /// A list of rows, which is where the type scale shows: the gap between a row's title and its
    /// subtitle was one point before this pass, which is a rounding error rather than a hierarchy.
    @Test("List rows")
    func listRows() throws {
        let clock = SystemDateProvider()
        let items: [ItemSnapshot] = [
            ItemSnapshot(
                kind: .note,
                title: "Notes from the Tuesday call",
                body: "Jordan wants the revised numbers before the board meeting.",
                updatedAt: clock.startOfDay(daysFromToday: -1),
                tagSlugs: ["work"]
            ),
            // `status: .open` matters. `isActionable` is `isActive && kind.supportsStatus &&
            // status == .open`, and only an actionable row colours its date — so a task left at the
            // default `.none` renders an overdue deadline in quiet grey. The first version of this
            // fixture did exactly that and made it look as though urgency colour had been lost.
            ItemSnapshot(
                kind: .task,
                title: "Send the revised pricing table to Priya",
                body: "",
                updatedAt: clock.now,
                status: .open,
                dueAt: clock.startOfDay(daysFromToday: -3),
                tagSlugs: ["urgent"],
                parentTitle: "Q3 Product Launch"
            ),
            ItemSnapshot(
                kind: .task,
                title: "Weekly review",
                body: "",
                updatedAt: clock.now,
                status: .open,
                dueAt: clock.startOfDay(daysFromToday: 0)
            ),
            ItemSnapshot(
                kind: .task,
                title: "Renew the parking permit",
                body: "",
                updatedAt: clock.startOfDay(daysFromToday: -2),
                status: .completed,
                dueAt: clock.startOfDay(daysFromToday: -5)
            ),
            ItemSnapshot(
                kind: .note,
                title: "Migration runbook",
                body: "Steps, in order. Do not skip step four.",
                updatedAt: clock.startOfDay(daysFromToday: -8),
                tagSlugs: ["infrastructure"]
            ),
        ]

        try write("list-rows", width: 420) {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    ItemRow(item: item, dateProvider: clock)
                    Divider()
                }
            }
        }
    }
}
