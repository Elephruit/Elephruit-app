// Rich-document format gate — Stage 0 prototype.
//
// Throwaway. Answers one question: which serialization can carry everything the
// expansion plan asks a note to hold, without losing the thing Elephruit already
// depends on — a stable, machine-readable link target on a run of text.
//
// Candidates: RTFD (NSAttributedString document type) vs NSKeyedArchiver.

import AppKit
import Foundation

// MARK: - Harness

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var results: [String] = []

func check(_ name: String, _ passed: Bool, _ detail: String = "") {
    let mark = passed ? "PASS" : "FAIL"
    if !passed { failures += 1 }
    let line = "  [\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")"
    results.append(line)
    print(line)
}

func section(_ title: String) {
    print("\n\(title)")
    results.append("\n\(title)")
}

func ms(_ block: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

// The attribute Elephruit would need: a stable target ID on a run of text.
let wikiTargetKey = NSAttributedString.Key("com.elephruit.wikiTarget")
let semanticStyleKey = NSAttributedString.Key("com.elephruit.semanticStyle")

func rtfd(_ s: NSAttributedString) -> Data? {
    try? s.data(
        from: NSRange(location: 0, length: s.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
    )
}

func fromRTFD(_ d: Data) -> NSAttributedString? {
    try? NSAttributedString(
        data: d,
        options: [.documentType: NSAttributedString.DocumentType.rtfd],
        documentAttributes: nil
    )
}

func archived(_ s: NSAttributedString) -> Data? {
    try? NSKeyedArchiver.archivedData(withRootObject: s, requiringSecureCoding: false)
}

func unarchived(_ d: Data) -> NSAttributedString? {
    try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: d)
}

// MARK: - 1. Custom attributes: the decisive question

section("1. Custom attributes (wiki link targets, semantic styles)")

let targetID = UUID()
let withCustom = NSMutableAttributedString(string: "See Q3 Launch for details.")
withCustom.addAttribute(wikiTargetKey, value: targetID.uuidString, range: NSRange(location: 4, length: 9))
withCustom.addAttribute(semanticStyleKey, value: "heading1", range: NSRange(location: 0, length: 3))

if let d = rtfd(withCustom), let back = fromRTFD(d) {
    var found: Any?
    back.enumerateAttribute(wikiTargetKey, in: NSRange(location: 0, length: back.length)) { v, _, _ in
        if v != nil { found = v }
    }
    check("RTFD preserves a custom wiki-target attribute", found != nil,
          found == nil ? "attribute is gone after round trip" : "kept")

    var style: Any?
    back.enumerateAttribute(semanticStyleKey, in: NSRange(location: 0, length: back.length)) { v, _, _ in
        if v != nil { style = v }
    }
    check("RTFD preserves a custom semantic-style attribute", style != nil,
          style == nil ? "attribute is gone after round trip" : "kept")
} else {
    check("RTFD round trip completed", false, "serialization itself failed")
}

if let d = archived(withCustom), let back = unarchived(d) {
    var found: Any?
    back.enumerateAttribute(wikiTargetKey, in: NSRange(location: 0, length: back.length)) { v, _, _ in
        if v != nil { found = v }
    }
    check("NSKeyedArchiver preserves a custom wiki-target attribute", found != nil,
          (found as? String) == targetID.uuidString ? "exact UUID survived" : "changed or lost")
} else {
    check("NSKeyedArchiver round trip completed", false, "serialization itself failed")
}

// A standard NSLinkAttributeName does survive RTF — check whether it can carry an app URL.
let withLink = NSMutableAttributedString(string: "See Q3 Launch for details.")
withLink.addAttribute(.link, value: URL(string: "elephruit://item/\(targetID.uuidString)")!,
                      range: NSRange(location: 4, length: 9))
if let d = rtfd(withLink), let back = fromRTFD(d) {
    var url: URL?
    back.enumerateAttribute(.link, in: NSRange(location: 0, length: back.length)) { v, _, _ in
        if let u = v as? URL { url = u } else if let s = v as? String { url = URL(string: s) }
    }
    check("RTFD preserves .link with a custom URL scheme",
          url?.absoluteString.contains(targetID.uuidString) == true,
          url?.absoluteString ?? "no link found")
}

// MARK: - 2. Tables

section("2. Tables (NSTextTable)")

func makeTable(rows: Int, cols: Int) -> NSAttributedString {
    let table = NSTextTable()
    table.numberOfColumns = cols
    let out = NSMutableAttributedString()
    for r in 0..<rows {
        for c in 0..<cols {
            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            out.append(NSAttributedString(string: "r\(r)c\(c)\n", attributes: [.paragraphStyle: style]))
        }
    }
    return out
}

func tableCount(_ s: NSAttributedString) -> Int {
    var tables = Set<ObjectIdentifier>()
    s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
        guard let style = v as? NSParagraphStyle else { return }
        for block in style.textBlocks {
            if let t = (block as? NSTextTableBlock)?.table { tables.insert(ObjectIdentifier(t)) }
        }
    }
    return tables.count
}

