defmodule Eurostatx.DataFrame do
  @moduledoc """
  Converts Eurostat responses into `Explorer.DataFrame`s.

  Most users will not call this module directly: the `*_as_data_frame`
  functions (`Eurostatx.Data.get_as_data_frame/2`,
  `Eurostatx.Statistics.data_as_data_frame/2`...) use it under the hood. It is
  public so that you can convert any response yourself, including the TSV and
  SDMX-CSV formats.

  ## Long (tidy) format

  `from_json_stat/2` and `from_tsv/2` return **one row per observation**:

  | column           | dtype  | description                                                  |
  | ---------------- | ------ | ------------------------------------------------------------ |
  | one per dimension| string | The code of the dimension (`freq`, `unit`, `geo`...)         |
  | `time`           | string | The time period, e.g. `"2024"`, `"2024-Q2"`, `"2024-03"`     |
  | `date`           | date   | First day of the period (see `Eurostatx.Period`)             |
  | `value`          | f64    | The observation value (`nil` when not available)             |
  | `flag`           | string | The observation status: `"p"` provisional, `"e"` estimated...|

  With `labels: true` (JSON-stat only) a `<dimension>_label` column follows
  each dimension column, and a `flag_label` column follows `flag`.

  ## Wide format

  `to_wide/2` pivots a long data frame into a `date` column plus one column
  per series, which is the format returned by
  `Fred.Series.observations_as_data_frame/2` and is convenient for charts and
  comparisons. Series are named after the codes of the dimensions that vary
  between them: comparing the GDP of Germany and France gives the columns
  `"DE"` and `"FR"`.
  """

  alias Eurostatx.JSONStat
  alias Eurostatx.Period
  alias Eurostatx.TSV
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series

  @observation_columns ~w(time date value flag)

  @doc """
  Builds a long (tidy) data frame from a JSON-stat dataset, as returned by
  `Eurostatx.Statistics.data/2` and `Eurostatx.Data.get/2` with `format: :json`.

  ## Options

    - `:labels` - add label columns. Default `false`.

  ## Examples

      iex> json = %{
      ...>   "id" => ["geo", "time"],
      ...>   "size" => [2, 1],
      ...>   "dimension" => %{
      ...>     "geo" => %{"category" => %{"index" => %{"DE" => 0, "FR" => 1}, "label" => %{"DE" => "Germany", "FR" => "France"}}},
      ...>     "time" => %{"category" => %{"index" => %{"2025-Q1" => 0}}}
      ...>   },
      ...>   "value" => %{"0" => 1.5, "1" => 2.0},
      ...>   "status" => %{"1" => "p"}
      ...> }
      iex> df = Eurostatx.DataFrame.from_json_stat(json, labels: true)
      iex> Explorer.DataFrame.names(df)
      ["geo", "geo_label", "time", "date", "value", "flag", "flag_label"]
      iex> Explorer.DataFrame.to_columns(df, atom_keys: true) |> Map.take([:geo, :date, :value, :flag])
      %{geo: ["DE", "FR"], date: [~D[2025-01-01], ~D[2025-01-01]], value: [1.5, 2.0], flag: [nil, "p"]}
  """
  @spec from_json_stat(JSONStat.t(), keyword()) :: DF.t()
  def from_json_stat(json, opts \\ []) do
    labels? = Keyword.get(opts, :labels, false)

    dimension_columns =
      json
      |> JSONStat.dimensions()
      |> Enum.reject(&(&1["role"] == "time"))
      |> Enum.map(& &1["id"])
      |> Enum.flat_map(&if(labels?, do: [&1, &1 <> "_label"], else: [&1]))

    flag_columns = if labels?, do: ["flag", "flag_label"], else: ["flag"]

    json
    |> JSONStat.to_records(labels: labels?)
    |> build(dimension_columns, flag_columns)
  end

  @doc """
  Builds a long (tidy) data frame from a TSV body, as returned by
  `Eurostatx.Data.get/2` with `format: :tsv`. See `Eurostatx.TSV`.

  ## Examples

      iex> tsv = "freq,geo\\\\TIME_PERIOD\\t2024 \\t2025 \\nA,DE\\t1.5 p\\t2.5 \\n"
      iex> df = Eurostatx.DataFrame.from_tsv(tsv)
      iex> Explorer.DataFrame.names(df)
      ["freq", "geo", "time", "date", "value", "flag"]
      iex> df["value"] |> Explorer.Series.to_list()
      [1.5, 2.5]
  """
  @spec from_tsv(String.t()) :: DF.t()
  def from_tsv(tsv) do
    {dimensions, _periods} = TSV.header(tsv)
    tsv |> TSV.parse() |> build(dimensions, ["flag"])
  end

  @doc """
  Loads an SDMX-CSV body (as returned by `Eurostatx.Data.get/2` with
  `format: :csv`) with `Explorer.DataFrame.load_csv/2`.

  Every column is read as a string except `OBS_VALUE`, which is a float.
  Column names are kept as they are in the file (`STRUCTURE`, `freq`...,
  `TIME_PERIOD`, `OBS_VALUE`, `OBS_FLAG`...). This is the fastest way to load
  big extractions.

  ## Examples

      iex> csv = "STRUCTURE,STRUCTURE_ID,geo,TIME_PERIOD,OBS_VALUE,OBS_FLAG\\ndataflow,ESTAT:X(1.0),DE,2024,1.5,p\\n"
      iex> df = Eurostatx.DataFrame.from_csv(csv)
      iex> df["OBS_VALUE"] |> Explorer.Series.to_list()
      [1.5]
  """
  @spec from_csv(String.t()) :: DF.t()
  def from_csv(csv) do
    [header | _rows] = NimbleCSV.RFC4180.parse_string(csv, skip_headers: false)

    dtypes =
      Enum.map(header, fn
        "OBS_VALUE" -> {"OBS_VALUE", {:f, 64}}
        column -> {column, :string}
      end)

    DF.load_csv!(csv, dtypes: dtypes)
  end

  @doc false
  # Shared by the `*_as_data_frame` functions: long or wide data frame + renames
  @spec build_from_json_stat(JSONStat.t(), keyword()) :: DF.t()
  def build_from_json_stat(json, opts) do
    long = from_json_stat(json, labels: Keyword.get(opts, :labels, false))
    rename = Keyword.get(opts, :rename) || %{}

    case Keyword.get(opts, :shape, :long) do
      :wide -> to_wide(long, rename: rename)
      :long -> DF.rename(long, rename)
    end
  end

  @doc """
  Pivots a long data frame (see `from_json_stat/2`) into a wide one.

  The result has a `date` column followed by one column per series, sorted by
  date. Each series is named after the codes of the dimensions that vary
  between series, joined with `"."` (`"DE"`, `"FR"` or `"CP_MEUR.DE"`...). When
  there is a single series the column is named `"value"`. Series without an
  observation for a date get `nil`.

  When a period cannot be converted into a date the `time` column is used as
  index instead.

  ## Options

    - `:rename` - a map to rename the resulting columns, e.g. `%{"DE" => "germany"}`.

  ## Examples

      iex> long = Explorer.DataFrame.new(
      ...>   unit: ["PC", "PC", "PC"],
      ...>   geo: ["DE", "DE", "FR"],
      ...>   time: ["2024", "2025", "2024"],
      ...>   date: [~D[2024-01-01], ~D[2025-01-01], ~D[2024-01-01]],
      ...>   value: [1.0, 2.0, 3.0],
      ...>   flag: [nil, nil, nil]
      ...> )
      iex> wide = Eurostatx.DataFrame.to_wide(long, rename: %{"FR" => "france"})
      iex> Explorer.DataFrame.to_columns(wide, atom_keys: true)
      %{DE: [1.0, 2.0], france: [3.0, nil], date: [~D[2024-01-01], ~D[2025-01-01]]}
  """
  @spec to_wide(DF.t(), keyword()) :: DF.t()
  def to_wide(%DF{} = df, opts \\ []) do
    rename = Keyword.get(opts, :rename, %{})
    index = if Series.nil_count(df["date"]) == 0, do: "date", else: "time"
    dimensions = dimension_columns(df)

    if DF.n_rows(df) == 0 do
      DF.new([{index, []}], dtypes: [{index, df[index].dtype}])
    else
      varying = Enum.filter(dimensions, &(Series.n_distinct(df[&1]) > 1))

      df
      |> DF.put("series", series_names(df, varying))
      |> DF.select([index, "series", "value"])
      |> DF.pivot_wider("series", "value")
      |> DF.sort_with(&[asc: &1[index]])
      |> DF.rename(rename)
    end
  end

  @doc """
  Builds a data frame from a list of records (maps), such as the datasets of
  `Eurostatx.Datasets.list/1`, the table of contents of
  `Eurostatx.Catalogue.toc/1` or the files of `Eurostatx.Files.inventory/1`.

  Nested maps are flattened using dots (`"codelist.id"`), lists are encoded as
  JSON strings and columns mixing incompatible types are converted to strings.
  Column order follows the first appearance of each key.

  ## Examples

      iex> records = [%{"code" => "A", "name" => "Annual"}, %{"code" => "M", "name" => "Monthly", "parent" => nil}]
      iex> df = Eurostatx.DataFrame.from_records(records)
      iex> Explorer.DataFrame.to_columns(df)
      %{"code" => ["A", "M"], "name" => ["Annual", "Monthly"], "parent" => [nil, nil]}
  """
  @spec from_records(map() | [map()]) :: DF.t()
  def from_records(record) when is_map(record), do: from_records([record])

  def from_records(records) when is_list(records) do
    rows = Enum.map(records, &flatten_record/1)

    columns =
      rows
      |> Enum.flat_map(fn row -> Enum.map(row, &elem(&1, 0)) end)
      |> Enum.uniq()
      |> Enum.sort_by(&preferred_order/1)

    row_maps = Enum.map(rows, &Map.new/1)

    columns
    |> Enum.map(fn column -> {column, normalize_column(Enum.map(row_maps, & &1[column]))} end)
    |> DF.new()
  end

  ## Helpers

  defp build(records, dimension_columns, flag_columns) do
    columns = dimension_columns ++ @observation_columns ++ (flag_columns -- ["flag"])

    rows =
      Enum.map(records, fn record ->
        Map.put(record, "date", Period.to_date(record["time"]))
      end)

    dtypes =
      Enum.map(columns, fn
        "date" -> {"date", :date}
        "value" -> {"value", {:f, 64}}
        column -> {column, :string}
      end)

    columns
    |> Enum.map(fn column -> {column, Enum.map(rows, & &1[column])} end)
    |> DF.new(dtypes: dtypes)
  end

  # Every string column of a long data frame but the observation ones is a dimension
  defp dimension_columns(df) do
    df
    |> DF.dtypes()
    |> Enum.filter(fn {name, dtype} ->
      dtype == :string and name not in @observation_columns and name != "flag_label" and
        not String.ends_with?(name, "_label")
    end)
    |> Enum.map(&elem(&1, 0))
    |> then(fn names -> Enum.filter(DF.names(df), &(&1 in names)) end)
  end

  defp series_names(df, []), do: List.duplicate("value", DF.n_rows(df))

  defp series_names(df, varying) do
    varying
    |> Enum.map(&Series.to_list(df[&1]))
    |> Enum.zip_with(&Enum.join(&1, "."))
  end

  # "code"/"id" first, then labels/names, then the rest in order of appearance
  defp preferred_order(column) do
    case column do
      "id" -> 0
      "code" -> 0
      "label" -> 1
      "name" -> 1
      "title" -> 1
      _other -> 2
    end
  end

  defp flatten_record(record, prefix \\ nil) do
    Enum.flat_map(record, fn {key, value} ->
      key = if prefix, do: "#{prefix}.#{key}", else: to_string(key)

      case value do
        %Date{} = date -> [{key, date}]
        %DateTime{} = datetime -> [{key, datetime}]
        %NaiveDateTime{} = datetime -> [{key, datetime}]
        %{} = nested -> flatten_record(nested, key)
        list when is_list(list) -> [{key, JSON.encode!(list)}]
        scalar -> [{key, scalar}]
      end
    end)
  end

  defp normalize_column(values) do
    types = values |> Enum.reject(&is_nil/1) |> Enum.map(&value_type/1) |> Enum.uniq()

    case types do
      [] -> values
      [_single] -> values
      [:float, :integer] -> Enum.map(values, &if(is_integer(&1), do: &1 * 1.0, else: &1))
      [:integer, :float] -> Enum.map(values, &if(is_integer(&1), do: &1 * 1.0, else: &1))
      _mixed -> Enum.map(values, &if(is_nil(&1), do: nil, else: to_string(&1)))
    end
  end

  defp value_type(value) when is_integer(value), do: :integer
  defp value_type(value) when is_float(value), do: :float
  defp value_type(value) when is_boolean(value), do: :boolean
  defp value_type(value) when is_binary(value), do: :string
  defp value_type(%Date{}), do: :date
  defp value_type(%DateTime{}), do: :datetime
  defp value_type(%NaiveDateTime{}), do: :naive_datetime
  defp value_type(_value), do: :other
end
