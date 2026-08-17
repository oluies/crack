# Crack Constitution

Governing principles for `crack` — a static site charting diesel crack spreads and
European/US retail fuel prices. These rules bind every feature spec, plan, and
implementation in this repository.

## Core Principles

### I. Static by Construction

The published artefact is a directory of files. No server, no runtime database, no
API call from the browser to anything but the site's own origin. Every number the
page renders is baked into a JSON file at build time. This is not a performance
preference — it is what makes the site free to host, trivially archivable, and
immune to an upstream API outage taking the charts down.

Consequence: any feature that would require a request at page-load time is out of
scope until the constitution is amended.

### II. SQL Is the Pipeline

Data acquisition, reshaping, and aggregation live in DuckDB SQL under `pipeline/`.
Shell exists only to sequence SQL scripts and to move bytes that DuckDB cannot fetch
itself. Python is permitted only where DuckDB genuinely cannot do the job, and every
such use must carry a comment naming the specific limitation.

The SQL is idiomatic DuckDB — `read_json_auto`, `read_xlsx`, `UNPIVOT ... ON
COLUMNS(*)`, `QUALIFY`, `EXCLUDE`/`REPLACE`. Do not hand-roll in a scripting
language what a DuckDB idiom already expresses.

### III. Provenance Is Part of the Data

Every published series states where it came from, under what licence, and when it
was last refreshed. A number whose origin cannot be named does not ship. Derived
series (crack spreads, currency conversions) state their formula in the same place
the number is documented.

Where a source is unavailable — as ICE gasoil futures are, having no free API — the
gap is documented as a gap, backed by an explicit manually maintained file, and
surfaced in the UI as such. A stub is honest; a silently interpolated series is not.

### IV. Minimal Frontend Surface

The frontend is Scala 3 / Scala.js / Laminar, built with Mill. ECharts arrives from
a CDN and is reached through a hand-written `js.native` facade covering only the
methods actually called. No ScalablyTyped, no bundler, no npm dependency graph.

New facade members are added when a chart needs them, never speculatively. If the
facade grows past what one screen of code can hold, that is a signal to reconsider,
not to generate bindings.

### V. Reproducible Refresh

`pipeline/run.sh` is the single entry point and is idempotent: running it twice
against the same upstream data produces byte-identical output. Timestamps that would
break this belong in a separate metadata field, not interleaved with observations.
The weekly GitHub Actions job runs exactly this script — CI has no privileged path
that a developer cannot reproduce locally with an API key.

## Data Integrity Constraints

- **Units are explicit and normalised at the pipeline boundary.** Oil Bulletin
  prices arrive as EUR per 1000 litres and are stored as EUR/L. EIA retail prices
  arrive as USD/gal. Crack spreads are USD/bbl. A column name carries its unit.
- **Weekly means weekly.** Sources publish on different weekdays; observations are
  keyed to the ISO week and the representative date is that week's Monday.
  Cross-source joins happen on the week key, never on the raw publication date.
- **Currency conversion is a presentation concern.** Series are stored in their
  native currency alongside the ECB reference rates for the same week; the frontend
  converts. This keeps one source of truth and makes the EUR/USD/SEK toggle exact
  rather than three separately rounded pipelines.
- **Missing is null, never zero and never carried forward.** Gaps render as gaps.

## Development Workflow

- Work proceeds through Spec Kit: constitution → `spec.md` → `plan.md` →
  `tasks.md` → implementation. Specs describe observable behaviour and data
  contracts, not code structure.
- Every commit is reviewed by `roborev` before the feature branch merges. Findings
  are resolved or explicitly waived with a reason recorded in the review.
- CI runs on push: Mill compile of the Scala.js app, and a pipeline dry run against
  fixtures so a broken SQL script fails before the weekly cron does.
- The weekly cron commits refreshed JSON. A refresh that produces no diff commits
  nothing.

## Governance

This constitution supersedes convenience. Where a plan conflicts with it, the plan
changes or the constitution is amended in the same pull request that departs from
it — never silently.

Amendments record what changed and why. Complexity that is not demanded by a
principle above must be justified in the plan's Complexity Tracking section or
removed.

**Version**: 1.0.0 | **Ratified**: 2026-08-17 | **Last Amended**: 2026-08-17
