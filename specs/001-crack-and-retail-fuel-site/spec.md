# Feature Specification: Diesel Crack Spreads & Retail Fuel Prices

**Feature Branch**: `001-crack-and-retail-fuel-site`

**Created**: 2026-08-17

**Status**: Draft

**Input**: User description: "Static data-visualization site on GitHub Pages showing diesel crack spreads (NWE ICE gasoil vs Brent, US NYH ULSD vs Brent/WTI) and retail diesel/gasoline prices with Sweden highlighted against EU-27 and the USA, weekly from 2022."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Read the refining margin on diesel (Priority: P1)

Someone following fuel markets opens the site and immediately sees how much a
refiner earns per barrel turning crude into diesel, plotted weekly since the start
of 2022. They can switch between the US view (NYH ULSD against Brent, and against
WTI) and the North-West European view (ICE gasoil against Brent), and read off both
the 2022 spike and where the margin sits today.

**Why this priority**: This is the headline the site is named for. It is the only
chart that requires deriving a number rather than replotting a published one, and
it is buildable from the EIA API alone — the NWE leg can arrive later without
blocking the page.

**Independent Test**: Load the site with only the US crack series published. The
crack chart renders three or more years of weekly points, the region toggle offers
both regions, and selecting NWE with no data shows an explicit "manual data not
supplied" state rather than an empty or broken chart.

**Acceptance Scenarios**:

1. **Given** the pipeline has run with a valid EIA key, **When** a visitor opens the
   crack chart, **Then** they see weekly ULSD–Brent and ULSD–WTI spreads in USD per
   barrel from 2022-01-03 to the most recent week with enough trading days behind
   it (amended by 003 and 004 — see FR-007).
2. **Given** a visitor hovers any point, **When** the tooltip appears, **Then** it
   names the week, each series, and the spread to two decimals in USD/bbl.
3. **Given** `data/manual/ice_gasoil.csv` contains rows, **When** the visitor selects
   the NWE region, **Then** the gasoil–Brent crack renders from those rows.
4. **Given** that file contains only its header, **When** the visitor selects NWE,
   **Then** the chart states that ICE gasoil has no free API and points at the file
   to populate.

---

### User Story 2 - See where Sweden sits on pump prices (Priority: P1)

A visitor wants to know whether Swedish diesel is expensive. They see every EU-27
country plus the USA drawn weekly, with Sweden picked out boldly and everything else
in restrained grey, so Sweden's position in the pack is legible at a glance. Hovering
any grey line raises it and names the country.

**Why this priority**: This is the comparison the site exists to make. It depends on
a different source from Story 1, so the two can be built and shipped in either order.

**Independent Test**: Load the retail chart with the Oil Bulletin and EIA retail
series published. Sweden is visually distinct without reading the legend, all 27 EU
members are present, and the USA is distinguishable from the EU lines by line style.

**Acceptance Scenarios**:

1. **Given** the retail chart is open, **When** the visitor looks at it without
   interacting, **Then** Sweden is the visually dominant line and the USA is drawn
   dashed, distinct from the solid EU lines.
2. **Given** the visitor hovers a grey line, **When** the pointer is near it, **Then**
   that country's line is emphasised and the tooltip names the country and price.
3. **Given** the visitor toggles fuel from diesel to gasoline, **When** the chart
   updates, **Then** it shows Euro-super 95 for the EU and US regular gasoline, with
   the same country set and the same highlighted Sweden.
4. **Given** the visitor toggles tax treatment to "without tax", **When** the chart
   updates, **Then** only countries publishing a pre-tax price are drawn and the
   omission is stated rather than shown as a gap in an otherwise-complete chart.
5. **Given** the visitor switches currency to SEK, **When** the chart updates,
   **Then** every series is converted at that week's ECB reference rate and the axis
   label and tooltip both read SEK per litre.

---

### User Story 3 - Trust and reuse the numbers (Priority: P2)

A visitor who wants to cite or rebuild the chart can find, without leaving the site
or guessing, which upstream series each line comes from, the licence covering it,
when the data was last refreshed, and the exact arithmetic behind each derived
series.

**Why this priority**: Provenance is a constitutional requirement, but the charts
carry value before the documentation is complete.

**Independent Test**: From the published site and README alone, a reader can name the
EIA series ID behind each US line, the Oil Bulletin column behind each EU line, and
reproduce a crack spread by hand from two published numbers.

