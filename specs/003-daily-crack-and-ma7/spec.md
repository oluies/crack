# Feature Specification: Daily Crack Spreads and the 7-Day Ruler

**Feature Branch**: `003-daily-crack-and-ma7`

**Created**: 2026-08-19

**Status**: Draft

**Input**: "diesel crack should be at usd 102" — a reader comparing the site
against a live market quote. Investigation found the site correct in its own
terms and misleading in practice, for two separate reasons. This spec covers
both.

## Why

The published weekly crack for the week of 2026-08-10 was **86.28 USD/bbl**. Two
things stood between that number and the market:

1. **EIA's own publication lag.** EIA's daily spot series ended 2026-08-11 when
   queried on 2026-08-19 — eight days behind. No schedule change can fix this;
   it is a property of the source, and the site must state it rather than let a
   reader assume the last point is today.

2. **The last week was an average of two days, not five.** `40_cracks.sql`
   aggregated `AVG(value)` per ISO week with no minimum-coverage condition, so a
   week EIA had only begun publishing was averaged over whatever days existed and
   published as if complete:

   ```
   week 2026-08-10:  (84.16 + 88.39) / 2       = 86.28   <- 2 of 5 business days
   week 2026-08-03:  (74.82 + ... + 76.60) / 5 = 74.67   <- complete
   ```

   Both matched the published file exactly, which is how the defect was
   confirmed. Because the crack was climbing steeply, the partial week read low,
   and a partial average is indistinguishable from a complete one on the chart.

The reader's 102 could be neither confirmed nor refuted from EIA — the data runs
out at 88.39 against Brent and 96.88 against WTI, both still rising. That is
itself the finding: **the site had no view at all of the most recent, most
volatile days**, because weekly averaging is the only granularity published.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Read the crack at daily resolution (Priority: P1)

A reader who follows the market wants to compare the site against a quote they
have just seen. They switch the crack chart to daily and get every observation
EIA has published, up to the last one, with no averaging between them and the
market.

**Why this priority**: It is the reason the discrepancy was reported. Weekly
averaging is a smoothing choice; at 4 USD/bbl of daily movement it hides more
than it clarifies.

**Independent Test**: With `cracks_daily.json` published, the daily view draws
one point per EIA observation date and its last point equals the last row of the
EIA response.

**Acceptance Scenarios**:

1. **Given** the daily view, **When** the reader opens it, **Then** the x-axis is
   observation dates only — dates on which a source actually published — with no
   padding for non-trading days.
2. **Given** the daily view, **When** the reader reads the last point, **Then** it
   is the most recent EIA observation and the chart states that date and the lag
   in days.
3. **Given** the reader switches back to weekly, **When** the chart updates,
   **Then** the weekly series is unchanged from before this feature apart from
   partial weeks now being absent.

### User Story 2 - See the trend through the noise (Priority: P1)

Daily spot is noisy enough that a single day proves little. The reader wants a
7-day average drawn over the daily series so a move is separable from a jump.

**Why this priority**: Daily resolution without smoothing trades one
misreading for another. The two ship together or neither is an improvement.

**Independent Test**: The MA series is present, is drawn over the daily series,
and its value on any date equals the mean of the daily observations in the
trailing 7 calendar days ending that date.

**Acceptance Scenarios**:

1. **Given** the daily view, **When** it renders, **Then** a 7-day average is
   drawn over the daily line and is visually distinguishable from it.
2. **Given** any date on the MA line, **When** its value is compared against the
   daily observations of the preceding week, **Then** it equals their unweighted
   mean.
3. **Given** the reader turns the ruler off, **When** the chart updates, **Then**
   the daily series remains and only the average is removed.
4. **Given** the first days of the series, **When** the window holds fewer than 3
   observations, **Then** the MA is absent rather than computed from one or two.

### User Story 3 - Never be shown a partial period as a complete one (Priority: P1)

**Independent Test**: A week with fewer than 3 daily observations publishes as
`null`, and the chart draws a gap.

**Acceptance Scenarios**:

1. **Given** a week EIA has only partly published, **When** the weekly chart
   renders, **Then** that week is a gap, not a low point.
2. **Given** the same week later completes upstream, **When** the pipeline next
   runs, **Then** the week appears with its full-coverage average.

### Edge Cases

- **The weekly crack now ends earlier than the weekly retail series.** EIA's
  8-day lag plus the ≥3-day rule means the last one or two weekly crack points
  are routinely absent, while the Oil Bulletin retail series is current. The
  files still share one week axis; the crack series simply ends in nulls. This is
  the intended consequence, and the daily view is where recency lives.
- **Public holidays.** A 4-day trading week passes the ≥3 rule and is averaged
  over 4 days. Requiring 5 would drop a legitimate week every Easter.
- **The MA window is calendar days, not observations.** 7 calendar days holds 5
  business-day observations in steady state — one trading week — and shortens
  over a holiday instead of silently reaching 9 calendar days back, which a
  7-observation window would do.
- **The daily axis is observation dates, not a calendar.** Weekends are not
  missing data and must not render as gaps.
- **ICE gasoil remains absent.** The NWE leg has no daily source either; it stays
  the documented empty series in both views.
- **`meta.generated` is not the data date.** A reader cannot infer freshness from
  it — it is when the pipeline ran. The lag must be computed from the last
  observation, and stated.

## Requirements *(mandatory)*

- **FR-201**: Weekly leg aggregation MUST require at least 3 daily observations
  in the ISO week; a week below that MUST publish as `null` for that leg, and the
  spreads derived from it MUST follow by null propagation, never by a special
  case.
- **FR-202**: The pipeline MUST publish `cracks_daily.json` carrying every EIA
  observation date, the daily spreads, and the daily crude and ULSD levels.
- **FR-203**: The daily file MUST carry, for each daily spread, a trailing 7
  **calendar** day unweighted mean of the daily values, emitted only where the
  window holds at least 3 observations.
- **FR-204**: The daily file's axis MUST be `days` — observation dates only, in
  ascending order, with no weekend or holiday padding. It MUST NOT be assumed
  positionally alignable with the `weeks` axis of the other files.
- **FR-205**: The crack section MUST offer a Weekly/Daily switch, and in the
  daily view a control to show or hide the 7-day ruler.
- **FR-206**: The daily view MUST state the date of its last observation and the
  resulting lag in whole days, computed against `meta.generated`.
- **FR-207**: The MA definition — trailing 7 calendar days, unweighted, minimum 3
  observations — MUST be stated in `meta.formulae` and visible in the UI, not
  only in this spec.
- **FR-208**: `verify.sql` MUST assert that no published weekly leg derives from
  fewer than 3 daily observations, and `pipeline/test/negative.sh` MUST prove
  that assertion can fail.

## Out of scope

- Intraday or real-time quotes. EIA's lag is the floor on freshness and no
  scheduling change moves it.
- Any second source to close the lag. That is a sourcing decision, not a
  charting one.
- Daily retail prices. The Oil Bulletin is weekly by construction.
- Other moving-average windows, Bollinger bands, or further TA overlays. One
  ruler, defined precisely.