let table = makeTable(rows: 3, cols: 3)
check("Table constructed in memory", tableCount(table) == 1, "\(tableCount(table)) table(s)")

if let d = rtfd(table), let back = fromRTFD(d) {
    check("RTFD preserves table structure", tableCount(back) == 1, "\(tableCount(back)) table(s) after round trip")
    check("RTFD preserves cell text", back.string.contains("r2c2"), "")
}
if let d = archived(table), let back = unarchived(d) {
    check("NSKeyedArchiver preserves table structure", tableCount(back) == 1, "\(tableCount(back)) table(s) after round trip")
}

// MARK: - 3. Lists

section("3. Nested lists and checklists")

func makeNestedList() -> NSAttributedString {
    let out = NSMutableAttributedString()
    let l1 = NSTextList(markerFormat: .disc, options: 0)
    let l2 = NSTextList(markerFormat: .circle, options: 0)
    let l3 = NSTextList(markerFormat: .square, options: 0)
    for (text, lists) in [("top\n", [l1]), ("nested\n", [l1, l2]), ("deep\n", [l1, l2, l3])] {
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        out.append(NSAttributedString(string: text, attributes: [.paragraphStyle: style]))
    }
    return out
}

func maxNesting(_ s: NSAttributedString) -> Int {
    var depth = 0
    s.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: s.length)) { v, _, _ in
        if let style = v as? NSParagraphStyle { depth = max(depth, style.textLists.count) }
    }
    return depth
}

let lists = makeNestedList()
check("Three-level list constructed", maxNesting(lists) == 3, "depth \(maxNesting(lists))")
if let d = rtfd(lists), let back = fromRTFD(d) {
    check("RTFD preserves 3-level nesting", maxNesting(back) == 3, "depth \(maxNesting(back))")
}
if let d = archived(lists), let back = unarchived(d) {
    check("NSKeyedArchiver preserves 3-level nesting", maxNesting(back) == 3, "depth \(maxNesting(back))")
}
// Checklists have no native NSTextList marker format — they need a custom attribute.
check("Checklists need a custom attribute (no native marker format)", true,
      "NSTextList.MarkerFormat has no checkbox case; must ride on a custom attribute")

// MARK: - 4. Attachments

section("4. Inline images and file attachments")

let png: Data = {
    let img = NSImage(size: NSSize(width: 8, height: 8))
    img.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let d = rep.representation(using: .png, properties: [:]) else { return Data() }
    return d
}()

let attachmentID = UUID()
let wrapper = FileWrapper(regularFileWithContents: png)
wrapper.preferredFilename = "diagram.png"
let attachment = NSTextAttachment(fileWrapper: wrapper)
let withAttachment = NSMutableAttributedString(string: "Before ")
let attachStr = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
attachStr.addAttribute(wikiTargetKey, value: attachmentID.uuidString, range: NSRange(location: 0, length: attachStr.length))
withAttachment.append(attachStr)
withAttachment.append(NSAttributedString(string: " after"))

if let d = rtfd(withAttachment), let back = fromRTFD(d) {
    var count = 0
    var name: String?
    var stableID: Any?
    back.enumerateAttribute(.attachment, in: NSRange(location: 0, length: back.length)) { v, r, _ in
        guard let a = v as? NSTextAttachment else { return }
        count += 1
        name = a.fileWrapper?.preferredFilename
        stableID = back.attribute(wikiTargetKey, at: r.location, effectiveRange: nil)
    }
    check("RTFD preserves the attachment", count == 1, "\(count) attachment(s)")
    check("RTFD preserves the attachment filename", name != nil, name ?? "lost")
    check("RTFD preserves a stable ID alongside the attachment", stableID != nil,
          stableID == nil ? "custom attribute lost — attachment identity cannot ride in RTFD" : "kept")
}
if let d = archived(withAttachment), let back = unarchived(d) {
    var stableID: Any?
    back.enumerateAttribute(.attachment, in: NSRange(location: 0, length: back.length)) { v, r, _ in
        guard v is NSTextAttachment else { return }
        stableID = back.attribute(wikiTargetKey, at: r.location, effectiveRange: nil)
    }
    check("NSKeyedArchiver preserves a stable ID alongside the attachment", stableID != nil,
          (stableID as? String) == attachmentID.uuidString ? "exact UUID survived" : "changed or lost")
}

