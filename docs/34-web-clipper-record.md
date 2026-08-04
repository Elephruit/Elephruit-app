# Safari Web Clipper — implementation record

## Outcome

Elephruit ships a Safari Web Extension that captures the useful part of a page and saves it directly
into the local Elephruit library. It supports six modes:

- **Article** finds the page's primary readable region and removes navigation, advertising, forms,
  scripts, and other page chrome.
- **Simplified article** keeps the readable region while also stripping site-specific presentation.
- **Selection** saves the current DOM selection with its source metadata.
- **Full page** saves the cleaned body and a stitched visual capture of the page.
- **Bookmark** stores the canonical URL, page excerpt, and a local visual thumbnail.
- **Screenshot** captures the visible Safari tab and stores a PNG attachment.

The popup lets the user revise the title, preview the extracted text and a representative image, add
a note and tags, and name an existing project for filing. Article images are downloaded into the
local library and placed inline in the resulting note. Article, simplified-article, selection,
full-page, and screenshot clips become notes; bookmark clips remain bookmarks with a visual preview.

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
  → content extractor (Markdown, cleaned HTML, metadata, image candidates)
  → extension popup (review and filing)
  → native extension handler
  → App Group inbox (atomic JSON)
  → Elephruit importer
  → item + provenance + tags + managed attachments
```

## Privacy and safety boundary

- The extension has scripting, storage, native-messaging, and HTTP/HTTPS website-access permissions.
  Safari exposes that access in its Extensions settings. A dormant content script registers the
  extraction message handler on allowed pages; it does not inspect or copy the DOM until the user
  opens the clipper.
- It does not upload, synchronize, or call a remote API.
- Only HTTP and HTTPS source URLs are accepted.
- Text, screenshot, and downloaded-image payloads have explicit size limits before persistence.
- Extracted HTML removes executable and distracting elements before it enters the app.
- The queue uses an App Group rather than exposing the main data store to the extension.

The main app still has no network entitlement. Safari itself naturally has network access to display
the page being clipped; the extension operates on that active page.

## Enablement and signing

1. Select a development team for both **Elephruit** and **Elephruit Web Clipper**.
2. Register `group.com.elephruit.Elephruit` and include it in both provisioning profiles.
3. Build and run Elephruit once.
4. Open **Settings → Web Clipper → Open Safari Extension Settings**.
5. Enable Elephruit Web Clipper in Safari and optionally pin it to the toolbar.

Unsigned builds verify compilation and embedding, but macOS does not provide a functioning shared App
Group container until both targets are signed with the capability.

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

The popup uses a three-by-two mode picker at its shipping width so all capture types remain legible.
The content extractor was also exercised against a representative article DOM to verify canonical
metadata, absolute links, readable Markdown, and removal of navigation and ads.

## Deliberate current boundary

The screenshot mode captures the visible viewport. **Full page** scrolls and stitches as many as 32
viewports into a JPEG, scales very tall pages to Safari's safe canvas limit, and keeps the cleaned
document as searchable Markdown plus an HTML fidelity attachment. Screenshot annotation, direct PDF
capture, multi-select, site-specific recipes, and a Chromium package remain follow-on slices.
