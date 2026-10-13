defmodule Eurostatx.Telemetry.Logger do
  @moduledoc """
  A built-in telemetry handler that logs Eurostat API request details using Elixir's `Logger`.

  Attach it in your application's `start/2` callback (or at the top of a
  Livebook) for quick observability:

  ```elixir
  Eurostatx.Telemetry.Logger.attach()
  ```

  ## Output

  On every completed request (`:stop` event) it logs at the configured level:

  ```
  [eurostatx] GET statistics/1.0/data/NAMA_10_GDP - 200 in 412ms (params: [{"lang", "EN"}, {"geo", "DE"}])
  ```

  On errors and asynchronous (queued) responses:

  ```
  [eurostatx] GET sdmx/3.0/data/dataflow/ESTAT/NOPE/1.0 - error in 83ms: (HTTP 404) ERR_NOT_FOUND_4: NOPE...
  [eurostatx] GET sdmx/2.1/data/DS-045409/A.FI.CA..2.SUPPLEMENTARY_QUANTITY - queued in 230ms (request 91430d7b-...)
  ```

  On exceptions (`:exception` event):

  ```
  [eurostatx] GET catalogue/toc/xml - exception in 5012ms: %RuntimeError{message: "boom"}
  ```

  ## Configuration

  ```elixir
  Eurostatx.Telemetry.Logger.attach(
    level: :info,                   # Logger level (default: :info)
    handler_id: "my-eurostatx-log"  # Unique handler ID (default: "eurostatx-default-logger")
  )
  ```

  ## Detaching

  ```elixir
  Eurostatx.Telemetry.Logger.detach()

  # or with a custom ID:
  Eurostatx.Telemetry.Logger.detach("my-eurostatx-log")
  ```
  """

  require Logger

  @default_id "eurostatx-default-logger"

  @doc """
  Attaches the logger handler to the Eurostatx telemetry events.

  ## Options

    - `:level` - The `Logger` level to log at. Default: `:info`
    - `:handler_id` - A unique string ID for this handler. Default: `"eurostatx-default-logger"`.

  Returns `:ok` or `{:error, :already_exists}` if the handler ID is taken.
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    level = Keyword.get(opts, :level, :info)
    handler_id = Keyword.get(opts, :handler_id, @default_id)

    :telemetry.attach_many(
      handler_id,
      [[:eurostatx, :request, :stop], [:eurostatx, :request, :exception]],
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc """
  Detaches the logger handler. Defaults to the `"eurostatx-default-logger"` handler ID.
  """
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id \\ @default_id) do
    :telemetry.detach(handler_id)
  end

  @doc false
  def handle_event([:eurostatx, :request, :stop], measurements, metadata, config) do
    duration = duration_ms(measurements)

    message =
      case metadata[:result] do
        :ok ->
          "[eurostatx] GET #{metadata[:path]} - #{metadata[:status]} in #{duration}ms" <>
            format_params(metadata)

        :queued ->
          request = if id = metadata[:request_id], do: " (request #{id})", else: ""
          "[eurostatx] GET #{metadata[:path]} - queued in #{duration}ms#{request}"

        :error ->
          error_detail =
            if error = metadata[:error], do: ": #{Exception.message(error)}", else: ""

          "[eurostatx] GET #{metadata[:path]} - error in #{duration}ms#{error_detail}" <>
            format_params(metadata)
      end

    Logger.log(config.level, message)
  end

  def handle_event([:eurostatx, :request, :exception], measurements, metadata, config) do
    message =
      "[eurostatx] GET #{metadata[:path]} - exception in #{duration_ms(measurements)}ms: " <>
        "#{inspect(metadata[:reason])}#{format_params(metadata)}"

    Logger.log(config.level, message)
  end

  defp duration_ms(%{duration: duration}),
    do: System.convert_time_unit(duration, :native, :millisecond)

  defp format_params(%{params: [_ | _] = params}), do: " (params: #{inspect(params)})"
  defp format_params(_metadata), do: ""
end
