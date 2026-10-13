defmodule Eurostatx.JSONStat do
  @moduledoc """
  Conversion of [JSON-stat 2.0](https://json-stat.org/format/) datasets into
  observations.

  JSON-stat is the format of the Statistics API (`Eurostatx.Statistics`) and
  of the SDMX data queries with `format: :json` (`Eurostatx.Data`). A JSON-stat
  dataset is a cube: `"id"` lists the dimensions, `"size"` the number of
  categories of each one and `"dimension"` their codes (`"index"`) and labels.
  Values are stored in a flat `"value"` array or object whose positions follow
  the row-major order of the dimensions, and the statuses (flags) in `"status"`.

  `to_records/2` walks the values and returns one map per observation, with
  the code of every dimension. Observations without value but with a status
  (for example confidential `"c"` values) are kept with a `nil` value.
  """

  @typedoc "A decoded JSON-stat 2.0 dataset."
  @type t :: map()

  @doc """
  Converts a JSON-stat dataset into a list of observations.

  Every observation is a map with one key per dimension (its code, e.g.
  `"geo" => "DE"`), plus `"value"` (a float or `nil`) and `"flag"` (the status,
  or `nil`). The keys follow the dimension ids of the dataset (usually
  lowercase), except for the time dimension, which is always `"time"`: its id
  is `"time"` in the Eurostat datasets and `"TIME_PERIOD"` in the REDISSTAT
  ones, and it can also be declared in the `"role"` of the dataset.

  ## Options

    - `:labels` - when `true`, also adds a `"<dimension>_label"` key for every
      dimension but time, and `"flag_label"`. Default `false`.

  ## Examples

      iex> json = %{
      ...>   "id" => ["geo", "time"],
      ...>   "size" => [2, 2],
      ...>   "dimension" => %{
      ...>     "geo" => %{"category" => %{"index" => %{"DE" => 0, "FR" => 1}, "label" => %{"DE" => "Germany", "FR" => "France"}}},
      ...>     "time" => %{"category" => %{"index" => %{"2024" => 0, "2025" => 1}}}
      ...>   },
      ...>   "value" => %{"0" => 1.5, "1" => 2.0, "3" => 4.0},
      ...>   "status" => %{"1" => "p", "2" => "c"},
      ...>   "extension" => %{"status" => %{"label" => %{"p" => "provisional", "c" => "confidential"}}}
      ...> }
      iex> Eurostatx.JSONStat.to_records(json)
      [
        %{"geo" => "DE", "time" => "2024", "value" => 1.5, "flag" => nil},
        %{"geo" => "DE", "time" => "2025", "value" => 2.0, "flag" => "p"},
        %{"geo" => "FR", "time" => "2024", "value" => nil, "flag" => "c"},
        %{"geo" => "FR", "time" => "2025", "value" => 4.0, "flag" => nil}
      ]
      iex> json |> Eurostatx.JSONStat.to_records(labels: true) |> hd()
      %{"geo" => "DE", "geo_label" => "Germany", "time" => "2024", "value" => 1.5, "flag" => nil, "flag_label" => nil}
  """
  @spec to_records(t(), keyword()) :: [map()]
  def to_records(json, opts \\ []) when is_map(json) do
    labels? = Keyword.get(opts, :labels, false)
    dimensions = parse_dimensions(json)
    strides = strides(Enum.map(dimensions, & &1.size))
    values = indexed(json["value"])
    statuses = indexed(json["status"], Enum.product(Enum.map(dimensions, & &1.size)))
    flag_labels = get_in(json, ["extension", "status", "label"]) || %{}

    values
    |> Map.keys()
    |> Enum.concat(Map.keys(statuses))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn index ->
      flag = Map.get(statuses, index)

      base = %{"value" => to_float(Map.get(values, index)), "flag" => flag}
      base = if labels?, do: Map.put(base, "flag_label", flag_labels[flag]), else: base

      dimensions
      |> Enum.zip(strides)
      |> Enum.reduce(base, &put_dimension(&2, &1, index, labels?))
    end)
  end

  # The position of the category of a dimension is the flat index divided by
  # the stride of the dimension, modulo its size
  defp put_dimension(record, {dimension, stride}, index, labels?) do
    code = elem(dimension.codes, index |> div(stride) |> rem(dimension.size))
    record = Map.put(record, dimension.key, code)

    if labels? and not dimension.time?,
      do: Map.put(record, dimension.id <> "_label", Map.get(dimension.labels, code)),
      else: record
  end

  @doc """
  Returns the dimensions of a JSON-stat dataset, in order, with their label,
  their categories (code and label) and their `"role"` (`"time"` for the time
  dimension, `nil` otherwise).

  ## Examples

      iex> Eurostatx.JSONStat.dimensions(%{
      ...>   "id" => ["geo"],
      ...>   "size" => [2],
      ...>   "dimension" => %{"geo" => %{"label" => "Geopolitical entity", "category" => %{
      ...>     "index" => %{"FR" => 1, "DE" => 0}, "label" => %{"DE" => "Germany", "FR" => "France"}}}}
      ...> })
      [%{"id" => "geo", "label" => "Geopolitical entity", "role" => nil, "categories" => [
        %{"code" => "DE", "label" => "Germany"}, %{"code" => "FR", "label" => "France"}]}]
  """
  @spec dimensions(t()) :: [map()]
  def dimensions(json) do
    json
    |> parse_dimensions()
    |> Enum.map(fn dimension ->
      %{
        "id" => dimension.id,
        "label" => dimension.label,
        "role" => if(dimension.time?, do: "time"),
        "categories" =>
          dimension.codes
          |> Tuple.to_list()
          |> Enum.map(&%{"code" => &1, "label" => Map.get(dimension.labels, &1)})
      }
    end)
  end

  defp parse_dimensions(%{"id" => ids, "size" => sizes} = json) do
    time_roles = get_in(json, ["role", "time"]) || []

    ids
    |> Enum.zip(sizes)
    |> Enum.map(fn {id, size} ->
      dimension = get_in(json, ["dimension", id]) || %{}
      category = dimension["category"] || %{}
      time? = id in time_roles or String.downcase(id) in ["time", "time_period"]

      %{
        id: id,
        key: if(time?, do: "time", else: id),
        time?: time?,
        size: size,
        label: dimension["label"],
        codes: category |> category_codes() |> List.to_tuple(),
        labels: category["label"] || %{}
      }
    end)
  end

  defp parse_dimensions(_json), do: []

  # "index" can be an object (code => position) or an array of codes. A
  # dimension with a single category may have no index at all.
  defp category_codes(%{"index" => index}) when is_map(index) do
    index |> Enum.sort_by(fn {_code, position} -> position end) |> Enum.map(&elem(&1, 0))
  end

  defp category_codes(%{"index" => index}) when is_list(index), do: index
  defp category_codes(%{"label" => labels}) when is_map(labels), do: Map.keys(labels)
  defp category_codes(_category), do: []

  defp strides([]), do: []

  defp strides(sizes) do
    sizes
    |> Enum.reverse()
    |> Enum.scan(1, &(&1 * &2))
    |> Enum.reverse()
    |> tl()
    |> Kernel.++([1])
  end

  # Values and statuses can be arrays, objects keyed by position, or (statuses
  # only) a single string that applies to every value.
  defp indexed(data, size \\ 0)
  defp indexed(nil, _size), do: %{}

  defp indexed(data, _size) when is_map(data) do
    Map.new(data, fn {index, value} -> {String.to_integer(index), value} end)
  end

  defp indexed(data, _size) when is_list(data) do
    for {value, index} <- Enum.with_index(data), not is_nil(value), into: %{}, do: {index, value}
  end

  defp indexed(status, size) when is_binary(status) and size > 0 do
    Map.new(0..(size - 1), &{&1, status})
  end

  defp indexed(_data, _size), do: %{}

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0
  defp to_float(_value), do: nil
end