**Acceptance Scenarios**:

1. **Given** a visitor reads the page, **When** they look for provenance, **Then**
   each chart names its sources and the page states the refresh date.
2. **Given** a reader opens the README, **When** they look up the crack definition,
   **Then** they find `ULSD USD/gal × 42 − Brent USD/bbl` stated explicitly.
3. **Given** a developer clones the repository, **When** they set `EIA_API_KEY` and
   run `pipeline/run.sh`, **Then** they reproduce the published JSON.

---

### User Story 4 - Stay current without anyone touching it (Priority: P3)

The site refreshes itself weekly. New Oil Bulletin and EIA observations appear
without a human running anything, and a failure upstream leaves the last good data
published rather than replacing the site with an error.

**Why this priority**: Valuable but strictly after the charts work; a manually
refreshed site is still a working site.

**Independent Test**: Trigger the refresh workflow manually. It commits changed JSON
and redeploys; run it twice with no upstream change and the second run commits
nothing.

**Acceptance Scenarios**:

1. **Given** the weekly cron fires, **When** upstream data has advanced, **Then**
   refreshed JSON is committed and the site redeploys.
2. **Given** the cron fires with no upstream change, **When** the pipeline completes,
   **Then** no commit is made.
3. **Given** an upstream source is unreachable, **When** the pipeline fails, **Then**
   the previously published data stays live and the workflow reports failure.

### User Story 5 - See the margin against a breakeven (Priority: P2)

Rather than reading a line against a bare axis, a visitor sets a threshold — a
refinery breakeven, a target margin — and sees the crack spread as a filled mountain
that is green where it clears the threshold and red where it does not. The eye picks
out the profitable and pressured stretches without reading any numbers.

**Why this priority**: It reframes data Story 1 already publishes, so it costs no new
source. It changes the crack chart from something you read into something you scan.

**Independent Test**: With only `cracks.json` published, switch the crack chart to
threshold view, drag the threshold, and watch the shading cross over at the value set.

**Acceptance Scenarios**:

1. **Given** the crack chart is in threshold view, **When** the visitor looks at it,
   **Then** the area between the line and the threshold is filled green where the
   spread is above it and red where below, with the threshold drawn as a dashed
   reference line labelled with its value.
2. **Given** the visitor changes the threshold, **When** the value updates, **Then**
   the shading and the reference line move with it, without refetching data.
3. **Given** a week has no observation, **When** the chart renders, **Then** the fill
   breaks at that week rather than spanning the gap.
4. **Given** threshold view is active, **When** the visitor switches to plain line
   view, **Then** the same series renders unfilled and the threshold is retained for
   when they switch back.

---

### User Story 6 - Watch rockets and feathers (Priority: P2)

A visitor compares crude benchmarks against pump prices on one chart — crude in USD
per barrel on the left axis, retail fuel in USD per gallon on the right — to see the
asymmetry: pump prices chase a crude spike up quickly and drift back down slowly.

**Why this priority**: It uses series Stories 1 and 2 already fetch, and it is the
comparison that explains the retail chart's shape. It needs both, so it lands after
either alone.

**Independent Test**: With `cracks.json` and `retail.json` published, the dual-axis
chart draws Brent and WTI against US retail diesel and gasoline, each axis labelled
in its own unit, and the axes align at a common baseline rather than floating.

**Acceptance Scenarios**:

1. **Given** the chart is open, **When** the visitor reads it, **Then** crude series
   are on the left axis in USD/bbl and retail series on the right in USD/gal, with
   both units named on their axis.
2. **Given** the visitor hovers a week, **When** the tooltip appears, **Then** it
   lists every visible series with its own unit, not a shared one.
3. **Given** the visitor toggles a series off via the legend, **When** the chart
   updates, **Then** the remaining series rescale and the hidden one's axis stays
   labelled if its partner is still shown.

### Edge Cases

- **Sources disagree on the week.** EIA spot prices are daily, EIA retail is weekly
  on Mondays, and the Oil Bulletin publishes weekly on Mondays covering the prior
  week. All observations are bucketed to an ISO week and keyed to that week's Monday;
  a partial current week is dropped rather than shown as a dip.
- **A country stops reporting.** Croatia joined the euro; Bulgaria adopted it in
  2026; the UK appears in the Oil Bulletin history but is not in the EU-27. Country
  membership is resolved from an explicit list, not from whatever columns happen to
  be present.
