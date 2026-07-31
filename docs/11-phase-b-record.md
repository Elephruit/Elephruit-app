# Phase B — Universal search: what was built and what was proven

Phase B replaced the search engine and the way search is reached. This is the record of what is
verified, by which test, and — for the one criterion that is not met — by how much.

---

## 1. What changed

### The engine

| | Before | After |
|---|---|---|
| Index | In memory, rebuilt at every launch | SQLite FTS5 file beside the store |
| Structural filters | Applied in Swift after materialising every text match | A `WHERE` clause |
| Rendering a result | One SwiftData fetch per row | Zero fetches |
| Substring match | Not possible | Trigram index over titles |
| Ranking | Hand-written score | BM25, title weighted 10× body |
| Why a result matched | Title highlights only | Title highlights + a body excerpt around the match |

### The interface

Search was a modal sheet, and the list had a separate "Filter this list" box that looked identical
and behaved differently. Both are gone. There is one field; typing turns the middle column into
results; the sidebar and detail pane do not move; Escape restores the list, the selection, and keeps
the query. The old second field is now a scope picker — *Everywhere* or the current list.

### No dependency added

FTS5 is reached through `sqlite3_*`, wrapped in `SQLiteConnection` — about two hundred lines covering
open, prepare, bind, step, finalize. Every Swift wrapper for this is third-party, and the brief rules
those out unless they solve something the platform cannot.

---

## 2. Correctness

All ten pre-existing engine tests are **unchanged** and now run against the new implementation. That
was the point of putting `SearchEngine` behind a protocol: the behaviour they assert is the contract,
and swapping what is underneath is how a contract gets proven rather than assumed.

| Property | Test |
|---|---|
| The index survives a relaunch and opens ready | `indexSurvivesRelaunch` |
| Deleting the index loses nothing | `deletingTheIndexLosesNothing` |
| A rebuild sweeps rows whose item is gone | `staleRowsAreSweptOnRebuild` |
| A finished rebuild leaves search *on the index* | `rebuildLeavesTheIndexReady` |
| A fragment inside a word is found | `substringMatching` |
| A substring hit never displaces a word match | `wordMatchesOutrankSubstrings` |
| Query text is never SQL or FTS syntax | `queryTextIsNeverSQL` |
| Diacritics fold both ways | `diacriticsFold` |
| A body match carries an excerpt containing the match | `bodyExcerptExplainsTheMatch` |
| Headings stay out of results unless named | `headingsAreStructural` |
| Archived items are opt-in | `archivedIsOptedInto` |
| `tag:work` matches `work/clients`, never `workshop` | `tagPrefixIsNotSubstring` |
| A query of pure operators works | `structuralOnlyQuery` |
| `person:` finds links in both directions | `personOperator` |
| `person:` is not a full-text search for the name | `personIsNotFullText` |
| `in:` finds by containment *and* by filing | `containerOperator` |
| Date bounds are applied by the database | `dateBounds` |
| A slow query cannot overwrite a faster later one | `staleResultsAreDiscarded` |
| One letter does not run a search | `singleLetterDoesNotRun` |
| Idle, too-short and no-matches are distinct | `vacancyStatesAreDistinct` |
| An unreadable fragment is reported | `unrecognisedTokensSurface` |

**407 tests pass. Debug and Release build with zero warnings.**

---

## 3. Performance

Measured on the reference machine at **exactly 50,000 items**, the size the criteria name. Benchmarks
are opt-in (`ELEPHRUIT_BENCHMARKS=1`) and never run in an ordinary build.

Every figure is **keystroke to results returned**, not keystroke to results *painted*. Painting
cannot be timed without a window, so it is covered a different way — see the behavioural criterion
below. Saying so is more honest than a number that quietly excludes half of what it claims.

| Criterion | Budget | Measured | |
|---|---|---|---|
| Keystroke → results, p95 | 40 ms | **29.2 ms** | ✅ |
| Keystroke → results with filters, p95 | 40 ms | **11.1 ms** | ✅ |
| Structural query, no words, p95 | 40 ms | **29.4 ms** | ✅ |
| Cold open of an existing index | 150 ms | **0.3 ms** | ✅ |
| Search while the index rebuilds, p95 | 40 ms | **4.6 ms** | ✅ |
| Incremental update on save | 10 ms | **0.2 ms** | ✅ |
| **Full rebuild, 50k items** | **6 s** | **6.15 s** | ❌ |

### The behavioural criterion

