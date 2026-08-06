# Visual QA checklist — UI/UX polish plan

The polish plan (rail-based, background-integrated moments) is verified against
these four viewports at every phase boundary. Screenshots go in the phase's PR
or working notes; this file is the checklist, not the archive.

## Baseline (recorded 2026-08-06, before any polish-plan change)

- `npm test`: 15 files, 85 tests, all passing.
- `npm run build`: passes (pre-existing warning: main chunk > 500 kB).
- `npm run lint`: passes with 3 pre-existing warnings (LogPage useMemo deps,
  UserContext fast-refresh export, hooks.ts setState-in-effect).

## Required viewports

| Viewport | Size | What it represents |
|---|---|---|
| Desktop wide | 1440 × 1000 | Feed with right utility rail |
| Desktop | 1024 × 900 | Two-column person profile, no feed rail |
| Tablet | 768 × 1024 | Bottom sheets, collapsed nav |
| Phone | 390 × 844 | Single column, mobile tab bar |

## How to capture

1. `npm run emulators` (fresh) then `npm run seed`, or `npm run emulators:resume`
   to keep existing state. The seeded Dave Okafor profile is the acceptance
   fixture for relationship identity.
2. `npm run dev`, sign in with **Use the local dev account**.
3. Drive the browser pane by JavaScript (its synthetic clicks are unreliable);
   resize to each viewport and screenshot.
4. Capture light and dark (Settings → Appearance), and `prefers-reduced-motion`
   spot checks on any surface with entrance/expand animation.

## Per-surface checks

Feed (`/`):
- No horizontal page overflow at any viewport.
- Summary metrics: separators not tiles; two-column at 390 with Going quiet
  full-width; no clipped scroller.
- Continuous vertical rail connects composer, date nodes, and moments; no
  white/opaque card, border, radius, or shadow around any memory.
- Empty state only after loading resolves; never flashes while loading.

Capture (composer):
- Opens inline at `/?capture=1`; feed stays visible behind it.
- Collapsed height 56px (54px mobile); expanded region stays rail-connected.
- Draft survives collapse and refresh; Escape collapses without losing text.

Person profile (`/people/:id`):
- Identity header: avatar, name or relationship label, Name unknown badge,
  correct last-contact line (`No conversations logged yet` vs
  `Nothing recorded yet`).
- Dave Okafor's two unnamed sons distinguishable without opening either;
  no `DO` initials on unnamed people.

Follow-ups (`/followups`):
- Sheet is right-anchored ≥ 900px, bottom sheet below; sticky footer clears
  the mobile tab bar and safe area.
- Schedule rows show structured date/time/zone, never title-embedded phrases
  as the only schedule display.

Keyboard and motion (all surfaces):
- Tab reaches everything hover reaches; focus returns to triggers on close.
- Reduced motion: same states, no movement.
