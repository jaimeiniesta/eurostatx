# AGENTS.md

Instructions for AI coding agents working on this repository.

## Project

Eurostatx is an Elixir client for the [Eurostat APIs](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access)
(`https://ec.europa.eu/eurostat/api/dissemination/...`): Statistics, SDMX 3.0 and 2.1 (data and
structure queries), Catalogue, asynchronous and files APIs, for Eurostat, Comext/Prodcom and the
REDISSTAT agencies. Its interface follows [Inex](https://hex.pm/packages/inex), and returns the
decoded JSON, the raw body or Explorer data frames.

- **Reference implementation:** [restatapi](https://github.com/eurostat/restatapi), the R package
  published by Eurostat in its GitHub organization. When the API behaviour is unclear, check what
  restatapi does. Do not copy its code.
- **API reference:** the guides linked above (read every page, they are short) and the OpenAPI spec
  at `https://ec.europa.eu/eurostat/api/dissemination/swagger-ui/sdmx-rest.yaml`. Both are
  incomplete and sometimes wrong; see the pitfalls below.
- Elixir `~> 1.18`. Use the built-in `JSON` module; do not add Jason. XML is parsed with Saxy
  (never with `:xmerl`, which creates atoms), CSV/TSV with NimbleCSV.

## Commands

| Command | Purpose |
|---|---|
| `mix test` | Unit tests, offline (Req.Test stubs and recorded fixtures) |
| `mix test --include integration` | Also run invariant checks against the live APIs |
| `mix test --only restatapi` | Compare with the R package (needs Docker, see `test/restatapi/README.md`) |
| `mix format` | Format the code |
| `mix credo --strict` | Lint |
| `mix sobelow` | Security checks (config in `.sobelow-conf`) |
| `mix dialyzer` | Type checks (PLT in `priv/plts/`) |
| `mix docs` | Build the docs; must produce no warnings |
| `mix coveralls` | Coverage |

## Layout

| Path | Contents |
|---|---|
| `lib/eurostatx/client.ex` | HTTP via Req: base URLs per agency, URL building, gunzip, error normalization, asynchronous responses, telemetry |
| `lib/eurostatx/utils.ex` | Private. Option schemas (NimbleOptions), validators, agency and SDMX version resolution |
| `lib/eurostatx/{statistics,data}.ex` | The data APIs (Statistics; SDMX 3.0 and 2.1 data queries) |
| `lib/eurostatx/{datasets,codelists,structure}.ex` | SDMX structure queries |
| `lib/eurostatx/{catalogue,async,files}.ex` | Catalogue, asynchronous and files APIs |
| `lib/eurostatx/catalogue/toc_handler.ex` | Saxy handler for the 23 MB XML table of contents |
| `lib/eurostatx/{xml,sdmx}.ex` | Private. Saxy helpers and SDMX-ML structure parsers (2.1 and 3.0) |
| `lib/eurostatx/{json_stat,tsv,period,data_frame}.ex` | Formats: JSON-stat, Eurostat TSV, time periods, Explorer |
| `test/support/eurostat_case.ex` | `Eurostatx.Case`: `stub_eurostat/1`, `assert_eurostat_request/1`, `fixture/1`, `fixture!/1` |
| `test/support/fixtures/` | Real API responses, trimmed. The name includes the extension |
| `test/integration_test.exs` | Live API tests (`:integration` tag) |
| `test/restatapi/` | Cross-check with restatapi: `Dockerfile`, `queries.R`, `cross_check_test.exs` |
| `livebooks/` | Example notebooks, also published as extras in the docs |

## Conventions

- **One module per API or entity, one function per endpoint.** Add the function to the endpoint
  list in its moduledoc, with a link to the Eurostat guide, and to the coverage table of the README.
- **Options use idiomatic English names, never raw Eurostat parameter names,** and are validated
  with NimbleOptions (`Utils.schema/1`, documented with `#{NimbleOptions.docs(@schema)}`):

  | Option | Statistics | SDMX 3.0 | SDMX 2.1 |
  |---|---|---|---|
  | `filters` | `dim=value` (repeated) | `c[dim]=v1,v2` | key built from the structure |
  | `key` | | path key, `*` wildcards | path key, `+` and empty wildcards |
  | `start_period`/`end_period` | `sinceTimePeriod`/`untilTimePeriod` | `c[TIME_PERIOD]=ge:…+le:…` | `startPeriod`/`endPeriod` |
  | `time` | `time` (repeated) | `c[TIME_PERIOD]=a,b` | single period as a range |
  | `last_periods` | `lastTimePeriod` | | |
  | `first_n`/`last_n` | | `firstNObservations`/`lastNObservations` | same |
  | `detail` | | `attributes` + `measures` | `detail` |
  | `language` | `lang=EN` | `lang=en` (SDMX-CSV labels only) | `lang=en` (structures) |
  | `agency` | base URL | base URL + agency ID | base URL + agency ID |

  Validate incompatible combinations client-side (`:option_error`) instead of letting the API fail.
- **Return values:**
  - Every function returns `{:ok, result} | {:error, %Eurostatx.Error{}}`. Non-bang functions never
    raise.
  - JSON responses are returned untouched, with Eurostat's keys. Other formats are binaries, except
    XML metadata with a dedicated function, parsed into maps with **string** keys (snake_case).
  - Data frame functions return `{:ok, df}` and have a bang variant (`Utils.bang!/1`).
- **Never make concurrent requests.** Eurostat asks for one request at a time and pushes clients
  that parallelize into asynchronous processing.
- **Public functions have `@spec`s and docs with examples.** Example outputs must be real: run the
  call against the live API before writing them.
- **Docs, README, CHANGELOG and livebooks:** update them together whenever the public API changes.

## Eurostat API pitfalls

- **Gzip without `Content-Encoding`.** With `Accept-Encoding: gzip` (Req sends it) the SDMX APIs
  return a gzip *file* without a `Content-Encoding` header, so Req does not decompress it.
  `Client` checks the magic bytes (`1F 8B`). File downloads (`decode: :binary`) are left untouched.
- **Errors come in three formats:**
  - SDMX: a bare SOAP fault, `<S:Fault><faultcode>150</faultcode><faultstring>…`, with XML
    entities (`&apos;`). Codes: `100` not found/no results, `140` syntax, `150` semantic, `413` too big.
  - Statistics API, and SDMX with `format=json`: `{"error": [{"status", "id", "label"}]}`. It is a
    **list**; the guide shows an object.
  - Files API: an HTML page (`File x does not exist or is not readable on the server`).
- **Asynchronous responses:**
  - SDMX: an HTTP 200 SOAP envelope `…<ns0:syncResponse>…<queued><id>KEY</id>`, whatever format was
    requested. The status endpoint answers an `asyncResponse` envelope, which **contains the string
    `syncResponse`**: match `:syncResponse`. Async data comes back as `application/octet-stream`
    in the original format. `DATA_NOT_YET_AVAILABLE` is a 400 fault; unknown keys give a 400
    `UNKNOWN_REQUEST` fault on status and a 500 `SERVER` fault on data.
  - Statistics API: an **HTTP 413** with `{"error": [{"status": 413, "label": "ASYNCHRONOUS_RESPONSE…"}]}`,
    not the 200 `{"warning": …}` of the guide (both are handled). There is no key: repeat the request.
  - Above 5,000,000 cells: `EXTRACTION_TOO_BIG` (413), type `:too_big`. `lastNObservations` alone
    can trigger it: combine it with a time range.
- **Dimension filters only accept equality.** `c[geo]=ne:DE`, `co:`, `sw:`... and even `lt/le/gt/ge`
  are rejected (`INVALID_OPERATOR_FOR_DIMENSION_FILTERING`) although the guide lists them. Range
  operators only work on `TIME_PERIOD`.
- **SDMX 3.0 keys take one value per dimension** (`DE+FR` and `DE,FR` are `INVALID_URL_VALUE`): use
  `c[...]` filters. SDMX 2.1 keys use `+` and empty positions as wildcards.
- **SDMX 3.0 cannot list dataflows:** `structure/dataflow/ESTAT/*` returns an empty list, and with a
  version `ERR_ALL_CATALOG_VERSION`. Use SDMX 2.1: `dataflow/ESTAT/all?format=JSON` (with
  annotations). `detail=allcompletestubs` is rejected for the full catalogue.
- **SDMX 3.0 TSV code lists** reject `lang` and have one label column per language. SDMX 2.1 TSV
  takes `lang`.
- **Unknown codes:** the SDMX APIs validate them (400, fault `150`); the Statistics API returns a
  200 with an empty `"value"`.
- **SDMX 2.1 vs 3.0 structures:** 3.0 references artefacts with URNs in element text, 2.1 with `Ref`
  elements; observation attributes are attached to `Observation` (3.0) or `PrimaryMeasure` (2.1).
  `SDMX` normalizes both so that `Datasets.structure/2` returns the same map; keep it that way.
- **JSON-stat:** `"value"` and `"status"` are sparse objects keyed by flat index (not sorted), a
  status can exist without a value, and category indexes are objects or arrays (code lists). The
  time dimension is `time` for Eurostat and `TIME_PERIOD` for REDISSTAT: `JSONStat` always calls it
  `"time"`.
- **REDISSTAT agencies** (`:ecfin`, `:empl`, `:grow`, `:taxud`) serve SDMX 2.1, the Statistics API and
  DCAT only (no TOC, RSS or metabase). Their dimension ids are uppercase, and dataset ids contain `$`
  (`LMP_EXPME$HR`), which must be sent **literally**: `%24` returns a 404.
- **Comext** (`DS-` datasets) has its own base URL (selected automatically) and rejects unfiltered
  extractions.
- **Table of contents:** datasets appear in several folders. The TXT version labels the "Cross
  cutting topics" root with the code `data` (a duplicate) and nests "EU policies" in it; the XML
  version has three roots (`data`, `tb_eu`, `cc`). Some titles end with a non-breaking space.
- **Metabase:** no `freq` dimension; time periods in descending order; 1.3 million lines.
- **Files API:** `/files?…` redirects to `/files/?…` (use `["files", ""]`); the root listing does not
  include `comext`, contrary to the guide.
- **Discontinued datasets.** When a classification changes Eurostat creates new datasets and stops
  updating the old ones, which keep answering. E.g. `prc_hicp_manr` ("(1997-2025)", COICOP 1999) was
  replaced by `prc_hicp_minr` (ECOICOP ver.2, dimension `coicop18`, total `TOTAL`). Before using a
  dataset in docs, tests or livebooks, check its `"latest_period"`.
  - Current datasets: `nama_10_gdp`, `namq_10_gdp`, `prc_hicp_minr`, `tps00001`, `une_rt_m`.
  - Asynchronous Comext example: `DS-045409` with keys like `A.FI.CA..2.SUPPLEMENTARY_QUANTITY`.
- **SDMX-CSV and TSV use CRLF line endings.**

## Testing

- **Unit tests never hit the network.** `config/test.exs` routes Req through `Req.Test` and sets
  `async_interval: 0`. Use `Eurostatx.Case`, and assert both the result and the exact request
  (`assert_eurostat_request/1` takes the path relative to the base URL and returns the params).
  Route maps accept lists of responses to simulate polling.
- **Fixtures:**
  - Capture them from the live API (e.g. with `curl`), trim them to the minimum (whole elements
    for XML, whole items for JSON, whole lines for text), and save them as
    `test/support/fixtures/<api>_<what>.<ext>`.
  - Never hand-write fixtures.
- **Integration tests** check invariants (shapes, types, errors, agreement between APIs and
  formats), not values, because the data changes with every release.
- **restatapi cross-check:** when you change anything that affects data frames, structures, code
  lists or the TOC, add or adjust the query in `queries.R` and its comparison in
  `cross_check_test.exs`. restatapi's output is the ground truth; do not hand-code expected values.
  Set `RESTATAPI_OUTPUT` to reuse a previous R run.
- **Livebooks** load Eurostatx from Hex (`{:eurostatx, "~> 0.1"}`). To try local changes, switch
  temporarily to `{:eurostatx, path: Path.join(__DIR__, "..")}` (do not commit it). After changing the
  public API or an example, run every cell against the live API.

## Before finishing a change

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix sobelow
mix test
mix dialyzer
mix docs
```

If you touched `Client`, `DataFrame`, `JSONStat`, `TSV`, `SDMX` or option translation, also run
`mix test --include integration --include restatapi`.

## Git

- Commit only when asked.
- Never open issues or pull requests on your own: a human must create and supervise them (see the
  "Contributing" section of the README).
- Do not add `Co-Authored-By` trailers or any other AI attribution to commit messages.
