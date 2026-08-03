# 33 — Reminders unification

The Tasks product surface was removed on 2026-08-03. Reminders is now the single place for ordinary
actionable work, whether it was captured locally, created from another record, or linked to Apple
Reminders.

## Data migration

On launch, every persisted item whose legacy kind is `task` is changed in place to `reminder`. This
is a kind promotion, not a copy-and-delete migration, so the item keeps its stable identifier,
parent and children, links and backlinks, tags, dates, recurrence, checklist, completion state,
priority, people, provenance, external Reminders identity, archive state, and trash state.

Legacy JSON archives and Markdown front matter are normalized at import time as well. The `task`
enum case and historical shortcut and navigation raw values remain decodable only so older stores,
exports, preferences, restored windows, and deep links continue to work. They are not creation paths
and are not shown in the interface.

## One destination

Reminders is graph-backed. Its workspace reads and edits the same item records used by Today,
projects, search, people, notes, calendar follow-ups, and EventKit synchronization. Links that once
opened a Tasks list now open the linked reminder in Reminders. Legacy Tasks system views and smart
list destinations also redirect there.

Every ordinary producer creates a reminder directly, including Quick Jot action grammar, meeting
follow-ups, people follow-ups, checklist promotion, recurring occurrences, and sample data. Exported
Markdown bundles use a `Reminders` directory, and search describes the legacy `type:task` alias as
Reminders.

## Project-specific work stays project-specific

Bug, feature, milestone, and release records are not migrated. They remain project-owned work
records and keep their project views, fields, and workflows. Only the retired ordinary `task` kind
is promoted to `reminder`.

## Removed surface

The Tasks module, its sidebar, workspace, cards, rows, quick-entry surface, popovers, bottom bar,
redirect view, view service exposure, and dedicated entry parser/composer were deleted. Shared
pieces still needed by Reminders or project work were retained under neutral names. Reminders owns
the live lifecycle service and query surface.
