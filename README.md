<div align="center">

<img src="Assets/elephruit-logo.png" alt="Elephruit" width="320">

<h3>Your entire working memory, in one app, on your own Mac.</h3>

<p>
Notes, reminders, projects, people, calendar, and time —<br>
one linked graph, one search box, zero cloud.
</p>

<p>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-1d1d1f?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
  <img alt="Local first" src="https://img.shields.io/badge/local--first-no_network_entitlement-2ea44f?style=flat-square">
  <img alt="Dependencies: none" src="https://img.shields.io/badge/dependencies-none-4c6ef5?style=flat-square">
</p>

</div>

<br>

<div align="center">
<table>
<tr><td align="center">

Your thinking is spread across six apps that don't know about each other.<br>
The note from Tuesday doesn't know it produced three reminders.<br>
The person you promised something to doesn't know you promised it.<br>
Search means remembering **which app** before you can find **what**.

</td></tr>
</table>
</div>

Elephruit puts all of it in one store where **everything can link to everything** — and then does the
thing that only becomes possible once you do: a single search surface, a single day view, and a
person page that assembles itself out of links you never had to file.

It runs entirely on your Mac. No account, no subscription, no sync server, and no network entitlement
in the app at all.

<br>

<div align="center">

**[Capture](#capture-in-under-four-seconds)** · **[Web Clipper](#save-the-web-without-sending-it-away)** ·
**[Search](#search-that-actually-narrows)** ·
**[Today](#a-today-that-has-seen-your-whole-day)** · **[Reminders](#reminders-with-the-parts-real-work-needs)** ·
**[People](#people-who-remember-themselves)** · **[Calendar](#a-calendar-that-knows-the-rest-of-your-life)** ·
**[Time](#time-tracking-that-survives-an-audit)** · **[Export](#your-data-leaves-whenever-you-want)**

</div>

---

<br>

<table>
<tr>
<td width="50%" valign="top">

### One graph, not six silos

Notes, reminders, projects, areas, people, meetings, and reference material are all first-class items in
one store, and any of them can link to any other.

Type `[[` anywhere in a note to link to something that exists — or to something that doesn't yet, and
create it in place. Every item shows its **backlinks**, computed from the graph, never
hand-maintained.

</td>
<td width="50%" valign="top">

### Keyboard first, everywhere

`⌘K` opens the command palette. Every module has a jump shortcut, every primitive action has a
binding, and **you can rebind all of them**.

Quick Jot, Quick Log, and the people command bar are one chord away from anywhere in the app —
including from other apps, via a global hotkey.

</td>
</tr>
</table>

<br>

## Capture in under four seconds

> *One line, no decision about where it goes.*

`⌘⇧N` opens Quick Jot over whatever you're doing. Type a line, press `⌘↩`, and the grammar does the
filing for you:

```
Draft the Q3 memo >Q3 Launch @sarah #writing !friday 3pm
```

`>` picks the project · `@` links a person · `#` tags it · `!` sets a deadline · `follow:` sets a
start date instead

The field shows you what it understood **before** you commit, so nothing is ever filed somewhere you
didn't intend. Then it lands in the Inbox and you get back to what you were doing.

<br>

## Save the web without sending it away

> *A Safari web clipper with a local destination.*

The bundled Safari extension can save a cleaned article, the current selection, the full page, a
bookmark, or a visible screenshot. Before saving, you can edit the title, add a note and tags, and
file the result under an existing project. Article clips become searchable Markdown notes. Full-page
clips keep the continuous visual capture in the editor while indexing the extracted DOM and
on-device OCR behind it, so searches find text in the page without appending a transcription below
the image. Cleaned HTML is retained as a managed attachment for fidelity. Screenshots are copied
into the same attachment store as your other files and OCR-indexed locally.

Opening the toolbar item places the clipper in a fixed panel at the page's right edge, away from the
primary reading column. Choosing **Article** or **Simplified** outlines the detected article directly
on the Safari page and dims everything outside it. Use − and + in the panel—or on the floating page
control—to narrow or expand the meaningful page boundary before saving. The preview and saved
content update together.

Nothing is uploaded. The extension reads only the page on which you invoke it, places an atomic clip
envelope in the app-group inbox, and wakes Elephruit to import it. If importing is interrupted, the
same clip resumes without duplicating the item or its attachments.

To turn it on, run Elephruit, open **Settings → Web Clipper**, choose **Open Safari Extension
Settings**, and enable Elephruit Web Clipper. Pin it to Safari's toolbar if you use it often. A signed
development or
distribution build must sign both targets with the same team. On macOS the build derives a
team-prefixed App Group identifier, allowing the app and extension to share the clip inbox without a
repeated “access data from other apps” prompt during development.

See [the implementation record](docs/34-web-clipper-record.md) for the capture contract, privacy
boundary, signing requirement, and verification commands.

<br>

## Search that actually narrows

> *Stop remembering where. Just describe it.*

Free text across every title and body, plus a token grammar that turns "somewhere in my stuff" into
one line:

```
launch plan type:note tag:work project:"Q3 Launch" is:open due:<7d
```

|  |  |
|---|---|
| **Resolved in the index** | `is:open type:reminder due:<7d` becomes a `WHERE` clause, not a scan of your whole library — results stay instant as the corpus grows |
| **Hierarchical tags** | `tag:work` finds `work/clients` |
| **Quotes group** | `project:"Q3 Launch"`, `tag:"work in progress"` |
| **Saveable** | Any query becomes a smart view that lives in the sidebar forever |

<br>

## A Today that has seen your whole day

> *The person in your ten o'clock is also the person a reminder is waiting on.*

One page, not three. Today joins your meetings, your work, and the people both involve — so the
joining you used to do in your head, reading one screen and then another, is already done. Somebody
appears on it for a stated reason: they're in a meeting, a reminder is waiting on them, a reminder is about
them, or it's their birthday.

The rules behind it are deliberate about what *not* to say. A dentist appointment isn't a meeting, so
"six meetings today" stays a number you can act on. A focus block overlapped by a meeting isn't a
conflict, because flagging it would put a warning on most days of most calendars and teach you to
ignore warnings. Free time is measured from *now* against the working hours you actually set, and on
a day you don't work there's no figure at all. Overdue work belongs to today alone — repeating it
forward would make every future day open as a crisis.

`Space` completes. A recurring reminder reschedules itself instead of breeding duplicates.

<br>

## Reminders with the parts real work needs

> *Deadlines and start dates are different dates, and behave differently.*

A start date brings something into view on the day without ever turning red. A deadline can go
overdue. Conflating the two is why most reminder apps eventually shout at you about everything at once.

Beyond that: projects with sections, checklists and subtasks, Someday, waiting-on-a-person, promises
you made, repeats of both kinds — *every Monday*, and *three days after you last finished it* — and
reminders created straight from a line in a note that keep a link back to where they came from.

<br>

## People who remember themselves

> *Assembled from links you already made.*

A person's page shows every interaction, every note that mentions them, every open reminder you owe them
or they owe you, the projects you share, and their relationships to other people — none of it
re-entered.

Import from your address book with a review step built for the awkward cases: the same person twice,
two people sharing a surname, a housemate on the same number, a birthday with no year.

> [!NOTE]
> Contacts is **read-only by construction** — the adapter has no write method to call, and a test
> fails the build if one is ever added.

<br>

## A calendar that knows the rest of your life

> *The meeting, and everything you know about it.*

Day, week, month, and agenda views. Overlap-aware layout for a morning where three meetings clash.
Time zones shown honestly. Recurring events, event templates, and calendar sets you can switch
between.

You create and edit real events from here — and attach the things a calendar can't hold: who was
there, what you decided, what you promised. Those stay in Elephruit. A **meeting brief** pulls the
people, the notes, and the open threads together before you walk in.

<br>

## Time tracking that survives an audit

> *An entry that ran fifty-one minutes is stored as fifty-one minutes. Forever.*

Start a timer on anything — a reminder, a project, a meeting, a note — or log it after the fact.

People are a real relationship rather than a string, so *time **on** Sarah* and *time **with** Sarah*
are different questions with different answers. Rounding applies to a report row, an export column,
an invoice total — never to the store, because a store holding fifty-four minutes has lost the only
number that could settle a dispute.

Reports group by project, person, tag, or period, chart the result, and export to CSV in either
shape. A built-in **focus cycle** runs pomodoros against the running timer, with idle detection so a
walk to the kitchen doesn't get billed.

<br>

## Apple integrations, on your terms

> *Connected one at a time, list by list, or not at all.*

Reminders, Calendar, and Contacts each stay off until you switch them on. No list participates until
you tick it. Disconnecting leaves every existing link intact.

> [!IMPORTANT]
> Nothing private crosses the boundary. Areas, projects, Today, waiting-for, linked people, and
> provenance are never written into a reminder's title or a calendar note — that text would appear in
> Apple's own apps on every device, and in a shared list to everybody it's shared with. Every rule
> has a stated reason in Settings, and a test that fails if the code stops honouring it.

<br>

## Your data leaves whenever you want

> *Shipped in v1 on purpose. It's the whole escape hatch.*

| Format | What you get |
|---|---|
| **JSON archive** | Complete, versioned, round-trippable, identifiers preserved |
| **Markdown bundle** | One `.md` per note with YAML front-matter, attachments in a predictable tree |

Import accepts both, validates before it writes, detects duplicates by stable ID and then by content
hash, and reports exactly what it did.

And nothing is destroyed by accident: deleting moves to **Trash** with a restore path that reattaches
the original relationships, `⌘Z` undoes structural changes rather than just typing, and permanent
deletion is always a separate, explicit act.

<br>

---

<br>

## Built for the machine it runs on

Native SwiftUI and SwiftData. Sandboxed with five entitlements and no network one. No third-party
dependencies, no analytics, no telemetry, no crash-reporting SDK, nothing phoning home. Secrets live
in the Keychain or nowhere.

Every colour resolves through the system palette, so light, dark, Increase Contrast, and a
non-default accent all work — and a test fails the build if a view ever names a literal colour.

<table>
<tr>
<td align="center"><strong>&lt; 700 ms</strong><br><sub>cold launch to usable window</sub></td>
<td align="center"><strong>&lt; 100 ms</strong><br><sub>search over 20 000 items</sub></td>
<td align="center"><strong>10 000 words</strong><br><sub>imperceptible typing latency</sub></td>
<td align="center"><strong>zero</strong><br><sub>data loss on force-quit mid-edit</sub></td>
</tr>
</table>

<br>

## Getting it running

Requires **macOS 26** or later, and **Xcode 27** or later to build.

```bash
open Elephruit.xcodeproj
```

Or from the command line:

```bash
xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -configuration Debug build
```

The module tests run without Xcode, signing, or a simulator:

```bash
swift test --package-path Packages/ElephruitKit
```

<details>
<summary><strong>Trying it without touching anything real</strong></summary>

<br>

Run with sample data and a throwaway library:

```bash
open -n "$(xcodebuild -project Elephruit.xcodeproj -scheme Elephruit -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}' | head -1)/Elephruit.app" --args -ElephruitDevelopmentMode -ElephruitUseTemporaryStore
```

Sample data then lives under **Settings ▸ Advanced ▸ Load Sample Data**.

Add `-ElephruitUseFixtureCalendar` or `-ElephruitUseFixtureContacts` to explore the calendar and
contacts features against invented data — fictional calendars, `example.com` addresses, 555 numbers —
instead of your own. The real system stores are never opened. Both flags are ignored outside
development mode, so a release build can never be talked into showing fiction where somebody expects
their own data.

</details>

<br>

## Documentation

Design documents, architecture decisions, and per-module records live in **[docs/](docs/)** — start
with [Product definition](docs/01-product-definition.md) and the [Roadmap](docs/07-roadmap.md).

<br>

---

<div align="center">

**Non-negotiables**

No network requests, because the app has no network entitlement · Nothing recorded *about* a person
or a meeting is ever written to a system calendar or contact · No analytics, telemetry, or
crash-reporting SDKs · Secrets in the Keychain only · Full-fidelity export ships in v1

</div>
