# Feature Specification: Publish the Current Survey Week, and Say What the Data Covers

**Feature Branch**: `004-current-week-and-datestamp`

**Created**: 2026-08-19

**Status**: Draft

**Input**: "fix the retail week calendar too, can we write 'last updated' in the
header, and also state which dates the data cover" — following
[003](../003-daily-crack-and-ma7/spec.md), which found the crack chart a week
behind and left the same problem in place for retail.

## Why

Feature 003 introduced `min_week_obs` so a partly-published week could not be
averaged as if complete. That is the right rule for a **daily-sampled** source.
It was then noticed that the axis itself applies a second, cruder version of the
same idea to **every** source: `stg.week_calendar` ended at the last *complete*
week, so the current week was discarded regardless of what had been published in
it.

For the Oil Bulletin and EIA's `pri/gnd` retail series that is simply wrong. They
are weekly point-in-time surveys — one observation *is* the week, not a partial
mean of it. On 2026-08-19 both had published the week of 08-17 and the site was
still showing 08-10, up to seven days of avoidable staleness in the chart most
readers open first.

Separately, the page never said when it was refreshed or what period it covered.
`meta.generated` appeared under each chart as "Refreshed …", which is when the
*pipeline ran* — a different thing, and the confusion that started 003.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See the most recent published pump price (Priority: P1)

**Independent Test**: With a survey published for the current week, `retail.json`
carries that week and the chart draws it.

**Acceptance Scenarios**:

1. **Given** the Oil Bulletin has published the current week, **When** the
   pipeline runs, **Then** the axis includes it and the prices are drawn.
2. **Given** no survey has published in the current week, **When** the pipeline
   runs, **Then** the axis ends at the last complete week exactly as before.
3. **Given** the crack legs have too few trading days for those weeks, **When**
   the chart renders, **Then** the crack series ends earlier than the retail
   series on the same shared axis, and each states its own coverage.

### User Story 2 - Know how old the page is without reading the charts (Priority: P1)

**Independent Test**: The header states the refresh date, the weekly coverage and
the last daily observation; each chart states its own coverage.

**Acceptance Scenarios**:

1. **Given** the data has loaded, **When** the reader looks at the header,
   **Then** it states when it was updated and the span the data covers.
2. **Given** the fetch fails, **When** the page renders the failure banner,
   **Then** the header stamp is empty rather than showing a date with no data.
3. **Given** two charts whose series end on different weeks, **When** the reader
   reads their provenance lines, **Then** the two state different end dates.

### Edge Cases

- **Coverage is the series, not the axis.** The shared axis now runs to the last
  surveyed week while the crack series ends one to two weeks earlier. Printing
  the axis as coverage would promise data that is not there — the exact
  confusion 003 was raised to fix, reintroduced in the caption.
- **A bad upstream date must not move the axis.** The bound now depends on
  source data, so a corrupt week could push the axis into the future. Capped at
  the current week and floored at the last complete week; `verify 1e` asserts
  both, because an axis that is merely *wrong* still looks normal.
- **A stalled survey must not shorten the axis.** The floor is what lets
  `verify 7`/`7b` see a growing gap instead of an axis that quietly tracks the
  stalled source and reports itself fresh.
- **Spot must not extend the axis.** Only weekly point-in-time surveys are
  consulted. A daily source's presence in the current week says nothing about
  whether that week is complete.

## Requirements *(mandatory)*

- **FR-301**: The week axis MUST extend to the most recent week in which a weekly
  point-in-time survey has published, capped at the current week.
- **FR-302**: The axis MUST NOT end before the last complete week, whatever the
  sources have published.
- **FR-303**: Only weekly point-in-time sources may extend the axis. Daily-sampled
  sources MUST NOT.
- **FR-304**: `verify.sql` MUST assert the axis ends within those bounds, and
  `negative.sh` MUST prove that assertion can fail in both directions.
- **FR-305**: The page header MUST state the refresh date, the weekly span the
  data covers, and the last daily observation.
- **FR-306**: Each chart MUST state the coverage of **its own** series, which may
  differ from the axis and from the other charts.
- **FR-307**: The header stamp MUST be empty when the data has not loaded.

## Out of scope

- Any change to `min_week_obs` or to how daily observations are aggregated.
- Making the crack series as current as the retail series. EIA's lag is the
  floor on that, as 003 records.
