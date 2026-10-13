defmodule Eurostatx.Utils do
  @moduledoc false

  # Option schemas shared by the endpoint modules, plus the helpers that
  # translate the idiomatic Elixir options into the Eurostat query parameters.

  alias Eurostatx.Client
  alias Eurostatx.Error

  @agencies [:eurostat, :comext, :ecfin, :empl, :grow, :taxud]

  # REDISSTAT agencies (other Directorates-General) only serve SDMX 2.1
  @sdmx_2_1_only [:ecfin, :empl, :grow, :taxud]

  @doc """
  Validates `opts` against a NimbleOptions `schema`, returning an
  `Eurostatx.Error` of type `:option_error` when they are invalid.
  """
  def validate(opts, schema) do
    case NimbleOptions.validate(opts, schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, %NimbleOptions.ValidationError{} = error} -> option_error(Exception.message(error))
    end
  end

  @doc false
  def option_error(message), do: {:error, Error.new(:option_error, message)}

  @doc false
  def bang!({:ok, result}), do: result
  def bang!({:error, %Error{} = error}), do: raise(error)

  @doc false
  def schema(fields) do
    fields
    |> Enum.flat_map(&field_spec/1)
    |> Enum.sort_by(fn {field, _spec} -> field end)
    |> NimbleOptions.new!()
  end

  @doc """
  Resolves the agency of a request. `DS-` prefixed datasets (Comext and
  Prodcom) are served by the Comext endpoint, so it is selected
  automatically unless the agency is given explicitly.
  """
  def agency(dataset, opts) do
    case {opts[:agency], dataset} do
      {nil, "DS-" <> _rest} -> :comext
      {nil, "ds-" <> _rest} -> :comext
      {nil, _dataset} -> :eurostat
      {agency, _dataset} -> agency
    end
  end

  @doc """
  Resolves the SDMX version: `"3.0"` by default, `"2.1"` for the REDISSTAT
  agencies, which only serve SDMX 2.1.
  """
  def sdmx_version(agency, opts) do
    case {opts[:sdmx_version], agency in @sdmx_2_1_only} do
      {nil, true} ->
        {:ok, "2.1"}

      {nil, false} ->
        {:ok, "3.0"}

      {"3.0", true} ->
        option_error(
          "the #{inspect(agency)} agency only serves SDMX 2.1, use sdmx_version: \"2.1\""
        )

      {version, _only_2_1} ->
        {:ok, version}
    end
  end

  @doc false
  def client_opts(opts, agency, extra \\ []) do
    [agency: agency]
    |> Keyword.merge(Keyword.take(opts, [:async_timeout]))
    |> Keyword.merge(extra)
  end

  @doc "Language code in the case expected by each API (`:upper` for Statistics)."
  def language(opts, case \\ :lower) do
    language = opts[:language] || Client.default_language()
    if case == :upper, do: String.upcase(to_string(language)), else: to_string(language)
  end

  @doc "Finds the values of a dimension in normalized filters, ignoring case."
  def filter_values(filters, dimension) do
    Enum.find_value(filters || [], fn {key, values} ->
      if String.downcase(key) == String.downcase(dimension), do: values
    end)
  end

  ## Custom validators (they also normalize the values)

  @doc false
  # Filters: a keyword list or map of dimension => value(s). Normalized into
  # [{"geo", ["DE", "FR"]}, ...]
  def validate_filters(filters) when is_map(filters), do: validate_filters(Map.to_list(filters))

  def validate_filters(filters) when is_list(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn
      {key, values}, {:ok, acc} when (is_atom(key) or is_binary(key)) and key not in [nil, ""] ->
        case filter_values(values) do
          {:ok, values} -> {:cont, {:ok, [{to_string(key), values} | acc]}}
          :error -> {:halt, {:error, "invalid values for the #{key} filter: #{inspect(values)}"}}
        end

      other, _acc ->
        {:halt, {:error, "expected {dimension, value(s)} filters, got: #{inspect(other)}"}}
    end)
    |> case do
      {:ok, filters} -> {:ok, Enum.reverse(filters)}
      error -> error
    end
  end

  def validate_filters(other),
    do: {:error, "expected a keyword list or map of filters, got: #{inspect(other)}"}

  defp filter_values(values) when is_list(values) and values != [] do
    if Enum.all?(values, &filter_value?/1),
      do: {:ok, Enum.map(values, &to_string/1)},
      else: :error
  end

  defp filter_values(value) do
    if filter_value?(value), do: {:ok, [to_string(value)]}, else: :error
  end

  defp filter_value?(value), do: (is_binary(value) and value != "") or is_integer(value)

  @doc false
  # Time periods: 2024, "2024", "2024-Q1", "2024-03", ~D[2024-03-15]...
  def validate_period(%Date{} = date), do: {:ok, Date.to_iso8601(date)}
  def validate_period(year) when is_integer(year) and year > 0, do: {:ok, Integer.to_string(year)}

  def validate_period(period) when is_binary(period) do
    if Regex.match?(~r/^\d{4}(-?[A-Z0-9-]+)?$/i, period),
      do: {:ok, period},
      else: {:error, "invalid time period: #{inspect(period)}"}
  end

  def validate_period(other), do: {:error, "invalid time period: #{inspect(other)}"}

  @doc false
  def validate_periods(periods) when is_list(periods) and periods != [] do
    Enum.reduce_while(periods, {:ok, []}, fn period, {:ok, acc} ->
      case validate_period(period) do
        {:ok, period} -> {:cont, {:ok, [period | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, periods} -> {:ok, Enum.reverse(periods)}
      error -> error
    end
  end

  def validate_periods(period),
    do: with({:ok, period} <- validate_period(period), do: {:ok, [period]})

  ## Option specs

  defp field_spec(:language) do
    [
      language: [
        type: {:in, [:en, :fr, :de]},
        doc:
          "Language of the labels: `:en`, `:fr` or `:de`. " <>
            "Defaults to the `:language` application setting (`:en`).",
        type_doc: "`:en | :fr | :de`"
      ]
    ]
  end

  defp field_spec(:agency) do
    [
      agency: [
        type: {:in, @agencies},
        doc:
          "Agency whose API is queried: `:eurostat` (default), `:comext` (Comext and Prodcom " <>
            "datasets, selected automatically for `DS-` codes) or the REDISSTAT agencies " <>
            "`:ecfin`, `:empl`, `:grow` and `:taxud`. See `Eurostatx.Client`.",
        type_doc: "`:eurostat | :comext | :ecfin | :empl | :grow | :taxud`"
      ]
    ]
  end

  defp field_spec(:sdmx_version) do
    [
      sdmx_version: [
        type: {:in, ["3.0", "2.1"]},
        doc:
          ~s[Version of the SDMX API: `"3.0"` (default) or `"2.1"`. The REDISSTAT agencies ] <>
            "only serve SDMX 2.1, which is their default.",
        type_doc: ~s(`"3.0" | "2.1"`)
      ]
    ]
  end

  defp field_spec(:async_timeout) do
    [
      async_timeout: [
        type: :non_neg_integer,
        doc:
          "Milliseconds to wait when Eurostat answers asynchronously (big extractions). " <>
            "Defaults to the `:async_timeout` application setting (5 minutes). Use `0` to get " <>
            "an `Eurostatx.Error` of type `:queued` right away. See `Eurostatx.Async`."
      ]
    ]
  end

  defp field_spec(:filters) do
    [
      filters: [
        type: {:custom, __MODULE__, :validate_filters, []},
        doc:
          "Dimension filters, as a keyword list or map of dimension code to value or list of " <>
            ~s|values, e.g. `[geo: ["DE", "FR"], unit: "CP_MEUR"]`. Several values of a | <>
            "dimension are combined with OR. Codes are case-insensitive.",
        type_doc: "`keyword() | map()`"
      ]
    ]
  end

  defp field_spec(:time) do
    [
      time: [
        type: {:custom, __MODULE__, :validate_periods, []},
        doc:
          "Time period(s) to retrieve, e.g. `2024`, `\"2024-Q1\"` or `[2020, 2022]`. " <>
            "See `Eurostatx.Period` for the formats.",
        type_doc: "period or list of periods"
      ]
    ]
  end

  defp field_spec(:period_range) do
    [
      start_period: [
        type: {:custom, __MODULE__, :validate_period, []},
        doc:
          "First time period to retrieve (inclusive), e.g. `2015`, `\"2015-Q1\"`, " <>
            "`\"2015-01\"` or `~D[2015-01-01]`.",
        type_doc: "`integer() | String.t() | Date.t()`"
      ],
      end_period: [
        type: {:custom, __MODULE__, :validate_period, []},
        doc: "Last time period to retrieve (inclusive). Same formats as `:start_period`.",
        type_doc: "`integer() | String.t() | Date.t()`"
      ]
    ]
  end

  defp field_spec(:data_frame) do
    [
      labels: [
        type: :boolean,
        default: false,
        doc:
          "Add a `<dimension>_label` column next to every dimension column, and a " <>
            "`flag_label` column, with the labels in the requested language."
      ],
      shape: [
        type: {:in, [:long, :wide]},
        default: :long,
        doc:
          "Shape of the data frame. `:long` (tidy) has one row per observation, `:wide` a " <>
            "`date` column plus one column per series. See `Eurostatx.DataFrame`.",
        type_doc: "`:long | :wide`"
      ],
      rename: [
        type: {:map, :string, :string},
        doc:
          "A map of columns to rename in the resulting data frame, e.g. `%{\"DE\" => \"germany\"}`."
      ]
    ]
  end

  defp field_spec({name, spec}), do: [{name, spec}]
end
