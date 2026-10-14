defmodule Eurostatx do
  @moduledoc """
  Elixir client for the [Eurostat APIs](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access),
  the open data services of the statistical office of the European Union.

  The APIs give access to every dataset of the
  [Eurostat database](https://ec.europa.eu/eurostat/data/database):
  national accounts (GDP), prices (HICP), population, labour market,
  international trade (Comext), industry (Prodcom), regional statistics and
  much more. They are free and do **not** require an API key.

  See the [demo](https://jaimeiniesta.com/en/eurostatx): the countries of the
  European Union side by side, each chart with the Eurostatx call that
  fetched its data.

  ## Run Your First Query

      iex> Eurostatx.Statistics.data_as_data_frame!("nama_10_gdp",
      ...>   filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
      ...>   last_periods: 3,
      ...>   shape: :wide
      ...> )
      #Explorer.DataFrame<
        Polars[3 x 3]
        date date [2023-01-01, 2024-01-01, 2025-01-01]
        DE f64 [4254930.0, 4386940.0, 4529710.0]
        FR f64 [2833826.4, 2935236.2, 2991055.9]
      >

  ## APIs

  Each Eurostat API has its own module:

    - `Eurostatx.Statistics` - the **Statistics API**: data in JSON-stat with
      labels in English, French or German. The simplest way to get data.
    - `Eurostatx.Data` - the **SDMX 3.0 and 2.1 data queries**: data in
      JSON-stat, SDMX-CSV, TSV or SDMX-ML, with keys, filters and observation
      limits.
    - `Eurostatx.Datasets`, `Eurostatx.Codelists` and `Eurostatx.Structure` -
      the **SDMX structure queries**: datasets (dataflows), their structure,
      the codes they use, code lists, concept schemes, the navigation tree...
    - `Eurostatx.Catalogue` - the **Catalogue API**: table of contents and
      search, RSS feed of updates, DCAT-AP catalogue and metabase.
    - `Eurostatx.Async` - the **asynchronous API**, for big extractions. Used
      automatically by the data functions.
    - `Eurostatx.Files` - the **files API**: inventories, reference metadata
      and bulk Comext files.

  ## Concepts

    - **Datasets** are identified by their online data code, shown next to
      their title in the Eurostat website (`nama_10_gdp`, `TPS00001`...). In
      SDMX they are called *dataflows*. Codes are case-insensitive.
    - Every dataset has **dimensions** (`freq`, `unit`, `geo`...) and a time
      dimension (`TIME_PERIOD`, `time` in JSON-stat). Each dimension takes its
      codes from a **code list** (`GEO`, `UNIT`...).
    - A **series** is identified by a **key**: a code for every dimension,
      in the order defined by the data structure (`A.CP_MEUR.B1GQ.DE`).
    - Observations can have **flags**: `p` provisional, `e` estimated, `b`
      break in time series, `c` confidential... (code list `OBS_FLAG`).
    - Comext and Prodcom datasets have `DS-` codes and are served by a
      dedicated endpoint, selected automatically. Other Directorates-General
      of the European Commission (REDISSTAT) publish data with the same APIs;
      use the `:agency` option.

  ## Return values

  Every endpoint function returns `{:ok, result}` or
  `{:error, %Eurostatx.Error{}}`. JSON responses (JSON-stat datasets, code
  lists, dataflows) are returned as decoded, untouched. Other formats
  (SDMX-CSV, TSV, SDMX-ML) are returned as binaries, except the XML metadata
  that has a dedicated function (structures, constraints, table of contents,
  RSS), which is parsed into maps with string keys. The `*_as_data_frame`
  functions return `{:ok, %Explorer.DataFrame{}}` and have bang (`!`)
  variants that raise `Eurostatx.Error` instead.

  ## Fair use

  Eurostat processes big extractions asynchronously, and forces requests to
  be processed asynchronously when a client makes too many or too costly
  requests, or requests in parallel. Make one request at a time: Eurostatx
  never makes concurrent requests. Datasets are updated twice a day, at 11:00
  and 23:00 (Brussels time), so there is no point in polling them more often.

  ## Configuration

  No configuration is required. Optionally:

  ```elixir
  config :eurostatx,
    language: :en,              # Default language of the labels (:en, :fr or :de)
    timeout: 120_000,           # Receive timeout of each request in milliseconds
    async_timeout: 300_000,     # How long to wait for asynchronous responses
    async_interval: 5_000,      # Interval between asynchronous status checks
    req_options: []             # Extra options for Req (retries, proxies, test plugs...)
  ```

  See `Eurostatx.Client` for details.

  ## Telemetry

  Eurostatx emits `[:eurostatx, :request, :start | :stop | :exception]`
  telemetry events for every HTTP request. For quick observability attach the
  built-in logger:

  ```elixir
  Eurostatx.Telemetry.Logger.attach()
  ```

  See `Eurostatx.Telemetry` for the details of each event.
  """

  @typedoc """
  Online data code of a dataset (`"nama_10_gdp"`, `"TPS00001"`,
  `"DS-045409"`...). Case-insensitive.
  """
  @type dataset :: String.t()
end