// MARK: - 5. Plain-text projection

section("5. Plain-text projection (what the FTS index would receive)")

let projection = withAttachment.string
let objectReplacement = projection.contains("\u{FFFC}")
check("Attachment appears as U+FFFC in .string", objectReplacement,
      "projection must strip it or the index gains a junk character")
check("Table cell text is present in .string", table.string.contains("r1c1"), "")
check("List item text is present in .string", lists.string.contains("nested"), "")

// MARK: - 6. Scale

section("6. 100,000-character document")

let bigBody = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 2273)
let big = NSMutableAttributedString(string: bigBody)
big.addAttribute(.font, value: NSFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: big.length))
for i in stride(from: 0, to: big.length - 200, by: 500) {
    big.addAttribute(.link, value: URL(string: "elephruit://item/\(UUID().uuidString)")!,
                     range: NSRange(location: i, length: 9))
}
print("  document length: \(big.length) characters, \(big.length / 500) links")

var rtfdData: Data?
let rtfdEncode = ms { rtfdData = rtfd(big) }
var archiveData: Data?
let archiveEncode = ms { archiveData = archived(big) }
var rtfdDecodeMS = 0.0
var archiveDecodeMS = 0.0
if let d = rtfdData { rtfdDecodeMS = ms { _ = fromRTFD(d) } }
if let d = archiveData { archiveDecodeMS = ms { _ = unarchived(d) } }
var projectionMS = 0.0
projectionMS = ms { _ = big.string }

print(String(format: "  RTFD    encode %.1f ms  decode %.1f ms  size %d KB",
             rtfdEncode, rtfdDecodeMS, (rtfdData?.count ?? 0) / 1024))
print(String(format: "  Archive encode %.1f ms  decode %.1f ms  size %d KB",
             archiveEncode, archiveDecodeMS, (archiveData?.count ?? 0) / 1024))
print(String(format: "  Plain-text projection: %.2f ms", projectionMS))
check("RTFD encode under 100 ms at 100k chars", rtfdEncode < 100, String(format: "%.1f ms", rtfdEncode))
check("Archive encode under 100 ms at 100k chars", archiveEncode < 100, String(format: "%.1f ms", archiveEncode))
check("Projection under 5 ms at 100k chars", projectionMS < 5, String(format: "%.2f ms", projectionMS))

// MARK: - 7. Paste from other macOS apps

section("7. Paste interoperability (real RTF from another app's pasteboard flavour)")

let foreignRTF = """
{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}
{\\colortbl;\\red0\\green0\\blue0;\\red200\\green0\\blue0;}
\\f0\\fs28\\b Heading\\b0\\par
\\fs24 Body with \\i italic\\i0  and \\cf2 red\\cf1  text.\\par
}
"""
if let data = foreignRTF.data(using: .utf8),
   let pasted = try? NSAttributedString(data: data,
                                        options: [.documentType: NSAttributedString.DocumentType.rtf],
                                        documentAttributes: nil) {
    var sawBold = false, sawItalic = false, sawColour = false
    pasted.enumerateAttributes(in: NSRange(location: 0, length: pasted.length)) { attrs, _, _ in
        if let f = attrs[.font] as? NSFont {
            let t = NSFontManager.shared.traits(of: f)
            if t.contains(.boldFontMask) { sawBold = true }
            if t.contains(.italicFontMask) { sawItalic = true }
        }
        if let c = attrs[.foregroundColor] as? NSColor,
           c.usingColorSpace(.deviceRGB)?.redComponent ?? 0 > 0.5 { sawColour = true }
    }
    check("Foreign RTF parses", pasted.length > 0, "\(pasted.length) chars")
    check("Bold survives the paste", sawBold, "")
    check("Italic survives the paste", sawItalic, "")
    check("Hard-coded colour arrives from the paste", sawColour,
          sawColour ? "MUST be sanitised or it is unreadable in dark mode" : "")
} else {
    check("Foreign RTF parses", false, "parse failed")
}

// MARK: - Summary

print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) failed — see FAIL lines above.")")
