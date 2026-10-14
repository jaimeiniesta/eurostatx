<p align="center">
  <img src="assets/logo.svg" alt="Eurostatx" width="340">
</p>

<p align="center">
  <a href="https://github.com/jaimeiniesta/eurostatx/actions/workflows/ci.yml"><img src="https://github.com/jaimeiniesta/eurostatx/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://hex.pm/packages/eurostatx"><img src="https://img.shields.io/hexpm/v/eurostatx.svg" alt="Hex version"></a>
  <a href="https://hexdocs.pm/eurostatx"><img src="https://img.shields.io/badge/hex-docs-4e2a8e.svg" alt="Documentation"></a>
  <a href="https://jaimeiniesta.com/en/eurostatx"><img src="https://img.shields.io/badge/demo-live-4e2a8e.svg" alt="Demo"></a>
  <a href="https://github.com/jaimeiniesta/eurostatx/blob/master/LICENSE"><img src="https://img.shields.io/hexpm/l/eurostatx.svg" alt="License"></a>
</p>

An Elixir client for the [Eurostat APIs](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access),
the open data services of the statistical office of the European Union, powered by
[Req](https://hexdocs.pm/req) and integrated with [Explorer](https://hexdocs.pm/explorer).

> **Eurostatx is not an official Eurostat library.** It is an independent open source project, not
> developed, endorsed or supported by Eurostat. The client published by Eurostat in its GitHub
> organization is [restatapi](https://github.com/eurostat/restatapi), for R.

The Eurostat APIs give access to every dataset of the
[Eurostat database](https://ec.europa.eu/eurostat/data/database): national accounts (GDP), prices
(HICP), population, labour market, international trade (Comext), industry (Prodcom), regional
statistics and much more. They are free and do **not** require an API key.

Eurostatx covers every API described in the
[Eurostat API guides](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access):
Statistics, SDMX 3.0 and 2.1 (data and structure queries), Catalogue, asynchronous and files APIs,
for Eurostat, Comext/Prodcom and the other Directorates-General of the European Commission
(REDISSTAT). It has been cross-checked against [restatapi](https://github.com/eurostat/restatapi).

**[See the demo](https://jaimeiniesta.com/en/eurostatx):** the countries of the European Union side
by side (prices, jobs, economy, energy, population), each chart with the Eurostatx call that fetched
its data.

## Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Finding Data](#finding-data)
- [Explorer Integration](#explorer-integration)
- [API Coverage](#api-coverage)
- [Big Extractions and Fair Use](#big-extractions-and-fair-use)
- [Comext, Prodcom and Other Agencies](#comext-prodcom-and-other-agencies)
- [Livebook Notebooks](#livebook-notebooks)
- [Configuration](#configuration)
- [Telemetry](#telemetry)
- [Testing](#testing)
- [Contributing](#contributing)

## Installation

Add `eurostatx` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:eurostatx, "~> 0.1.0"}
  ]
end
```

Or in Livebook:

```elixir
Mix.install([{:eurostatx, "~> 0.1.0"}])
```

## Quick Start

Get the annual inflation rate of the euro area and four countries, one column per country:

```elixir
iex> "prc_hicp_minr"
...> |> Eurostatx.Statistics.data_as_data_frame!(
...>   filters: [geo: ["EA", "DE", "FR", "ES", "IT"], unit: "RCH_A", coicop18: "TOTAL"],
...>   last_periods: 6,
...>   shape: :wide
...> )
...> |> Explorer.DataFrame.print()
+----------------------------------------------------+
|     Explorer DataFrame: [rows: 6, columns: 6]      |
+------------+-------+-------+-------+-------+-------+
|    date    |  EA   |  DE   |  ES   |  FR   |  IT   |
|   <date>   | <f64> | <f64> | <f64> | <f64> | <f64> |
+============+=======+=======+=======+=======+=======+
| 2026-04-01 | 3.0   | 2.9   | 3.5   | 2.5   | 2.8   |
| 2026-05-01 | 3.2   | 2.7   | 3.6   | 2.8   | 3.2   |
| 2026-06-01 | 2.8   | 2.4   | 3.6   | 2.0   | 3.0   |
| …          | …     | …     | …     | …     | …     |
| 2026-08-01 | 3.2   | 2.9   | 4.6   | 2.6   | 3.2   |
| 2026-09-01 | 3.8   | 3.3   | 5.0   | 3.4   | 4.1   |
+------------+-------+-------+-------+-------+-------+
```

Or get the JSON-stat response, untouched:

```elixir
iex> Eurostatx.Statistics.data("prc_hicp_minr",
...>   filters: [geo: "EA", unit: "RCH_A", coicop18: "TOTAL"],
...>   last_periods: 2
...> )
{:ok,
 %{
   "label" => "Harmonised index of consumer prices (HICP) - ECOICOP ver.2 - indices and rates of change, monthly data",
   "id" => ["freq", "unit", "coicop18", "geo", "time"],
   "size" => [1, 1, 1, 1, 2],
   "value" => %{"0" => 3.2, "1" => 3.8},
   "status" => %{"1" => "e"},
   "updated" => "2026-10-02T11:00:00+0200",
   ...
 }}
```

Every endpoint function returns `{:ok, result}` or `{:error, %Eurostatx.Error{}}`. The
`*_as_data_frame` functions return `{:ok, data_frame}` and have bang variants that raise instead,
handy for Livebook pipelines.

## Finding Data

Datasets are identified by their **online data code**, shown next to their title in the Eurostat
website and Data Browser (`prc_hicp_minr`, `nama_10_gdp`, `TPS00001`...). Every dataset has
**dimensions** (`freq`, `unit`, `geo`...) whose codes come from **code lists**.

```elixir
# 1. Search the table of contents
iex> {:ok, results} = Eurostatx.Catalogue.search("consumer prices")
iex> results |> Enum.map(&{&1["code"], &1["title"]}) |> Enum.take(2)
[
  {"ei_cphi_m", "Harmonised index of consumer prices - monthly data"},
  {"prc_hicp_ct", "Harmonised index of consumer prices (HICP) - ECOICOP ver.2 - indices and rates of change at constant tax rates, monthly data"}
]

# 2. Discover the dimensions of a dataset and the codes they use, with their labels
iex> {:ok, dimensions} = Eurostatx.Datasets.values("prc_hicp_minr")
iex> Enum.map(dimensions, &{&1["id"], &1["name"], length(&1["values"])})
[
  {"freq", "Time frequency", 1},
  {"unit", "Unit of measure", 5},
  {"coicop18", "Classification of individual consumption by purpose (COICOP) - 2018", 555},
  {"geo", "Geopolitical entity (reporting)", 46}
]

# 3. Get the data, filtering by dimension code
iex> Eurostatx.Data.get_as_data_frame!("prc_hicp_minr",
...>   filters: [geo: ["DE", "FR"], unit: "RCH_A", coicop18: ["TOTAL", "CP01"]],
...>   start_period: "2025-01"
...> )
```

`Eurostatx.Datasets` also lists every dataset with its last update and time coverage (`list/1`),
gives the data structure of a dataset, with its dimensions in key order (`structure/2`), and the
codes actually used by each dimension, including the time periods (`availability/2`).

> **Discontinued datasets.** When a classification changes, Eurostat publishes new datasets and stops
> updating the old ones, which keep answering with their historical data. For example the HICP
> datasets based on COICOP 1999 (`prc_hicp_manr`, "(1997-2025)") were replaced by the ECOICOP ver.2
> ones (`prc_hicp_minr`). Check the title, `"latest_period"` and `"data_updated_at"` in
> `Eurostatx.Datasets.list/1`.

## Explorer Integration

`Eurostatx.DataFrame` converts the responses into data frames:

- **Long/tidy** (default): one row per observation with one column per dimension (its code), `time`
  (the period, e.g. `"2026-09"`), `date` (the first day of the period), `value` and `flag` (the
  observation status: `"p"` provisional, `"e"` estimated...). With `labels: true`, a `<dimension>_label`
  column follows each dimension, in the requested language:

```elixir
iex> "prc_hicp_minr"
...> |> Eurostatx.Data.get_as_data_frame!(
...>   filters: [geo: ["DE", "FR"], unit: "RCH_A", coicop18: ["TOTAL", "CP01"]],
...>   last_n: 1,
...>   labels: true
...> )
...> |> Explorer.DataFrame.select(["geo_label", "coicop18_label", "time", "value", "flag"])
...> |> Explorer.DataFrame.print()
+----------------------------------------------------------------------------+
|                 Explorer DataFrame: [rows: 4, columns: 5]                  |
+-----------+----------------------------------+----------+-------+----------+
| geo_label |          coicop18_label          |   time   | value |   flag   |
| <string>  |             <string>             | <string> | <f64> | <string> |
+===========+==================================+==========+=======+==========+
| Germany   | Total                            | 2026-09  | 3.3   | e        |
| France    | Total                            | 2026-09  | 3.4   | e        |
| Germany   | Food and non-alcoholic beverages | 2026-08  | 0.2   | nil      |
| France    | Food and non-alcoholic beverages | 2026-08  | 1.1   | nil      |
+-----------+----------------------------------+----------+-------+----------+
```

- **Wide** (`shape: :wide`): a `date` column plus one column per series, named after the codes of the
  dimensions that vary (`"DE"`, `"FR"`...).

JSON-stat (both data APIs), TSV and SDMX-CSV responses can be converted with
`Eurostatx.DataFrame.from_json_stat/2`, `from_tsv/1` and `from_csv/1`, and metadata listings
(datasets, table of contents, inventories...) with `from_records/1`.

## API Coverage

| Module                  | Function                       | Endpoint                                                      |
| ----------------------- | ------------------------------ | ------------------------------------------------------------- |
| `Eurostatx.Statistics`  | `data/2`                       | `statistics/1.0/data/{dataset}` (JSON-stat)                   |
|                         | `data_as_data_frame/2`         | same → `Explorer.DataFrame`                                   |
| `Eurostatx.Data`        | `get/2`                        | `sdmx/3.0/data/dataflow/{agency}/{dataset}/{version}/{key}`, `sdmx/2.1/data/{dataset}/{key}` |
|                         | `get_as_data_frame/2`          | same → `Explorer.DataFrame`                                   |
| `Eurostatx.Datasets`    | `list/1`                       | `sdmx/2.1/dataflow/{agency}/all`                              |
|                         | `get/2`                        | `structure/dataflow/{agency}/{dataset}`                       |
|                         | `structure/2`                  | `dataflow` with `references=children` (data structure)        |
|                         | `availability/2`               | `dataconstraint` (3.0) / `contentconstraint` (2.1)            |
|                         | `values/2`                     | `dataflow` with `references=descendants&detail=referencepartial` |
| `Eurostatx.Codelists`   | `list/1`, `get/2`, `codes/2`   | `codelist/{agency}/{id}/{version}`                            |
| `Eurostatx.Structure`   | `get/3`                        | any artefact: `dataflow`, `datastructure`, `codelist`, `conceptscheme`, `constraint`, `categoryscheme`, `categorisation`, with `detail`, `references` and SDMX-ML, JSON or TSV |
| `Eurostatx.Catalogue`   | `toc/1`, `search/2`            | `catalogue/toc/txt`, `catalogue/toc/xml`                      |
|                         | `toc_schema/1`                 | `catalogue/toc/TableOfContent.xsd`                            |
|                         | `rss/1`                        | `catalogue/rss/{lang}/statistics-update.rss`                  |
|                         | `dcat/2`                       | `catalogue/dcat/{agency}/{FULL,UPDATES}`                      |
|                         | `metabase/1`, `metabase_as_data_frame/1` | `catalogue/metabase.txt.gz`                         |
| `Eurostatx.Async`       | `status/2`, `data/2`, `await/2` | `1.0/async/status/{key}`, `1.0/async/data/{key}`             |
| `Eurostatx.Files`       | `inventory/1`                  | `files/inventory?type={data,codelist}`                        |
|                         | `list/2`, `download/2`         | `files?format=csv&dir=`, `files?file=`                        |

The Eurostat parameters are exposed as idiomatic, validated options:

| Eurostatx option                        | Statistics API                  | SDMX 3.0                      | SDMX 2.1                   |
| --------------------------------------- | ------------------------------- | ----------------------------- | -------------------------- |
| `filters: [geo: ["DE", "FR"]]`          | `geo=DE&geo=FR`                 | `c[geo]=DE,FR`                | key built from the structure |
| `key: "A.CP_MEUR..DE"`                  |                                 | key (`*` wildcards)           | key (`+` for several values) |
| `start_period:` / `end_period:`         | `sinceTimePeriod` / `untilTimePeriod` | `c[TIME_PERIOD]=ge:…+le:…` | `startPeriod` / `endPeriod` |
| `time: [2020, 2022]`                    | `time=2020&time=2022`           | `c[TIME_PERIOD]=2020,2022`    | single period only         |
| `last_periods: 3`                       | `lastTimePeriod`                |                               |                            |
| `first_n:` / `last_n:`                  |                                 | `firstNObservations` / `lastNObservations` | same           |
| `geo_level: :nuts2`                     | `geoLevel`                      |                               |                            |
| `language: :fr`                         | `lang=FR`                       | `lang` (SDMX-CSV labels)      |                            |
| `format: :csv`, `:tsv`, `:xml`...       | (JSON-stat only)                | `format`, `formatVersion`     | `format`                   |
| `detail: :data_only`...                 |                                 | `attributes`, `measures`      | `detail`                   |
| `labels: :name`, `last_update_date: true` |                               | `labels`, `returnLastUpdateDate` |                         |
| `return_data: :all`                     |                                 | `returnData`                  | `returnData`               |
| `agency: :comext`...                    | base URL                        | base URL and agency ID        | base URL and agency ID     |

## Big Extractions and Fair Use

Eurostat estimates the number of cells of every extraction:

- below 500,000 cells (or when the result is cached), the data is returned right away;
- between 500,000 and 5,000,000 cells, the request is **queued** and processed asynchronously;
- above 5,000,000 cells, it fails with an error of type `:too_big`: add filters.

Queued requests are awaited transparently: Eurostatx polls the asynchronous API (SDMX) or repeats the
request (Statistics API) until the data is ready or `:async_timeout` (5 minutes by default) expires.
Set `async_timeout: 0` to get the request key right away and fetch the data later:

```elixir
{:error, %Eurostatx.Error{type: :queued, request_id: id}} =
  Eurostatx.Data.get("DS-045409", key: "A.FI.CA..2.SUPPLEMENTARY_QUANTITY", format: :csv, async_timeout: 0)

{:ok, csv} = Eurostatx.Async.await(id, agency: :comext)
```

Eurostat also queues requests to ensure the fair use of the service, based on the number of
concurrent requests and on the requests and extraction cost of the last day, 7 days and 30 days. It
asks to make **one request at a time**: Eurostatx never makes concurrent requests. Datasets are
updated twice a day, at 11:00 and 23:00 (Brussels time).

## Comext, Prodcom and Other Agencies

Comext and Prodcom datasets (`DS-` codes) are served by a dedicated endpoint, selected automatically.
Full Comext datasets cannot be downloaded: they must be filtered.

The European Commission's Directorates-General for Economic and Financial Affairs (`:ecfin`),
Employment (`:empl`), Internal Market (`:grow`) and Taxation (`:taxud`) publish their data with the
same APIs (REDISSTAT). They serve the Statistics API, SDMX 2.1 (the default for them) and the DCAT
catalogue:

```elixir
{:ok, datasets} = Eurostatx.Datasets.list(agency: :empl)
Eurostatx.Statistics.data_as_data_frame!("LMP_EXPME$HR", agency: :empl, last_periods: 1)
```

## Livebook Notebooks

The `livebooks/` directory contains interactive [Livebook](https://livebook.dev) notebooks with
[VegaLite](https://hexdocs.pm/vega_lite) charts:

| Notebook                                                                      | Description                                                        |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| [`1_getting_started.livemd`](./livebooks/1_getting_started.livemd)            | Statistics API, data frames, wide and long shapes, first charts    |
| [`2_exploring_datasets.livemd`](./livebooks/2_exploring_datasets.livemd)      | Table of contents, dataset structure, code lists, SDMX queries and formats |
| [`3_eu_in_charts.livemd`](./livebooks/3_eu_in_charts.livemd)                  | The charts of the [demo](https://jaimeiniesta.com/en/eurostatx): prices, jobs, economy, energy and population, with a map |

## Configuration

No configuration is needed. Optionally:

```elixir
config :eurostatx,
  language: :en,            # Default language of the labels (:en, :fr or :de)
  timeout: 120_000,         # Receive timeout of each request in milliseconds
  async_timeout: 300_000,   # How long to wait for asynchronous responses
  async_interval: 5_000,    # Interval between asynchronous status checks
  req_options: []           # Extra Req options: retries, proxies, test plugs...
```

## Telemetry

Eurostatx emits `[:eurostatx, :request, :start | :stop | :exception]`
[telemetry](https://hexdocs.pm/telemetry) events for every request. The quickest way to see what is
going on is the built-in logger:

```elixir
Eurostatx.Telemetry.Logger.attach()
```

```
[info] [eurostatx] GET statistics/1.0/data/prc_hicp_minr - 200 in 241ms (params: [{"lang", "EN"}, {"geo", "EA"}])
[info] [eurostatx] GET sdmx/2.1/data/DS-045409/A.SE.NO..2.SUPPLEMENTARY_QUANTITY - queued in 484ms (request f07392ce-...)
[info] [eurostatx] GET 1.0/async/status/f07392ce-0d11-47eb-9922-809615e9013e - 200 in 54ms
```

See `Eurostatx.Telemetry` for the details of each event.

## Testing

```sh
mix test                          # Unit tests, using real responses recorded from the APIs
mix test --include integration    # Also run the tests against the live APIs
mix test --only restatapi         # Cross-check against restatapi, the R package of Eurostat (requires Docker)
```

The `restatapi` suite runs the same queries with [restatapi](https://github.com/eurostat/restatapi)
(in a Docker container, see `test/restatapi`) and with Eurostatx against the live APIs, and compares
data values, flags and periods (Statistics API, SDMX 3.0 and 2.1, TSV), the codes and labels of data
structures and code lists, and the table of contents.

The [CI workflow](https://github.com/jaimeiniesta/eurostatx/actions) checks formatting, Credo and
[Sobelow](https://github.com/nccgroup/sobelow), and runs the unit tests on Elixir 1.18, 1.19 and 1.20.

## Contributing

Contributions are welcome: bug reports, ideas, documentation, examples and pull requests. For bigger
changes, open an issue first so that we can discuss them. Before sending a pull request, run
`mix format`, `mix credo --strict` and `mix test`.

You can use AI tools, as long as a human creates and supervises each issue and pull request and
answers for its content and its review. Coding agents will find instructions in
[AGENTS.md](https://github.com/jaimeiniesta/eurostatx/blob/master/AGENTS.md).

## Acknowledgements

- [Fred](https://github.com/akoutmos/fred), whose interface Eurostatx follows, and
  [Inex](https://github.com/jaimeiniesta/inex), its sibling for the Spanish INE.
- [restatapi](https://github.com/eurostat/restatapi), the R package published by Eurostat, used as
  reference implementation.
- Data © [European Union, Eurostat](https://ec.europa.eu/eurostat), reusable under the
  [Eurostat copyright notice](https://ec.europa.eu/eurostat/help/copyright-notice) (CC BY 4.0).

## License

MIT
