# Safari Web Clipper — implementation record

## Outcome

Elephruit ships a Safari Web Extension that captures the useful part of a page and saves it directly
into the local Elephruit library. It supports six modes:

- **Article** finds the primary readable story. On a feed with several `<article>` regions, it uses
  the substantial story nearest the current viewport instead of swallowing the entire feed. It
  removes navigation, advertising, forms, scripts, and other page chrome. When selected, the live
  page dims outside a green article boundary. Paired − / + controls walk through meaningful DOM
  ancestors so the user can narrow or expand exactly what the preview and saved clip contain. The
  initial boundary is the detected story. Repeated − clicks contract through useful inner regions
  such as the title and title bar; + expands through the article, feed, content grid, application
  wrapper, and page body. Visually identical wrapper divs are collapsed, with as many as ten real
  containment levels retained. Large feed ancestors are accepted based on their geometry rather
  than rejected merely because they contain substantially more text than the focused story.
- **Simplified article** keeps the readable region while also stripping site-specific presentation.
- **Selection** saves the current DOM selection with its source metadata.
- **Full page** saves a sequence of readable, full-width visual panels. The note renders adjacent
  panels edge-to-edge without captions or attachment-card chrome, so they read as one continuous
  page instead of separate screenshots. No extracted page copy is appended beneath the capture. The
  complete DOM text and on-device OCR for every panel are indexed as attachment metadata instead.
- **Bookmark** stores the canonical URL, page excerpt, and a local visual thumbnail.
- **Screenshot** captures the visible Safari tab and stores a PNG attachment.

The toolbar item toggles a fixed panel at the page's right edge. The panel lets the user revise the
title, preview the extracted text and a representative image, add a note and tags, and name an
existing project for filing without covering the primary reading column. Article images are
downloaded into the local library and retain their original position in the resulting document.
Article and selection clips preserve their sanitized DOM with computed styles, so typography,
colors, spacing, borders, tables, and columns remain recognizable while the text stays live and
selectable. The app does not repeat a flattened Markdown copy beneath that document. Article,
simplified-article, selection, full-page, and screenshot clips become notes; bookmark clips remain
bookmarks with a visual preview.
Every clipped PNG and JPEG is passed through macOS Vision locally, and its recognized text joins the
item's search projection without becoming visible note content.

The boundary adjustment appears in both the panel and a floating control on the page. Because the
panel belongs to the page instead of Safari's transient toolbar popover, clicks on either control
reach their target and several adjustments can be made in one pass. Changing to a non-article mode
removes the page overlay, as does closing the panel or completing the clip.

The toolbar action opens a tiny launcher popup that invokes an existing page API or asks Safari for
optional access to the current website before injecting it. After access is granted, the launcher
closes itself and hands the interaction to the right-side panel. Keeping this handshake in the
toolbar popup gives Safari the direct user gesture required for a runtime permission request and
avoids depending on a nonpersistent Manifest V3 background worker waking in time for the click. The
popup never extracts the page and never becomes the clipper UI. No script is registered on every
page at document start; the guarded page scripts are installed only when the user opens the clipper
on an allowed site. Because Safari can leave an injection promise pending after the script has
executed, the launcher polls for the working listener instead of trusting that promise. Short
deadlines ensure Safari can never leave an endless launcher spinner. The right-side panel is ordinary isolated-world content
rendered into a closed Shadow DOM; it is not an extension iframe embedded in the website. Screenshot,
image-download, and native-messaging operations are proxied through the background worker, so
privileged extension APIs never run from Safari's website WebContent process. This avoids WebKit
rejecting an invalid extension IPC message and terminating the tab.

Panel-to-page commands call a versioned API in the extension's isolated world. This is more than
an implementation detail: a tab that was open during an extension upgrade can retain the previous
message listener, and Safari may accept that listener's empty response before the new one answers.
Directly invoking the newest API makes extraction, boundary changes, and full-page capture work on
those already-open tabs without asking the user to reload.

## Architecture

The boundary between Safari and Elephruit is a versioned `WebClip` value in `ElephruitCore`. Browser
code produces that value; `WebClipService` validates it and maps it into ordinary item, source, tag,
filing, and attachment models. No Safari type crosses into the persistence layer, so another browser
bridge can reuse the same contract later.

The extension's native handler validates each message, writes a JSON envelope atomically into the
shared App Group, and opens `elephruit://clip/import`. The app imports all complete envelopes on
launch and polls while running. It acknowledges an envelope only after persistence succeeds. Saving
is idempotent: a retry reuses the stable clip identifier and completes any missing attachment.

```text
Safari page
  → content extractor (Markdown, styled sanitized HTML, metadata, image candidates)
  → right-side extension panel (review and filing)
  → native extension handler
  → App Group inbox (atomic JSON)
  → Elephruit importer
  → item + provenance + tags + managed HTML/image attachments
  → inert selectable document view backed only by local attachments
  → on-device image OCR → attachment search metadata
```

## Privacy and safety boundary

- The extension has scripting, storage, and native-messaging permissions, plus optional HTTP/HTTPS
  website access. The launcher requests access only for the website the user is clipping, and Safari
  exposes those choices in its Extensions settings. Page scripts are installed after that grant and
  do not inspect or copy the DOM until the user opens the clipper.
- It does not upload, synchronize, or call a remote API.
- Only HTTP and HTTPS source URLs are accepted.
- Text, screenshot, and downloaded-image payloads have explicit size limits before persistence.
- Extracted HTML removes executable and distracting elements before it enters the app. The saved
  document adds a restrictive Content Security Policy, disables page JavaScript in WebKit, blocks
  network resources, and resolves images only through an identifier-checked local attachment scheme.
- The queue uses an App Group rather than exposing the main data store to the extension.

The main app still has no network entitlement. Safari itself naturally has network access to display
the page being clipped; the extension operates on that active page.

## Enablement and signing

1. Select the same development team for both **Elephruit** and **Elephruit Web Clipper**.
2. The macOS build derives `<Team ID>.com.elephruit.Elephruit` for both targets. macOS authorizes
   this group from the shared signing-team prefix, so development builds do not depend on an
   explicit profile carrying an iOS-style `group.` entitlement.
3. Build and run Elephruit once.
4. Open **Settings → Web Clipper → Open Safari Extension Settings**.
5. Enable Elephruit Web Clipper in Safari and optionally pin it to the toolbar.

Unsigned builds verify compilation and embedding, but macOS does not provide a functioning shared App
Group container until both targets are signed with the capability and the same team.

## Verification

The focused package suite covers payload encoding, URL eligibility, atomic inbox behavior, path-safe
acknowledgement, item mapping, project filing, managed HTML and PNG attachments, and interrupted-save
recovery:

```sh
cd Packages/ElephruitKit
swift test --filter 'WebClip|dataAttachment'
```

The complete app and embedded extension build together with:

```sh
xcodebuild -project Elephruit.xcodeproj -scheme Elephruit \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

The panel uses a three-by-two mode picker at its shipping width so all capture types remain legible.
The content extractor was also exercised against a representative article DOM to verify canonical
metadata, absolute links, readable Markdown, and removal of navigation and ads.

## Deliberate current boundary

The screenshot mode captures the visible viewport. **Full page** scrolls across as many as 32
viewports, composes the result into panels no taller than three viewports, and keeps the cleaned
document as searchable attachment metadata plus an HTML fidelity attachment. Each panel is also
OCR-indexed on device. Screenshot annotation, direct PDF capture, multi-select, site-specific
recipes, and a Chromium package remain follow-on slices.
