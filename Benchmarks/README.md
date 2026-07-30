# Benchmarks

Timing checks that will not redden a build because the machine was busy.

## Running them

They are **off by default**. An ordinary `swift test` never executes them.

```bash
ELEPHRUIT_BENCHMARKS=1 swift test --package-path Packages/ElephruitKit --filter PhaseA1Benchmarks
```

The reduced corpus — 5,700 items — keeps a run under ten seconds. For the full one:

```bash
ELEPHRUIT_BENCHMARKS=1 ELEPHRUIT_BENCHMARK_SCALE=full swift test --package-path Packages/ElephruitKit --filter PhaseA1Benchmarks
```

## How a budget is decided

Each run first executes a deterministic calibration workload — mixed integer, allocation, and
hashing work, because a machine can be fast at one and slow at another — and compares it against
`reference.json`. The ratio is `hostFactor`, and budgets scale by it. A machine running at half
speed gets twice the budget instead of a red build.

Two things stop that from hiding a real problem:

- An **absolute ceiling** of 4× the budget applies regardless of calibration.
- Both figures are **always printed**. A flat normalised number beside a climbing raw one is a real
  slowdown being absorbed by calibration, and reporting only the normalised one would conceal
  exactly the thing worth knowing.

```
sidebar.render   normalised   0.00 ms  (budget   5.00)   raw   0.00 ms   hostFactor 1.00
today.load       normalised  26.62 ms  (budget  30.00)   raw  26.62 ms   hostFactor 1.00
```

Each measurement is the **median** of several iterations. One descheduled iteration should not
decide the result, and a mean lets it.

## The corpus

Generated, not templated. An index over `Item 1`…`Item 50000` proves nothing: every title shares a
prefix, every term has the same frequency, and the posting lists look nothing like a real library's
— which is the exact property search performance depends on. A seeded Markov chain over sample
prose gives realistic term frequencies and genuinely distinct titles, and the seed makes a run
reproducible so a regression is a regression rather than a different corpus.

## The reference machine

`reference.json` records where the published budgets were set, so "under 30 ms" means something
specific. Regenerate it on a new reference machine by reading the calibration figure the
`reportEnvironment` benchmark prints.

## What these are *not*

The primary acceptance criterion for the sidebar is behavioural — **zero item fetches during a
render**, asserted by `FetchAudit` in the ordinary suite. That passes or fails identically on any
machine under any load. These benchmarks are the secondary check: they catch a change that is
correct but slow.
