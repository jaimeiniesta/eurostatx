defmodule Eurostatx.TSV do
  @moduledoc """
  Parser for the Eurostat TSV data format.

  The TSV format is specific to Eurostat and comes from its former bulk
  download facility. It is available in the SDMX APIs with `format: :tsv`
  (see `Eurostatx.Data`) and described in the
  [TSV format guide](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-faq/tsv-format):

  ```
  freq,unit,na_item,geo\\TIME_PERIOD	2023 	2024 	2025
  A,CP_MEUR,B1GQ,DE	4254930.0 p	4386940.0 p	4529710.0 p
  A,CP_MEUR,B1GQ,FR	2833826.4 	2935236.2 p	2991055.9 p
  ```

    - The first column holds the series key: the codes of the dimensions,
      separated by commas. Its header lists the dimension codes followed by
      `\\TIME_PERIOD`.
    - Every other column is a time period. Each cell has the observation value
      and its flags separated by a space (the space is there even without flags).
    - `:` means that the value is not available. With several frequencies in the
      same dataset it also means "not applicable" (a monthly series has no value
      for the annual columns).
    - Series without any data are not included, unless `return_data: :all` is
      requested.
  """

  @doc """
  Parses a TSV body into a list of observations.

  Every observation is a map with the code of each dimension, `"time"`,
  `"value"` (a float or `nil`) and `"flag"` (or `nil`). Cells that are not
  available (`:`) and have no flag are skipped. Unparseable values such as
  confidential `:` with a `c` flag are kept with a `nil` value.

  ## Examples

      iex> tsv = "freq,geo\\\\TIME_PERIOD\\t2024 \\t2025 \\nA,DE\\t1.5 p\\t: \\nA,FR\\t: c\\t2 \\n"
      iex> Eurostatx.TSV.parse(tsv)
      [
        %{"freq" => "A", "geo" => "DE", "time" => "2024", "value" => 1.5, "flag" => "p"},
        %{"freq" => "A", "geo" => "FR", "time" => "2024", "value" => nil, "flag" => "c"},
        %{"freq" => "A", "geo" => "FR", "time" => "2025", "value" => 2.0, "flag" => nil}
      ]
  """
  @spec parse(String.t()) :: [map()]
  def parse(tsv) when is_binary(tsv) do
    case String.split(tsv, ["\r\n", "\n"], trim: true) do
      [] ->
        []

      [header | lines] ->
        {dimensions, periods} = parse_header(header)
        Enum.flat_map(lines, &parse_line(&1, dimensions, periods))
    end
  end

  @doc """
  Returns the dimension codes and the time periods of a TSV body, read from
  its header line.

  ## Examples

      iex> Eurostatx.TSV.header("freq,unit,geo\\\\TIME_PERIOD\\t2024 \\t2025 \\nA,PC,DE\\t1 \\t2 \\n")
      {["freq", "unit", "geo"], ["2024", "2025"]}
  """
  @spec header(String.t()) :: {[String.t()], [String.t()]}
  def header(tsv) do
    tsv |> String.split(["\r\n", "\n"], parts: 2) |> hd() |> parse_header()
  end

  defp parse_header(header) do
    [keys | periods] = String.split(header, "\t")

    dimensions =
      keys
      |> String.split("\\")
      |> hd()
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    {dimensions, Enum.map(periods, &String.trim/1)}
  end

  defp parse_line(line, dimensions, periods) do
    [key | cells] = String.split(line, "\t")
    codes = key |> String.split(",") |> Enum.map(&String.trim/1)
    series = dimensions |> Enum.zip(codes) |> Map.new()

    periods
    |> Enum.zip(cells)
    |> Enum.flat_map(fn {period, cell} ->
      case parse_cell(cell) do
        {nil, nil} ->
          []

        {value, flag} ->
          [Map.merge(series, %{"time" => period, "value" => value, "flag" => flag})]
      end
    end)
  end

  # "4254930.0 p" -> {4254930.0, "p"}, ": " -> {nil, nil}, ": c" -> {nil, "c"}
  defp parse_cell(cell) do
    {value, flag} =
      case String.split(String.trim_leading(cell), " ", parts: 2) do
        [value, flag] -> {value, String.trim(flag)}
        [value] -> {value, ""}
      end

    {parse_value(String.trim(value)), if(flag == "", do: nil, else: flag)}
  end

  defp parse_value(":"), do: nil
  defp parse_value(""), do: nil

  defp parse_value(value) do
    case Float.parse(value) do
      {float, ""} -> float
      _other -> nil
    end
  end
end
