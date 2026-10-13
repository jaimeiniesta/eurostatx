defmodule Eurostatx.Data do
  @moduledoc """
  Functions for the SDMX data queries of the
  [SDMX 3.0](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx3-0/data-query)
  and [SDMX 2.1](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/data-query)
  APIs.

  Data queries retrieve a whole dataset or any slice of it, in JSON-stat,
  SDMX-CSV, Eurostat's TSV or SDMX-ML. SDMX 3.0 is used by default; pass
  `sdmx_version: "2.1"` for the SDMX 2.1 API (the only one served by the
  REDISSTAT agencies).

      {:ok, json} = Eurostatx.Data.get("nama_10_gdp",
        filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
        start_period: 2020
      )

  ## Selecting data

  There are two ways to select the series of a dataset, which can be combined:

    - **Filters** (`filters: [geo: ["DE", "FR"]]`), sent as the SDMX 3.0
      component filters `c[geo]=DE,FR`. They can be given in any order and
      accept several values per dimension. With SDMX 2.1, which has no
      component filters, Eurostatx reads the order of the dimensions from the
      data structure (one extra request) and turns the filters into a key.
    - **Key** (`key: "A.CP_MEUR.B1GQ.DE"`), the codes of the dimensions in the
      order of the data structure, separated by dots (see
      `Eurostatx.Datasets.structure/2`). Missing trailing dimensions are
      wildcards. It can also be given as a list:
      `key: ["A", "CP_MEUR", :all, "DE"]`. SDMX 3.0 keys accept one value per
      dimension (`*` for all); SDMX 2.1 keys accept several values
      (`["A", "CP_MEUR", :all, ["DE", "FR"]]` is sent as `A.CP_MEUR..DE+FR`).

  Eurostat validates the codes against the dataset: an unknown code returns
  an `Eurostatx.Error` of type `:invalid_query`. Only equality filters are
  supported on dimensions; ranges are only available for time.

  ## Time

    - `start_period:` / `end_period:` - a range, both ends included
    - `time:` - specific periods, e.g. `[2020, 2022]` (SDMX 3.0 only)
    - `first_n:` / `last_n:` - the first or last `n` observations of each series

  `last_n` alone forces Eurostat to scan the whole dataset and can be rejected
  as too big; combine it with `start_period` to reduce the cost of the query.

  ## Formats

  | `:format`      | SDMX 3.0                         | SDMX 2.1                      | Returned as     |
  | -------------- | -------------------------------- | ----------------------------- | --------------- |
  | `:json`        | JSON-stat 2.0 (default)          | JSON-stat 2.0                 | decoded map     |
  | `:csv`         | SDMX-CSV 2.0                     | SDMX-CSV 1.0                  | binary          |
  | `:csv_1`       | SDMX-CSV 1.0                     | SDMX-CSV 1.0                  | binary          |
  | `:tsv`         | Eurostat TSV                     | Eurostat TSV                  | binary          |
  | `:xml`         | SDMX-ML 3.0 structure specific   | SDMX-ML 2.1 structure specific | binary         |
  | `:xml_2_1`     | SDMX-ML 2.1 structure specific   | SDMX-ML 2.1 structure specific | binary         |
  | `:xml_generic` | SDMX-ML 2.1 generic              | SDMX-ML 2.1 generic           | binary          |

  `Eurostatx.DataFrame` converts JSON-stat, TSV and SDMX-CSV into data frames.

  ## Big extractions

  Extractions above 500,000 cells are processed asynchronously by Eurostat;
  they are awaited automatically (see `Eurostatx.Async` and the
  `:async_timeout` option). Extractions above 5,000,000 cells are rejected
  with an error of type `:too_big`. Comext datasets (`DS-` codes) cannot be
  downloaded without filters. Eurostat asks to make one request at a time.

  ## Endpoints

    - `get/2` - [`sdmx/3.0/data/dataflow/{agency}/{dataset}/{version}/{key}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx3-0/data-query)
      or [`sdmx/2.1/data/{dataset}/{key}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/data-query) - The data of a dataset
    - `get_as_data_frame/2` - The same data as an `Explorer.DataFrame`
  """

  alias Eurostatx.Client
  alias Eurostatx.Datasets
  alias Eurostatx.Utils
  alias Explorer.DataFrame, as: DF

  @formats [:json, :csv, :csv_1, :tsv, :xml, :xml_2_1, :xml_generic]
  @details [:full, :data_only, :series_keys_only, :no_data]

  @selection_fields [
    :language,
    :agency,
    :sdmx_version,
    :filters,
    {:key,
     [
       type: {:custom, __MODULE__, :validate_key, []},
       doc:
         "Series key, as a string (`\"A.CP_MEUR..DE\"`) or a list with one element per " <>
           "dimension (`[\"A\", \"CP_MEUR\", :all, \"DE\"]`). See \"Selecting data\".",
       type_doc: "`String.t() | list()`"
     ]},
    :time,
    :period_range,
    {:first_n,
     [
       type: :pos_integer,
       doc: "Maximum number of observations per series, from the oldest (`firstNObservations`)."
     ]},
    {:last_n,
     [
       type: :pos_integer,
       doc:
         "Maximum number of observations per series, counting back from the most recent " <>
           "(`lastNObservations`)."
     ]},
    {:dataflow_version,
     [
       type: :string,
       default: "1.0",
       doc: "Version of the dataflow (SDMX 3.0). Eurostat datasets are always `\"1.0\"`."
     ]},
    :async_timeout
  ]

  @get_schema Utils.schema(
                @selection_fields ++
                  [
                    {:format,
                     [
                       type: {:in, @formats},
                       default: :json,
                       doc: "Format of the response. See \"Formats\".",
                       type_doc: "`#{Enum.map_join(@formats, " | ", &inspect/1)}`"
                     ]},
                    {:detail,
                     [
                       type: {:in, @details},
                       doc:
                         "Amount of information: `:full` (default), `:data_only` (no attributes " <>
                           "such as flags), `:series_keys_only` (only the keys of the series " <>
                           "that match) or `:no_data` (series attributes, no observations).",
                       type_doc: "`:full | :data_only | :series_keys_only | :no_data`"
                     ]},
                    {:labels,
                     [
                       type: {:in, [:id, :name, :both]},
                       doc:
                         "SDMX-CSV 2.0 only (`format: :csv`, SDMX 3.0). `:id` (default) codes, " <>
                           "`:name` adds a column with the label after each code column, `:both` " <>
                           "writes `\"code: label\"` in each cell. Labels follow `:language`.",
                       type_doc: "`:id | :name | :both`"
                     ]},
                    {:last_update_date,
                     [
                       type: :boolean,
                       doc:
                         "SDMX-CSV 2.0 only. Adds a `LAST UPDATE` column with the date of the " <>
                           "last update of the dataset (`returnLastUpdateDate`)."
                     ]},
                    {:return_data,
                     [
                       type: {:in, [:all, :data_only]},
                       doc:
                         "TSV and SDMX-CSV only. `:data_only` (default) returns only the series " <>
                           "with data, `:all` also the series without data (`returnData`).",
                       type_doc: "`:all | :data_only`"
                     ]},
                    {:dimension_at_observation,
                     [
                       type: :string,
                       doc:
                         "SDMX 2.1 only. How SDMX-ML data is packaged: `\"TIME_PERIOD\"` " <>
                           "(time series, default), the id of another dimension (cross-sectional) " <>
                           "or `\"AllDimensions\"` (flat)."
                     ]}
                  ]
              )

  @data_frame_schema Utils.schema(@selection_fields ++ [:data_frame])

  @doc """
  Gets the data of a dataset.

  Returns the decoded JSON-stat dataset with `format: :json` (the default) and
  the body as a binary for the other formats.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> Eurostatx.Data.get("nama_10_gdp",
      ...>   filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
      ...>   start_period: 2022
      ...> )
      {:ok,
       %{
         "class" => "dataset",
         "id" => ["freq", "unit", "na_item", "geo", "time"],
         "size" => [1, 1, 1, 2, 4],
         "value" => %{"0" => 4010630.0, "1" => 4254930.0, ...},
         ...
       }}

      # SDMX-CSV with a key and the last 2 observations of the series
      iex> Eurostatx.Data.get("nama_10_gdp", key: "A.CP_MEUR.B1GQ.DE", last_n: 2, format: :csv)
      {:ok,
       "STRUCTURE,STRUCTURE_ID,freq,unit,na_item,geo,TIME_PERIOD,OBS_VALUE,OBS_FLAG,CONF_STATUS\\r\\n" <>
         "dataflow,ESTAT:NAMA_10_GDP(1.0),A,CP_MEUR,B1GQ,DE,2024,4386940.0,p,\\r\\n" <>
         "dataflow,ESTAT:NAMA_10_GDP(1.0),A,CP_MEUR,B1GQ,DE,2025,4529710.0,p,\\r\\n"}

      # The SDMX 2.1 API: several values per dimension in the key
      iex> {:ok, tsv} =
      ...>   Eurostatx.Data.get("nama_10_gdp",
      ...>     key: ["A", "CP_MEUR", "B1GQ", ["DE", "FR"]],
      ...>     start_period: 2024,
      ...>     format: :tsv,
      ...>     sdmx_version: "2.1"
      ...>   )

      iex> {:error, %Eurostatx.Error{type: :invalid_query, code: "150"}} =
      ...>   Eurostatx.Data.get("nama_10_gdp", filters: [geo: "XX"])
  """
  @spec get(String.t(), keyword()) :: Client.response()
  def get(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema) do
      request(dataset, opts)
    end
  end

  @doc """
  Same as `get/2` except that it returns an `Explorer.DataFrame`, with one row
  per observation by default (the data is requested in JSON-stat). See
  `Eurostatx.DataFrame` for the columns.

  ## Options

  #{NimbleOptions.docs(@data_frame_schema)}

  ## Examples

      iex> Eurostatx.Data.get_as_data_frame!("nama_10_gdp",
      ...>   filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
      ...>   start_period: 2022
      ...> )
      #Explorer.DataFrame<
        Polars[8 x 8]
        freq string ["A", "A", "A", "A", "A", ...]
        unit string ["CP_MEUR", "CP_MEUR", "CP_MEUR", "CP_MEUR", "CP_MEUR", ...]
        na_item string ["B1GQ", "B1GQ", "B1GQ", "B1GQ", "B1GQ", ...]
        geo string ["DE", "DE", "DE", "DE", "FR", ...]
        time string ["2022", "2023", "2024", "2025", "2022", ...]
        date date [2022-01-01, 2023-01-01, 2024-01-01, 2025-01-01, 2022-01-01, ...]
        value f64 [4010630.0, 4254930.0, 4386940.0, 4529710.0, 2653997.2, ...]
        flag string [nil, "p", "p", "p", nil, ...]
      >
  """
  @spec get_as_data_frame(String.t(), keyword()) :: {:ok, DF.t()} | {:error, Eurostatx.Error.t()}
  def get_as_data_frame(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @data_frame_schema),
         request_opts =
           opts |> Keyword.drop([:labels, :shape, :rename]) |> Keyword.put(:format, :json),
         {:ok, json} <- request(dataset, request_opts) do
      {:ok, Eurostatx.DataFrame.build_from_json_stat(json, opts)}
    end
  end

  @doc """
  Same as `get_as_data_frame/2` but returns the data frame directly and raises
  an `Eurostatx.Error` on failure.
  """
  @spec get_as_data_frame!(String.t(), keyword()) :: DF.t()
  def get_as_data_frame!(dataset, opts \\ []) do
    dataset |> get_as_data_frame(opts) |> Utils.bang!()
  end

  defp request(dataset, opts) do
    agency = Utils.agency(dataset, opts)

    with {:ok, version} <- Utils.sdmx_version(agency, opts),
         :ok <- validate_format_options(opts, version),
         {:ok, filters, time} <- split_time(opts),
         {:ok, segments, params} <- build(version, dataset, agency, filters, time, opts) do
      Client.get(segments, params, Utils.client_opts(opts, agency))
    end
  end

  ## SDMX 3.0

  defp build("3.0", dataset, agency, filters, time, opts) do
    with {:ok, key} <- key_3_0(opts[:key]) do
      segments =
        [
          "sdmx",
          "3.0",
          "data",
          "dataflow",
          Client.agency_id(agency),
          dataset,
          opts[:dataflow_version]
        ] ++
          List.wrap(key)

      params =
        Enum.map(filters, fn {dimension, values} ->
          {"c[#{dimension}]", Enum.join(values, ",")}
        end) ++
          [{"c[TIME_PERIOD]", time_3_0(time)}] ++
          observation_params(opts) ++
          detail_3_0(opts[:detail]) ++
          format_3_0(opts[:format]) ++
          [
            {"labels", opts[:labels]},
            {"lang", csv_language(opts)},
            {"returnLastUpdateDate", opts[:last_update_date]},
            {"returnData", return_data(opts[:return_data])}
          ]

      {:ok, segments, params}
    end
  end

  ## SDMX 2.1

  defp build("2.1", dataset, agency, filters, time, opts) do
    with {:ok, start_period, end_period} <- time_2_1(time),
         {:ok, key} <- key_2_1(dataset, agency, filters, opts) do
      segments = ["sdmx", "2.1", "data", dataset] ++ List.wrap(key)

      params =
        [
          {"format", format_2_1(opts[:format])},
          {"startPeriod", start_period},
          {"endPeriod", end_period}
        ] ++
          observation_params(opts) ++
          [
            {"detail", detail_2_1(opts[:detail])},
            {"returnData", return_data(opts[:return_data])},
            {"dimensionAtObservation", opts[:dimension_at_observation]}
          ]

      {:ok, segments, params}
    end
  end

  # SDMX 2.1 only has a range, so a single period is sent as a range
  defp time_2_1(nil), do: {:ok, nil, nil}
  defp time_2_1({:range, start_period, end_period}), do: {:ok, start_period, end_period}
  defp time_2_1({:periods, [period]}), do: {:ok, period, period}

  defp time_2_1({:periods, _periods}) do
    Utils.option_error("SDMX 2.1 accepts a single time period, use :start_period and :end_period")
  end

  defp key_2_1(_dataset, _agency, [], opts), do: {:ok, encode_key_2_1(opts[:key])}

  # SDMX 2.1 has no component filters: build the key from the order of the dimensions
  defp key_2_1(dataset, agency, filters, opts) do
    with :ok <-
           if(opts[:key],
             do: Utils.option_error("use either :key or :filters with SDMX 2.1, not both"),
             else: :ok
           ),
         {:ok, structure} <-
           Datasets.structure(
             dataset,
             Keyword.merge(Keyword.take(opts, [:language]), agency: agency, sdmx_version: "2.1")
           ) do
      dimensions = Enum.map(structure["dimensions"], & &1["id"])

      unknown =
        for {dimension, _values} <- filters,
            not dimension_in?(dimension, dimensions),
            do: dimension

      if unknown == [] do
        {:ok,
         Enum.map_join(dimensions, ".", &Enum.join(Utils.filter_values(filters, &1) || [], "+"))}
      else
        Utils.option_error(
          "unknown dimensions #{inspect(unknown)} for #{dataset}, expected: #{inspect(dimensions)}"
        )
      end
    end
  end

  defp dimension_in?(dimension, dimensions) do
    Enum.any?(dimensions, &(String.downcase(&1) == String.downcase(dimension)))
  end

  ## Shared helpers

  # Splits the filters on the time dimension from the rest and merges them with
  # the :time, :start_period and :end_period options into a single selection:
  # nil, {:periods, periods} or {:range, start_period, end_period}.
  defp split_time(opts) do
    {time_filters, filters} =
      Enum.split_with(opts[:filters] || [], fn {dimension, _values} ->
        String.downcase(dimension) in ["time", "time_period"]
      end)

    range? = not is_nil(opts[:start_period] || opts[:end_period])

    cond do
      time_filters != [] and (opts[:time] || range?) ->
        Utils.option_error(
          "use either a time filter or :time/:start_period/:end_period, not both"
        )

      opts[:time] && range? ->
        Utils.option_error("use either :time or :start_period/:end_period, not both")

      true ->
        {:ok, filters, time_selection(time_filters, opts, range?)}
    end
  end

  defp time_selection([_ | _] = time_filters, _opts, _range?),
    do: {:periods, Enum.flat_map(time_filters, &elem(&1, 1))}

  defp time_selection([], opts, range?) do
    cond do
      opts[:time] -> {:periods, opts[:time]}
      range? -> {:range, opts[:start_period], opts[:end_period]}
      true -> nil
    end
  end

  defp time_3_0(nil), do: nil
  defp time_3_0({:periods, periods}), do: Enum.join(periods, ",")
  defp time_3_0({:range, start_period, end_period}), do: time_range_3_0(start_period, end_period)

  defp time_range_3_0(nil, nil), do: nil
  defp time_range_3_0(start, nil), do: "ge:#{start}"
  defp time_range_3_0(nil, finish), do: "le:#{finish}"
  defp time_range_3_0(start, finish), do: "ge:#{start}+le:#{finish}"

  defp observation_params(opts) do
    [{"firstNObservations", opts[:first_n]}, {"lastNObservations", opts[:last_n]}]
  end

  defp validate_format_options(opts, version) do
    format = opts[:format] || :json
    csv_2? = version == "3.0" and format == :csv

    [
      {opts[:labels] && not csv_2?,
       ":labels is only available for SDMX-CSV 2.0 (format: :csv, SDMX 3.0)"},
      {opts[:last_update_date] && not csv_2?,
       ":last_update_date is only available for SDMX-CSV 2.0 (format: :csv, SDMX 3.0)"},
      {opts[:return_data] && format not in [:csv, :csv_1, :tsv],
       ":return_data is only available for the TSV and SDMX-CSV formats"},
      {opts[:dimension_at_observation] && version != "2.1",
       ":dimension_at_observation is only available with SDMX 2.1"}
    ]
    |> Enum.find(fn {invalid?, _message} -> invalid? end)
    |> case do
      nil -> :ok
      {_invalid?, message} -> Utils.option_error(message)
    end
  end

  defp detail_3_0(nil), do: []
  defp detail_3_0(:full), do: []
  defp detail_3_0(:data_only), do: [{"attributes", "none"}, {"measures", "all"}]
  defp detail_3_0(:series_keys_only), do: [{"attributes", "none"}, {"measures", "none"}]
  defp detail_3_0(:no_data), do: [{"attributes", "series"}, {"measures", "none"}]

  defp detail_2_1(nil), do: nil
  defp detail_2_1(:full), do: "full"
  defp detail_2_1(:data_only), do: "dataonly"
  defp detail_2_1(:series_keys_only), do: "serieskeysonly"
  defp detail_2_1(:no_data), do: "nodata"

  defp format_3_0(:json), do: [{"format", "json"}]
  defp format_3_0(:csv), do: [{"format", "csvdata"}, {"formatVersion", "2.0"}]
  defp format_3_0(:csv_1), do: [{"format", "csvdata"}, {"formatVersion", "1.0"}]
  defp format_3_0(:tsv), do: [{"format", "tsv"}]
  defp format_3_0(:xml), do: []
  defp format_3_0(:xml_2_1), do: [{"format", "structurespecificdata"}, {"formatVersion", "2.1"}]
  defp format_3_0(:xml_generic), do: [{"format", "genericdata"}, {"formatVersion", "2.1"}]

  defp format_2_1(:json), do: "JSON"
  defp format_2_1(csv) when csv in [:csv, :csv_1], do: "SDMX-CSV"
  defp format_2_1(:tsv), do: "TSV"
  defp format_2_1(xml) when xml in [:xml, :xml_2_1], do: "SDMX_2.1_STRUCTURED"
  defp format_2_1(:xml_generic), do: nil

  defp return_data(nil), do: nil
  defp return_data(:all), do: "ALL"
  defp return_data(:data_only), do: "DATA_ONLY"

  # The language only applies to the labels of SDMX-CSV
  defp csv_language(opts) do
    if opts[:format] in [:csv, :csv_1] and opts[:labels] in [:name, :both],
      do: Utils.language(opts)
  end

  ## Keys

  @doc false
  # NimbleOptions validator for :key
  def validate_key(key) when is_binary(key), do: {:ok, key}

  def validate_key(key) when is_list(key) and key != [] do
    if Enum.all?(key, &key_part?/1),
      do: {:ok, key},
      else:
        {:error, "expected a list of codes, lists of codes, :all or nil, got: #{inspect(key)}"}
  end

  def validate_key(other), do: {:error, "expected a string or a list, got: #{inspect(other)}"}

  defp key_part?(part) when is_nil(part) or part == :all or is_binary(part) or is_integer(part),
    do: true

  defp key_part?(parts) when is_list(parts),
    do: Enum.all?(parts, &(is_binary(&1) or is_integer(&1)))

  defp key_part?(_part), do: false

  defp key_3_0(nil), do: {:ok, nil}
  defp key_3_0(key) when is_binary(key), do: {:ok, key}

  defp key_3_0(parts) do
    Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
      case part do
        wildcard when wildcard in [nil, :all, []] -> {:cont, {:ok, ["*" | acc]}}
        [single] -> {:cont, {:ok, [to_string(single) | acc]}}
        list when is_list(list) -> {:halt, :multiple}
        code -> {:cont, {:ok, [to_string(code) | acc]}}
      end
    end)
    |> case do
      {:ok, parts} ->
        {:ok, parts |> Enum.reverse() |> Enum.join(".")}

      :multiple ->
        Utils.option_error(
          "SDMX 3.0 keys accept a single value per dimension, use :filters for several values"
        )
    end
  end

  defp encode_key_2_1(nil), do: nil
  defp encode_key_2_1(key) when is_binary(key), do: key

  defp encode_key_2_1(parts) do
    Enum.map_join(parts, ".", fn
      wildcard when wildcard in [nil, :all] -> ""
      list when is_list(list) -> Enum.map_join(list, "+", &to_string/1)
      code -> to_string(code)
    end)
  end
end