- **No pre-tax price exists for a country.** Some countries publish only with-tax
  figures for some products. The without-tax view drops those countries and says so.
- **A holiday week has no ECB rate.** The reference rate for a week is the last
  published rate on or before that week's Monday.
- **The Oil Bulletin file moves.** Its download URL is a UUID that the Commission
  reissues. The pipeline fails loudly with the current page URL in the error rather
  than silently publishing a truncated series.
- **A US spot series has a gap.** Brent, WTI, and ULSD are separate series with
  independent holidays; a crack spread is computed only for weeks where both legs
  exist, and is null otherwise.
- **ICE gasoil is absent.** There is no free API. The NWE crack reads a manually
  maintained CSV that ships empty.

## Requirements *(mandatory)*

### Functional Requirements

**Data acquisition**

- **FR-001**: The pipeline MUST fetch NYH ULSD spot (`EER_EPD2DXL0_PF4_Y35NY_DPG`),
  Brent (`RBRTE`), and WTI (`RWTC`) from the EIA v2 petroleum spot-price endpoint,
  authenticated by `EIA_API_KEY` read from the environment.
- **FR-002**: The pipeline MUST fetch US weekly retail regular gasoline
  (`EMM_EPMR_PTE_NUS_DPG`) and on-highway diesel (`EMD_EPD2D_PTE_NUS_DPG`) from EIA.
- **FR-003**: The pipeline MUST fetch the EU Weekly Oil Bulletin price history
  workbook and extract Euro-super 95 and automotive gas oil, both with and without
  taxes, for all EU-27 countries.
- **FR-004**: The pipeline MUST fetch ECB EUR/USD and EUR/SEK daily reference rates.
- **FR-005**: The pipeline MUST read the NWE gasoil leg from
  `data/manual/ice_gasoil.csv`, treating an absent or header-only file as "no data"
  rather than as an error.
- **FR-006**: The pipeline MUST fail with a diagnosable message naming the failing
  source when any automated source is unreachable or returns an unexpected shape.

**Transformation**

- **FR-007**: All observations MUST be aggregated to ISO weeks, each keyed to that
  week's Monday.

  *Amended by [003](../003-daily-crack-and-ma7/spec.md) and
  [004](../004-current-week-and-datestamp/spec.md).* This originally read "with
  incomplete current weeks excluded", which conflated two different things and got
  both slightly wrong:

  - **Which weeks exist** is now the axis's job. It ends at the later of the last
    complete week and the most recent week a weekly point-in-time survey has
    published, capped at the build week (004, FR-301/FR-302). Excluding the current
    week unconditionally discarded a published retail price for up to seven days —
    for a survey, one observation *is* the week.
  - **Whether a week has enough data** is now `min_week_obs` (003, FR-201), and
    applies only to daily-sampled sources, where an unfinished week really is a
    partial mean. The old rule missed this entirely: it dropped the *current* week
    while still averaging a *previous* week over however many days had arrived.
- **FR-008**: Oil Bulletin prices MUST be converted from EUR per 1000 litres to
  EUR per litre; EIA retail prices MUST be retained as USD per gallon with an
  accompanying USD-per-litre conversion.
- **FR-009**: Crack spreads MUST be computed as the product price expressed in USD
  per barrel minus the crude price in USD per barrel, using 42 US gallons per barrel,
  and MUST be null for any week missing either leg.
- **FR-010**: The published series MUST cover 2022-01-01 onward.
- **FR-011**: Country membership MUST come from an explicit EU-27 list; the UK and
  the Oil Bulletin's own EU/euro-area aggregate columns MUST be excluded from the
  country set.
- **FR-012**: Output MUST be static JSON under `site/public/data/`, one file per
  chart, each carrying its own provenance and refresh metadata.

**Presentation**

- **FR-013**: The crack chart MUST offer a region toggle between US and NWE and MUST
  render an explicit empty state, naming the manual CSV, when NWE has no data.
- **FR-014**: The retail chart MUST draw Sweden emphasised, other EU-27 countries as
  thin grey lines, and the USA dashed.
- **FR-015**: Hovering a country line MUST emphasise it and identify the country.
- **FR-016**: The retail chart MUST offer independent toggles for fuel
  (diesel / gasoline), tax treatment (with / without), and currency (EUR / USD / SEK).