`searchDoesNotTouchTheStore` runs a search, reads every field of every result, and asserts the
`FetchAudit` tally is **zero**. Not a timing — a statement about what the code does, which gives the
same answer on any machine under any load, and which is what makes the timings above achievable.

### The one that misses

The full rebuild lands at **6.15 s against a 6 s budget — 2.4% over.** It started at 40 s.

The budget has not been moved. What closes the gap is an index on `Item.createdAt`, which the cursor
paging below would then seek rather than scan. That is a **schema change to the user's store**, and
the standing instruction is that their real data is not migrated until the A2 migration has been
independently reviewed. Trading a 2.4% benchmark miss for an unreviewed schema change to a real
library is not a trade worth making, so it is recorded here instead of taken.

Two mitigations mean the miss costs little in practice: a rebuild only happens on first launch or
after the index is deliberately discarded, and search stays fully usable throughout it, measured at
**4.6 ms p95 while rebuilding**.

---

## 4. Three bugs the measurements found

Each of these passed every correctness test. None would have been found by reading the code.

### A failed optimisation silently switched search off

`PRAGMA wal_checkpoint` returns `SQLITE_BUSY` whenever a reader is mid-query — ordinary, not an
error. That return threw, aborted the end of the rebuild, marked a perfectly good index unavailable,
and routed every search onto the store fallback: **fifty times slower, identical answers**.

Every correctness test still passed, because the fallback is correct. It was mistaken for a search
regression for two rounds of investigation before instrumentation showed the index was never being
queried at all.

The fix is that housekeeping at the end of a rebuild cannot fail the rebuild. The lasting fix is the
test: `rebuildLeavesTheIndexReady` asserts not "search works" but **"search is answering from the
index"** — the thing that was actually broken.

### Paging by offset made the rebuild quadratic

`OFFSET n` makes the database walk and discard *n* rows on every page. Measured across the library:
the first page took 41 ms and the last took 426 ms, and reads were **92% of a 40-second rebuild**.
Replacing the offset with a cursor took it to 12 s.

The cursor uses `>=` rather than `>` because timestamps are not unique — a bulk import gives hundreds
of items the same `createdAt` — and the caller drops the overlap it has already seen. Pretending the
key is unique would silently skip items.

### The sweep re-read the whole library, and had a race

Ending a rebuild by asking the store for every surviving identifier meant a second full pass over a
library that had just been walked in full. It was also wrong in a way nothing caught: an item created
*during* a rebuild was indexed incrementally and then deleted by the sweep for not having been
streamed.

A generation stamp on each row fixes both. An incremental write during a rebuild carries the current
generation and therefore survives it.

### And one thing the measurement said *not* to do

Before instrumenting, the obvious optimisation looked like the SQLite write path — skipping the
existence check and deletes during a full rebuild. The breakdown showed writes were **7%** of the
rebuild and reads were 93%. That work would have saved three seconds out of forty. It was not done.

Two changes made on a wrong theory — memory-mapping the database and enlarging the page cache — were
**removed** after measurement showed they changed nothing, rather than kept as cargo.

---

## 5. Deliberate departures, recorded

**The index lives beside the store, not under Caches.** It is large enough to be reclaimed first
under pressure, and search is a primary way of using the app rather than a convenience. Still
derived, still deletable, still rebuildable. See `docs/03-storage-matrix.md`.

**A result's snapshot body carries the stored excerpt, not the full text.** The full text is indexed
for matching and authoritative in the store. A result row shows a preview; holding every body twice
would multiply the file for no gain.

**Trigrams index titles only.** A trigram index over every body would roughly double the file for a
case that rarely arises — people search bodies by word and titles by fragment.

**One letter does not run a search.** It matches nearly everything and means nothing. Two characters
is the threshold; a query of pure operators runs however short it is.

**`optimize` is not run after a rebuild.** It merges b-tree segments that accumulate from
one-at-a-time inserts; a rebuild has just written the index in a few large transactions, so there is
almost nothing to merge and it cost most of the rebuild's remaining margin.

---

## 6. Not built in Phase B

- Saved searches are creatable and run, but **not yet reorderable or pinnable** from the sidebar.
- The `huge` (200,000-item) benchmark scale exists and is runnable, but the published 200k figure
  has **not** been measured — only the 50k one. Claiming it without running it would be exactly the
  thing the brief forbids.
- Search results are not yet keyboard-traversable with ↑/↓ from the field.
- `counts.compute` remains the slowest thing in the app on a large library. SQL-backed counts against
  this same sidecar would remove it, and that is now much cheaper to do than it was.
