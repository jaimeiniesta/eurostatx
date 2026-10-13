defmodule Eurostatx.Statistics do
  @moduledoc """
  Functions for the [Statistics API](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/api-statistics).

  The Statistics API returns the data of a dataset in
  [JSON-stat 2.0](https://json-stat.org/format/), with the labels of every
  dimension in English, French or German. It powers Eurostat's own
  visualisations and is the simplest way to query a dataset: filters are
  given by dimension code, in any order.

      {:ok, json} = Eurostatx.Statistics.data("nama_10_gdp",
        filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
        last_periods: 3
      )

  Dataset codes are the "online data codes" shown next to every dataset in the
  Eurostat website and Data Browser (e.g. `nama_10_gdp`, `TPS00001`). They are
  case-insensitive. Datasets of the Comext and Prodcom databases (`DS-`
  codes) are queried automatically on the Comext endpoint.

  For more control over the query (other formats, observation limits per
  series, the `c[...]` filters of SDMX 3.0...) use `Eurostatx.Data`.

  ## Endpoints

    - `data/2` - [`statistics/1.0/data/{dataset}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-getting-started/api) - The data of a dataset in JSON-stat
    - `data_as_data_frame/2` - The same data as an `Explorer.DataFrame`

  ## Time filters

  Only one kind of time filter can be used in a query, as required by the API:

    - `time: [2020, 2022]` - specific periods (`time=2020&time=2022`)
    - `start_period: 2015` and/or `end_period: 2020` - a range, both ends
      included (`sinceTimePeriod`/`untilTimePeriod`)
    - `last_periods: 3` - the last 3 time periods of the dataset (`lastTimePeriod`)

  ## Geographic levels

  `geo_level:` filters the `geo` dimension by the level of the regions in the
  [NUTS classification](https://ec.europa.eu/eurostat/web/nuts):

    - `:aggregate` - European aggregates (EU27_2020, EA20...)
    - `:country` - countries (`FR`)
    - `:nuts1`, `:nuts2`, `:nuts3` - NUTS regions (`FR4`, `FR41`, `FR413`)
    - `:city` - cities (`DE_DEL1`)

  It cannot be combined with a `geo` filter.
  """

  alias Eurostatx.Client
  alias Eurostatx.Utils
  alias Explorer.DataFrame, as: DF

  @geo_levels [:aggregate, :country, :nuts1, :nuts2, :nuts3, :city]

  @query_fields [
    :language,
    :agency,
    :filters,
    :time,
    :period_range,
    {:last_periods,
     [
       type: :pos_integer,
       doc: "Return only the last `n` time periods of the dataset (`lastTimePeriod`)."
     ]},
    {:geo_level,
     [
       type: {:custom, __MODULE__, :validate_geo_level, []},
       doc:
         "Geographic level(s) of the `geo` dimension (`geoLevel`): `:aggregate`, `:country`, " <>
           "`:nuts1`, `:nuts2`, `:nuts3` or `:city`, or a list of them. See \"Geographic levels\".",
       type_doc: "atom or list of atoms"
     ]},
    :async_timeout
  ]

  @data_schema Utils.schema(@query_fields)
  @data_frame_schema Utils.schema(@query_fields ++ [:data_frame])

  @doc """
  Gets the data of a dataset as a JSON-stat 2.0 dataset.

  The response is returned as decoded by `JSON`, untouched: `"value"` holds
  the observations indexed by position, `"status"` their flags,
  `"dimension"` the codes and labels of each dimension and `"extension"`
  Eurostat's metadata (annotations, flag labels...). Use
  `data_as_data_frame/2` or `Eurostatx.JSONStat.to_records/2` to get one row
  per observation.

  A filter on a value that does not exist in the dataset returns an empty
  `"value"` map, not an error.

  ## Options

  #{NimbleOptions.docs(@data_schema)}

  ## Examples

      iex> Eurostatx.Statistics.data("nama_10_gdp",
      ...>   filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
      ...>   last_periods: 3
      ...> )
      {:ok,
       %{
         "class" => "dataset",
         "label" => "Gross domestic product (GDP) and main components (output, expenditure and income) - annual data",
         "id" => ["freq", "unit", "na_item", "geo", "time"],
         "size" => [1, 1, 1, 2, 3],
         "value" => %{"0" => 4254930.0, "1" => 4386940.0, "2" => 4529710.0, "3" => 2833826.4, "4" => 2935236.2, "5" => 2991055.9},
         "status" => %{"0" => "p", "1" => "p", "2" => "p", "4" => "p", "5" => "p"},
         ...
       }}

      # French labels, a range of years and every country
      iex> {:ok, %{"dimension" => %{"geo" => %{"label" => "Entité géopolitique (déclarante)"}}}} =
      ...>   Eurostatx.Statistics.data("nama_10_gdp",
      ...>     filters: [unit: "CP_MEUR", na_item: "B1GQ"],
      ...>     geo_level: :country,
      ...>     start_period: 2020,
      ...>     end_period: 2022,
      ...>     language: :fr
      ...>   )

      iex> {:error, %Eurostatx.Error{type: :not_found}} = Eurostatx.Statistics.data("nope")
  """
  @spec data(String.t(), keyword()) :: Client.response()
  def data(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @data_schema) do
      request(dataset, opts)
    end
  end

  @doc """
  Same as `data/2` except that it returns an `Explorer.DataFrame`, with one
  row per observation by default. See `Eurostatx.DataFrame` for the columns.

  ## Options

  #{NimbleOptions.docs(@data_frame_schema)}

  ## Examples

      iex> Eurostatx.Statistics.data_as_data_frame!("nama_10_gdp",
      ...>   filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
      ...>   last_periods: 3,
      ...>   labels: true
      ...> )
      #Explorer.DataFrame<
        Polars[6 x 13]
        freq string ["A", "A", "A", "A", "A", ...]
        freq_label string ["Annual", "Annual", "Annual", "Annual", "Annual", ...]
        unit string ["CP_MEUR", "CP_MEUR", "CP_MEUR", "CP_MEUR", "CP_MEUR", ...]
        unit_label string ["Current prices, million euro",
         "Current prices, million euro", "Current prices, million euro",
         "Current prices, million euro", "Current prices, million euro", ...]
        na_item string ["B1GQ", "B1GQ", "B1GQ", "B1GQ", "B1GQ", ...]
        na_item_label string ["Gross domestic product at market prices",
         "Gross domestic product at market prices",
         "Gross domestic product at market prices",
         "Gross domestic product at market prices",
         "Gross domestic product at market prices", ...]
        geo string ["DE", "DE", "DE", "FR", "FR", ...]
        geo_label string ["Germany", "Germany", "Germany", "France", "France", ...]
        time string ["2023", "2024", "2025", "2023", "2024", ...]
        date date [2023-01-01, 2024-01-01, 2025-01-01, 2023-01-01, 2024-01-01, ...]
        value f64 [4254930.0, 4386940.0, 4529710.0, 2833826.4, 2935236.2, ...]
        flag string ["p", "p", "p", nil, "p", ...]
        flag_label string ["provisional", "provisional", "provisional", nil,
         "provisional", ...]
      >

      # One column per country
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
  """
  @spec data_as_data_frame(String.t(), keyword()) :: {:ok, DF.t()} | {:error, Eurostatx.Error.t()}
  def data_as_data_frame(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @data_frame_schema),
         {:ok, json} <- request(dataset, opts) do
      {:ok, Eurostatx.DataFrame.build_from_json_stat(json, opts)}
    end
  end

  @doc """
  Same as `data_as_data_frame/2` but returns the data frame directly and
  raises an `Eurostatx.Error` on failure.
  """
  @spec data_as_data_frame!(String.t(), keyword()) :: DF.t()
  def data_as_data_frame!(dataset, opts \\ []) do
    dataset |> data_as_data_frame(opts) |> Utils.bang!()
  end

  defp request(dataset, opts) do
    with :ok <- validate_time_filters(opts),
         :ok <- validate_geo(opts) do
      agency = Utils.agency(dataset, opts)

      params =
        [{"lang", Utils.language(opts, :upper)}] ++
          for(
            {dimension, values} <- opts[:filters] || [],
            value <- values,
            do: {dimension, value}
          ) ++
          Enum.map(opts[:time] || [], &{"time", &1}) ++
          [
            {"sinceTimePeriod", opts[:start_period]},
            {"untilTimePeriod", opts[:end_period]},
            {"lastTimePeriod", opts[:last_periods]}
          ] ++
          Enum.map(opts[:geo_level] || [], &{"geoLevel", &1})

      Client.get(["statistics", "1.0", "data", dataset], params, Utils.client_opts(opts, agency))
    end
  end

  # The API accepts a single time filter, except since + until together
  defp validate_time_filters(opts) do
    used =
      [
        opts[:time] && :time,
        (opts[:start_period] || opts[:end_period]) && :start_period,
        opts[:last_periods] && :last_periods,
        (Utils.filter_values(opts[:filters], "time") ||
           Utils.filter_values(opts[:filters], "time_period")) && :filters
      ]
      |> Enum.reject(&is_nil/1)

    if length(used) > 1,
      do:
        Utils.option_error(
          "only one kind of time filter can be used: :time, :start_period/:end_period, " <>
            ":last_periods or a time filter, got: #{inspect(used)}"
        ),
      else: :ok
  end

  defp validate_geo(opts) do
    if opts[:geo_level] && Utils.filter_values(opts[:filters], "geo"),
      do: Utils.option_error(":geo_level and a geo filter cannot be used at the same time"),
      else: :ok
  end

  @doc false
  def validate_geo_level(level) when level in @geo_levels, do: {:ok, [to_string(level)]}

  def validate_geo_level(levels) when is_list(levels) and levels != [] do
    if Enum.all?(levels, &(&1 in @geo_levels)),
      do: {:ok, levels |> Enum.uniq() |> Enum.map(&to_string/1)},
      else: {:error, "expected geo levels in #{inspect(@geo_levels)}, got: #{inspect(levels)}"}
  end

  def validate_geo_level(other),
    do: {:error, "expected a geo level in #{inspect(@geo_levels)}, got: #{inspect(other)}"}
end