- **FR-017**: Currency conversion MUST use the ECB reference rate for the same week
  as each observation, not a single spot rate applied to the whole series.
- **FR-018**: Each chart MUST state its sources and the data's refresh date.
- **FR-019**: The site MUST function as static files served from any path. The only
  permitted third-party origins at page load are the ECharts CDN and a cookieless
  analytics beacon. Neither may be load-bearing: with both blocked, every chart
  must still render from the local JSON.
- **FR-023**: The crack chart MUST offer a threshold ("mountain") view filling the
  area between the spread and a visitor-set threshold, green above and red below,
  with the threshold drawn as a labelled dashed reference line.
- **FR-024**: The threshold MUST be adjustable by the visitor and MUST re-render
  from data already in the browser, without refetching.
- **FR-025**: Threshold fills MUST break at missing weeks rather than spanning them.
- **FR-026**: The site MUST provide a dual-axis chart plotting crude benchmarks
  (USD/bbl, left axis) against US retail fuel prices (USD/gal, right axis), with each
  axis labelled in its own unit and the tooltip reporting per-series units.
- **FR-027**: `cracks.json` MUST publish the underlying Brent, WTI, and ULSD levels
  alongside the derived spreads, so the dual-axis chart needs no additional file.

**Operations**

- **FR-020**: A weekly scheduled workflow MUST run the pipeline, commit changed JSON,
  build the frontend, and deploy to GitHub Pages, committing nothing when no data
  changed.
- **FR-021**: A CI workflow MUST run on push and compile the frontend and validate
  the pipeline SQL without requiring an API key.
- **FR-022**: The README MUST document every source, its licence, and the ICE gasoil
  manual-CSV limitation.

### Key Entities

- **Weekly observation** — a value for one series in one ISO week: week-start date,
  series key, value, native unit. The atomic unit everything else is built from.
- **Spot price series** — a daily upstream price (ULSD, Brent, WTI) reduced to a
  weekly mean, in USD per gallon or USD per barrel.
- **Retail price series** — a pump price for one country, one fuel, one tax
  treatment, in its native currency per litre.
- **Crack spread** — a derived weekly series: one product leg, one crude leg, a
  region label, and the resulting USD-per-barrel margin.
- **FX rate** — a weekly EUR-denominated ECB reference rate for USD and SEK, used by
  the frontend to convert on demand.
- **Chart dataset** — one published JSON file: a week axis, a set of named series
  aligned to it, and a provenance block naming sources, licences, and refresh date.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The crack chart shows at least 190 weekly observations (2022 through
  the present) for each US series, with no fabricated points.
- **SC-002**: All 27 EU member states plus the USA appear in the retail chart's
  with-tax diesel view.
- **SC-003**: A visitor can identify Sweden's line and its rank among EU countries
  within five seconds, without using the legend.
- **SC-004**: Every toggle combination — 2 fuels × 2 tax treatments × 3 currencies —
  renders without error and with correct axis units.
- **SC-005**: A clean clone plus `EIA_API_KEY` reproduces the published JSON exactly.
- **SC-006**: The complete published site, excluding the CDN-loaded charting library,
  is under 5 MB.
- **SC-007**: The weekly workflow completes in under 10 minutes.
- **SC-008**: Changing the crack threshold re-renders in under 100 ms, with no
  network request.
- **SC-009**: On the dual-axis chart a visitor can identify, for the 2022 crude
  spike, that retail prices rose within weeks and fell back over months — the
  rockets-and-feathers asymmetry is visible without computing anything.

## Assumptions

- The EIA v2 API remains free with a self-service key and keeps its current route
  and series identifiers; the key is supplied to CI as a repository secret.
- The Commission continues to publish the Oil Bulletin price-history workbook with
  its current `{CC}_price_with_tax_{product}` column convention. The download URL is
  a reissued UUID and is treated as configuration, not as a constant.
- ECB reference rates are adequate for a chart comparing pump prices; intraday or
  transactional rates are out of scope.
- ICE gasoil futures settlements cannot be redistributed from a free source. The NWE
  crack ships as a documented stub and is populated only by a user who has their own
  licensed access.
- Visitors use a current desktop or mobile browser with JavaScript enabled; there is
  no server-rendered fallback.
- Sweden is the reference country. Making the highlighted country selectable is a
  plausible later feature but is out of scope here.
