import AppKit
@testable import ElephruitFeatures
import ElephruitCore
import ElephruitDesign
import Foundation
import SwiftUI
import Testing

/// Renders the notes workspace's surfaces to PNGs, with no window server involved — the same
/// arrangement as `ComponentGalleryTests`, for the same reason: a component must be inspectable
/// on a locked, sleeping, unattended machine.
///
/// The prose page is an `NSTextView`, which `ImageRenderer` cannot rasterise, so it draws itself
/// through `cacheDisplay` — offscreen, deterministic, and it exercises the same `draw(_:)` that
/// paints the markers, bars and tints in the app.
///
/// Off by default, because writing files is not a unit test's job:
/// ```bash
/// ELEPHRUIT_GALLERY=/tmp/gallery swift test --filter NoteGallery
/// ```
@Suite("Note gallery")
@MainActor
struct NoteGalleryTests {
    private var outputDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["ELEPHRUIT_GALLERY"] else { return nil }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Writers

    private func writePNG(_ image: NSImage, to url: URL) {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            Issue.record("Could not encode \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }

    /// Rasterises one prose document in a given appearance by asking the view to draw itself.
    private func proseImage(_ paragraphs: [NoteParagraph], width: CGFloat, appearance: NSAppearance.Name) -> NSImage? {
        let view = NoteProseTextView()
        view.appearance = NSAppearance(named: appearance)
        view.textStorage?.setAttributedString(NoteProseConversion.attributedString(for: paragraphs))

        guard let container = view.textContainer, let layoutManager = view.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height + 16

        view.frame = NSRect(x: 0, y: 0, width: width, height: height)

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }

        // The sheet colour behind the text, resolved in the same appearance the text draws in.
        view.appearance?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = context
                NSColor.textBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        view.cacheDisplay(in: view.bounds, to: bitmap)

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// Light above dark, one file, because the question is "do these two agree".
    private func writeProse(_ name: String, _ paragraphs: [NoteParagraph], width: CGFloat = 620) {
        guard let outputDirectory else { return }
        guard let light = proseImage(paragraphs, width: width, appearance: .aqua),
              let dark = proseImage(paragraphs, width: width, appearance: .darkAqua)
        else {
            Issue.record("Could not rasterise \(name)")
            return
        }

        let size = NSSize(width: width, height: light.size.height + dark.size.height)
        let combined = NSImage(size: size, flipped: false) { _ in
            light.draw(at: NSPoint(x: 0, y: dark.size.height), from: .zero, operation: .sourceOver, fraction: 1)
            dark.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        writePNG(combined, to: outputDirectory.appending(path: "\(name).png"))
    }

    private func writeSwiftUI(_ name: String, width: CGFloat = 340, @ViewBuilder _ view: () -> some View) {
        guard let outputDirectory else { return }

        let pair = VStack(alignment: .leading, spacing: 0) {
            view()
                .padding(Theme.Spacing.large)
                .frame(width: width, alignment: .leading)
                .background(Theme.Colors.windowBackground)
                .environment(\.colorScheme, .light)

            view()
                .padding(Theme.Spacing.large)
                .frame(width: width, alignment: .leading)
                .background(Theme.Colors.windowBackground)
                .environment(\.colorScheme, .dark)
        }

        let renderer = ImageRenderer(content: pair)
        renderer.scale = 2

        guard let image = renderer.nsImage else {
            Issue.record("Could not rasterise \(name)")
            return
        }
        writePNG(image, to: outputDirectory.appending(path: "\(name).png"))
    }

    // MARK: Fixtures

    /// One of everything the page can set in type.
    private var showcase: [NoteParagraph] {
        [
            NoteParagraph(kind: .heading1, text: NoteRichText("Planning the autumn release")),
            NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("The plan below is "),
                NoteTextRun("provisional", marks: [.italic]),
                NoteTextRun(" until the numbers land. The "),
                NoteTextRun("hard deadline", marks: [.bold]),
                NoteTextRun(" is the 14th, and "),
                NoteTextRun("the brief", link: .wiki("Release Brief")),
                NoteTextRun(" has the detail."),
            ])),
            NoteParagraph(kind: .heading2, text: NoteRichText("What has to happen")),
            NoteParagraph(kind: .checklist, text: NoteRichText("Confirm the pricing table"), isTicked: true),
            NoteParagraph(kind: .checklist, text: NoteRichText("Draft the announcement")),
            NoteParagraph(kind: .bulleted, text: NoteRichText("Website refresh")),
            NoteParagraph(kind: .bulleted, text: NoteRichText("New screenshots"), indent: 1),
            NoteParagraph(kind: .bulleted, text: NoteRichText("Dark mode set"), indent: 2),
            NoteParagraph(kind: .numbered, text: NoteRichText("Freeze the build")),
            NoteParagraph(kind: .numbered, text: NoteRichText("Tag the release")),
            NoteParagraph(kind: .numbered, text: NoteRichText("Ship")),
            NoteParagraph(kind: .quote, text: NoteRichText("A release date is a promise you make to everyone at once.")),
            NoteParagraph(kind: .callout, text: NoteRichText("The store migration must land before the UI does."), tone: .warning),
            NoteParagraph(
                kind: .code,
                text: NoteRichText("func ship() throws {\n    try freeze()\n    try tag(\"v2.0\")\n}"),
                language: "swift"
            ),
            NoteParagraph(text: NoteRichText(runs: [
                NoteTextRun("Inline "),
                NoteTextRun("code", marks: [.code]),
                NoteTextRun(" and "),
                NoteTextRun("struck", marks: [.strikethrough]),
                NoteTextRun(" and "),
                NoteTextRun("underlined", marks: [.underline]),
                NoteTextRun(" text, all in one paragraph."),
            ])),
            NoteParagraph(kind: .heading3, text: NoteRichText("Afterwards")),
            NoteParagraph(text: NoteRichText("Retro on the following Monday.")),
        ]
    }

    private var outlineModel: NoteEditorModel {
        let model = NoteEditorModel()
        model.load(NoteDocument(pieces: showcase.map { .prose($0) }))
        model.activeOutlineEntryID = model.outline.dropFirst().first?.id
        return model
    }

    // MARK: The images

    @Test("The page's typography, in both appearances")
    func proseShowcase() {
        writeProse("note-prose-showcase", showcase)
    }

    @Test("The / menu")
    func slashMenu() {
        // The list rather than the menu: `ImageRenderer` renders a `ScrollView` as an empty box,
        // which is why the rows live in their own view.
        writeSwiftUI("note-slash-menu") {
            NoteSlashMenuList(
                matches: NoteInsertionCommand.matching("li"),
                highlighted: .paragraph(.checklist),
                onHighlight: { _ in },
                onChoose: { _ in }
            )
            .frame(width: 280)
            .background(Theme.Colors.contentBackground, in: RoundedRectangle(cornerRadius: Theme.Radius.large))
        }
    }

    @Test("The outline rail")
    func outlineRail() {
        writeSwiftUI("note-outline-rail", width: 240) {
            NoteOutlineList(model: outlineModel)
                .frame(width: 200)
        }
    }

    @Test("The format panel")
    func formatPanel() {
        writeSwiftUI("note-format-panel") {
            NoteFormatPanel(model: outlineModel)
        }
    }
}
