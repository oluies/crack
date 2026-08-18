# Feature Specification: US Regional Retail Spread

**Feature Branch**: `002-us-regional-spread`

**Created**: 2026-08-18

**Status**: Draft

**Input**: "maybe we can add a number for each state with tax?" — answered by
[research.md](./research.md): per-state *tax* is not available from any pipeline
source, but per-state and per-region *prices* partly are. This spec covers what
the data supports.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - See how much a US pump price varies inside the country (Priority: P1)

A visitor who has just noticed the single US line sitting ~1 EUR/L below the EU
pack wants to know whether "the USA" is really one price. They see the national
average drawn boldly against the individual states and regions, and read off the
spread — California against Texas — which is largely a tax story and makes the
single national line legible as an average rather than a fact.

**Why this priority**: It answers the question the EU chart provokes, using data
already reachable with the existing API key, and needs nothing maintained by hand.

**Independent Test**: With `usregions.json` published, the chart draws the US
average bold against the regional lines, and the fuel toggle switches between the
state view and the PADD view.

**Acceptance Scenarios**:

1. **Given** the chart is open on petrol, **When** the visitor looks at it,
   **Then** the nine states EIA publishes are drawn against a bold US average.
2. **Given** the visitor switches to diesel, **When** the chart updates, **Then**
   it shows the five PADD regions plus California against the same bold average,
   and states that diesel is published by region rather than by state.
3. **Given** the visitor changes currency, **When** the chart updates, **Then**
   every line converts at that week's ECB rate, as the retail chart does.
4. **Given** any week, **When** the visitor reads the chart, **Then** the highest
   and lowest region are identifiable without using a legend.

### Edge Cases

- **Diesel is not published per state.** Only California has a state diesel
  series; everything else is PADD-level. The two fuels therefore have different
  geographies, and the chart says so rather than implying states throughout.
- **California appears in both views.** It is a state series in the petrol view
  and, for diesel, the one state EIA breaks out of the West Coast PADD. It is
  labelled as a state in both.
- **A region stops reporting.** Series are left-joined onto the shared week
  calendar like every other series; a gap renders as a gap.
- **PADD regions overlap the national average by construction.** The average is a
  volume-weighted national figure, not the mean of the drawn lines, so it need not
  sit midway between them. Stated on the chart.

## Requirements *(mandatory)*

- **FR-101**: The pipeline MUST fetch the nine state regular-petrol series
  (`EMM_EPMR_PTE_S{CA,CO,FL,MA,MN,NY,OH,TX,WA}_DPG`).
- **FR-102**: The pipeline MUST fetch the five PADD diesel series
  (`EMD_EPD2D_PTE_R{10,20,30,40,50}_DPG`) and California (`..._SCA_DPG`).
- **FR-103**: Regional prices MUST be aggregated to the same ISO weeks and joined
  to the same week calendar as every other series.
- **FR-104**: Output MUST be a separate `usregions.json` carrying its own
  provenance, one file per chart as the contract requires.
- **FR-105**: Series MUST be published in USD per litre, converted in the browser
  like every other retail series — never in a second pre-converted currency.
- **FR-106**: The chart MUST draw the US national average emphasised and the
  regions thin, reusing the retail chart's visual language.
- **FR-107**: The chart MUST offer a fuel toggle and MUST state, on the diesel
  view, that the geography is PADD regions rather than states.
- **FR-108**: The chart MUST label the extreme regions so the spread is readable
  without a legend, subject to the same narrow-screen budget as the retail chart.

## Success Criteria *(mandatory)*

- **SC-101**: All nine states appear in the petrol view and all six geographies in
  the diesel view, for the latest published week.
- **SC-102**: A visitor can state the current spread between the most and least
  expensive US region without interacting with the chart.
- **SC-103**: Published payload stays inside the existing 5 MB budget.
- **SC-104**: No new manually maintained data source is introduced.

## Assumptions

- EIA keeps publishing these series weekly under their current identifiers; a
  disappearance is caught by the completeness invariant rather than silently
  dropping a line.
- Nine states is the whole of EIA's free state-level petrol coverage. This chart
  is not, and does not claim to be, all fifty states.
