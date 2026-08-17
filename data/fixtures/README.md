# Fixtures

`eia_spot_000.json` and `eia_retail_000.json` are **synthetic**. They are smooth
sinusoids around plausible levels, not observations — nobody's diesel margin ever
traced a sine wave.

They exist for one reason: EIA is the only source needing an API key, and pull
requests from forks cannot see repository secrets. `pipeline/run.sh --fixtures`
substitutes these so CI can exercise the real SQL — the envelope shape, the
`response.data` unnest, the week bucketing, the crack arithmetic — without a key.

The Oil Bulletin and ECB are keyless and are fetched live even in fixtures mode,
so a reissued Oil Bulletin UUID fails in CI rather than in the weekly job.

**Never publish a fixtures build.** `run.sh --fixtures` says so loudly, and
`ci.yml` restores the committed JSON afterwards.

To regenerate, see the `duckdb -c` invocation recorded in the commit that added
this directory.
