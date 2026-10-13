defmodule Eurostatx.Telemetry do
  @moduledoc """
  Telemetry integration for the Eurostatx library.

  Eurostatx emits telemetry events using `:telemetry.span/3` for every HTTP
  request made to the Eurostat APIs. Each span produces the following events:

  ## Events

  ### `[:eurostatx, :request, :start]`

  Emitted when a request begins.

  **Measurements:**

    - `:system_time` - System time at the start of the request (in native units)
    - `:monotonic_time` - Monotonic time at the start of the request

  **Metadata:**

    - `:api` - The API being called: `:statistics`, `:sdmx`, `:catalogue`,
      `:async` or `:files`
    - `:path` - The path of the request, relative to the base URL of the
      agency (e.g. `"statistics/1.0/data/NAMA_10_GDP"`)
    - `:url` - The full requested URL (including the query string)
    - `:params` - The query parameters sent to the API (list of `{key, value}` tuples)
    - `:agency` - The agency whose API is called (`:eurostat`, `:comext`, `:empl`...)

  ### `[:eurostatx, :request, :stop]`

  Emitted when a request completes (the HTTP round-trip finished, regardless of
  API-level errors).

  **Measurements:**

    - `:duration` - Total wall-clock duration in native time units.
      Convert with `System.convert_time_unit(duration, :native, :millisecond)`.

  **Metadata:** everything from the `:start` event plus:

    - `:status` - HTTP status code, or `nil` if the request never got a response
    - `:result` - `:ok`, `:error` or `:queued` (the API queued the request for
      asynchronous processing, see `Eurostatx.Async`)
    - `:error` - The `%Eurostatx.Error{}` struct (only present when `:result` is `:error`)
    - `:request_id` - The asynchronous request key (only present when `:result` is `:queued`)

  ### `[:eurostatx, :request, :exception]`

  Emitted when the request raises an unexpected exception.

  **Measurements:**

    - `:duration` - Wall-clock duration until the exception

  **Metadata:** everything from the `:start` event plus `:kind`, `:reason` and `:stacktrace`.

  ## Attaching Handlers

  You can attach your own handlers to any of these events:

  ```elixir
  :telemetry.attach(
    "my-eurostatx-handler",
    [:eurostatx, :request, :stop],
    &MyApp.handle_eurostatx_event/4,
    nil
  )
  ```

  Or use the built-in logger for quick request observability:

  ```elixir
  Eurostatx.Telemetry.Logger.attach()
  ```
  """

  alias Eurostatx.Error

  @typedoc false
  @type result :: {:ok, term()} | {:error, Error.t()} | {:queued, String.t() | nil}

  @doc false
  @spec span(map(), (-> {result(), non_neg_integer() | nil})) :: result()
  def span(metadata, fun) when is_map(metadata) and is_function(fun, 0) do
    :telemetry.span([:eurostatx, :request], metadata, fn ->
      {result, status} = fun.()
      {result, Map.merge(metadata, stop_metadata(result, status))}
    end)
  end

  defp stop_metadata({:ok, _body}, status), do: %{status: status, result: :ok}

  defp stop_metadata({:error, %Error{} = error}, status),
    do: %{status: status, result: :error, error: error}

  defp stop_metadata({:queued, request_id}, status),
    do: %{status: status, result: :queued, request_id: request_id}
end
