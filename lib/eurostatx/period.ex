defmodule Eurostatx.Period do
  @moduledoc """
  Conversion of Eurostat time periods into dates.

  Eurostat identifies time periods with the ISO 8601 and SDMX notations
  listed in its [TSV format guide](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-faq/tsv-format):

  | Period     | Format       | Example      | Date (first day)  |
  | ---------- | ------------ | ------------ | ----------------- |
  | year       | `YYYY`       | `2015`       | `~D[2015-01-01]`  |
  | semester   | `YYYY-SN`    | `2015-S2`    | `~D[2015-07-01]`  |
  | quarter    | `YYYY-QN`    | `2015-Q4`    | `~D[2015-10-01]`  |
  | month      | `YYYY-MM`    | `2015-02`    | `~D[2015-02-01]`  |
  | week       | `YYYY-WNN`   | `2015-W01`   | `~D[2014-12-29]`  |
  | day        | `YYYY-MM-DD` | `2015-12-31` | `~D[2015-12-31]`  |

  The SDMX reporting periods `YYYY-A1`, `YYYY-MNN`, `YYYY-TN` (four-month
  periods) and `YYYY-DNNN` (day of the year) are supported too.

  When a period is used as an option (`:start_period`, `:end_period`, `:time`)
  it can be given as a string in any of these formats, an integer year or a
  `Date`.
  """

  @doc """
  Returns the first day of a time period, or `nil` if the period cannot be parsed.

  Weeks follow ISO 8601: week 1 is the week with the first Thursday of the
  year, and weeks start on Monday.

  ## Examples

      iex> Eurostatx.Period.to_date("2024")
      ~D[2024-01-01]

      iex> Eurostatx.Period.to_date("2024-Q2")
      ~D[2024-04-01]

      iex> Eurostatx.Period.to_date("2024-S2")
      ~D[2024-07-01]

      iex> Eurostatx.Period.to_date("2024-03")
      ~D[2024-03-01]

      iex> Eurostatx.Period.to_date("2024-W01")
      ~D[2024-01-01]

      iex> Eurostatx.Period.to_date("2024-03-15")
      ~D[2024-03-15]

      iex> Eurostatx.Period.to_date("2020-2024")
      nil
  """
  @spec to_date(String.t() | nil) :: Date.t() | nil
  def to_date(period) when is_binary(period) do
    period |> String.trim() |> String.upcase() |> parse()
  end

  def to_date(_period), do: nil

  defp parse(<<year::binary-size(4)>>), do: date(year, 1, 1)
  defp parse(<<year::binary-size(4), "-A1">>), do: date(year, 1, 1)
  defp parse(<<year::binary-size(4), "-S", n::binary-size(1)>>), do: nth(year, n, 2, 6)
  defp parse(<<year::binary-size(4), "-Q", n::binary-size(1)>>), do: nth(year, n, 4, 3)
  defp parse(<<year::binary-size(4), "-T", n::binary-size(1)>>), do: nth(year, n, 3, 4)
  defp parse(<<year::binary-size(4), "-M", month::binary-size(2)>>), do: date(year, month, 1)
  defp parse(<<year::binary-size(4), "-W", week::binary-size(2)>>), do: week(year, week)
  defp parse(<<year::binary-size(4), "-D", day::binary-size(3)>>), do: day_of_year(year, day)
  defp parse(<<year::binary-size(4), "-", month::binary-size(2)>>), do: date(year, month, 1)

  defp parse(<<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2)>>),
    do: date(year, month, day)

  defp parse(_period), do: nil

  # The n-th period of a year divided in `count` periods of `months` months
  defp nth(year, n, count, months) do
    case Integer.parse(n) do
      {n, ""} when n in 1..count//1 -> date(year, (n - 1) * months + 1, 1)
      _invalid -> nil
    end
  end

  defp week(year, week) do
    with {year, ""} <- Integer.parse(year),
         {week, ""} when week in 1..53 <- Integer.parse(week) do
      # 4 January is always in week 1
      january_4 = Date.new!(year, 1, 4)
      monday = Date.add(january_4, 1 - Date.day_of_week(january_4))
      Date.add(monday, (week - 1) * 7)
    else
      _invalid -> nil
    end
  end

  defp day_of_year(year, day) do
    with {:ok, first} <- date_tuple(year, 1, 1),
         {day, ""} when day in 1..366 <- Integer.parse(day),
         date = Date.add(first, day - 1),
         true <- date.year == first.year do
      date
    else
      _invalid -> nil
    end
  end

  defp date(year, month, day) do
    case date_tuple(year, month, day) do
      {:ok, date} -> date
      _invalid -> nil
    end
  end

  defp date_tuple(year, month, day) do
    with {:ok, year} <- to_integer(year),
         {:ok, month} <- to_integer(month),
         {:ok, day} <- to_integer(day) do
      Date.new(year, month, day)
    end
  end

  defp to_integer(value) when is_integer(value), do: {:ok, value}

  defp to_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _invalid -> :error
    end
  end
end
