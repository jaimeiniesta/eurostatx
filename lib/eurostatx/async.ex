defmodule Eurostatx.Async do
  @moduledoc """
  Functions for the [asynchronous API](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/asynchronous-api).

  The SDMX data queries can be answered asynchronously: instead of the data,
  Eurostat returns a request key, prepares the data in the background and
  serves it through this API. Eurostat decides it based on the estimated
  number of cells of the extraction:

    - below 500,000 cells (or when the result is cached), the data is returned
      synchronously;
    - between 500,000 and 5,000,000 cells, it is returned asynchronously;
    - above 5,000,000 cells, the request fails with an `Eurostatx.Error` of
      type `:too_big` and more filters are needed.

  Requests can also be forced to be asynchronous to ensure the fair use of the
  service, depending on the number of concurrent requests and on the requests
  and extraction cost of the last day, 7 days and 30 days. Eurostat
  recommends to make **one request at a time** and to use the bulk download
  (`Eurostatx.Files`) when possible. Eurostatx never makes concurrent requests.

  **You rarely need this module directly:** `Eurostatx.Data` waits for
  asynchronous responses automatically (see the `:async_timeout` option). If
  the data is not ready in time it returns an error of type `:queued` whose
  `:request_id` can be passed to `await/2` later.

  ## Endpoints

    - `status/2` - [`1.0/async/status/{key}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/asynchronous-api) - Status of a request
    - `data/2` - [`1.0/async/data/{key}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/asynchronous-api) - Data of a request, once available
    - `await/2` - Polls `status/2` until the data is available, then returns `data/2`
  """

  alias Eurostatx.Client
  alias Eurostatx.Error
  alias Eurostatx.Utils

  @statuses %{
    "SUBMITTED" => :submitted,
    "PROCESSING" => :processing,
    "AVAILABLE" => :available,
    "EXPIRED" => :expired,
    "UNKNOWN_REQUEST" => :unknown_request,
    "ERROR" => :error
  }

  @typedoc """
  Status of an asynchronous request:

    - `:submitted` - the request is submitted for processing
    - `:processing` - the request is being processed
    - `:available` - the data is available for download
    - `:expired` - the data is no longer available (after a few days, or when
      the dataset was updated). Repeat the original request.
    - `:unknown_request` - the key does not match any request
    - `:error` - the request was processed but an unexpected error occurred
  """
  @type status :: :submitted | :processing | :available | :expired | :unknown_request | :error

  @decode_spec [
    type: {:in, [:auto, :text]},
    default: :auto,
    doc: "`:auto` decodes JSON-stat responses, `:text` returns the body as a binary.",
    type_doc: "`:auto | :text`"
  ]

  @status_schema Utils.schema([:agency])
  @data_schema Utils.schema([:agency, {:decode, @decode_spec}])
  @await_schema Utils.schema([
                  :agency,
                  {:decode, @decode_spec},
                  {:timeout,
                   [
                     type: :non_neg_integer,
                     default: 300_000,
                     doc: "Milliseconds to wait for the data."
                   ]},
                  {:interval,
                   [
                     type: :non_neg_integer,
                     doc:
                       "Milliseconds between status checks. Defaults to the `:async_interval` " <>
                         "application setting (5 seconds)."
                   ]}
                ])

  @doc """
  Gets the status of an asynchronous request.

  Use the same `:agency` as the original request: Comext requests (`DS-`
  datasets) are tracked by the Comext endpoint.

  ## Options

  #{NimbleOptions.docs(@status_schema)}

  ## Examples

      iex> Eurostatx.Async.status("91430d7b-0fdc-4dac-9d06-3b7126518120", agency: :comext)
      {:ok, :available}

      iex> {:error, %Eurostatx.Error{type: :not_found}} =
      ...>   Eurostatx.Async.status("98de05ea-540a-43d3-903b-7c9e14faf808")
  """
  @spec status(String.t(), keyword()) :: {:ok, status()} | {:error, Error.t()}
  def status(request_id, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @status_schema),
         {:ok, body} <-
           Client.get(["1.0", "async", "status", request_id], [],
             agency: opts[:agency] || :eurostat,
             decode: :text
           ) do
      parse_status(body)
    end
  end

  @doc """
  Gets the data of an asynchronous request, in the format of the original
  request. Returns an error of type `:queued` while the data is not ready.

  ## Options

  #{NimbleOptions.docs(@data_schema)}

  ## Examples

      iex> {:ok, csv} = Eurostatx.Async.data("91430d7b-0fdc-4dac-9d06-3b7126518120", agency: :comext)
      iex> csv |> String.split("\\n") |> hd()
      "DATAFLOW,LAST UPDATE,freq,reporter,partner,product,flow,indicators,TIME_PERIOD,OBS_VALUE"
  """
  @spec data(String.t(), keyword()) :: Client.response()
  def data(request_id, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @data_schema) do
      fetch_data(request_id, opts[:agency] || :eurostat, opts[:decode])
    end
  end

  defp fetch_data(request_id, agency, decode) do
    case Client.get(["1.0", "async", "data", request_id], [], agency: agency, decode: decode) do
      {:error, %Error{type: :queued} = error} -> {:error, %{error | request_id: request_id}}
      result -> result
    end
  end

  @doc """
  Waits until an asynchronous request is available and returns its data.

  Polls `status/2` every `:interval` milliseconds. Returns an error of type
  `:queued` (with the `:request_id`) if the data is not ready within
  `:timeout`, and of type `:async_failed` if the request expired or failed.

  ## Options

  #{NimbleOptions.docs(@await_schema)}

  ## Examples

      iex> {:error, %Eurostatx.Error{type: :queued, request_id: id}} =
      ...>   Eurostatx.Data.get("DS-045409",
      ...>     key: "A.FI.CA..2.SUPPLEMENTARY_QUANTITY",
      ...>     sdmx_version: "2.1",
      ...>     format: :csv,
      ...>     async_timeout: 0
      ...>   )
      iex> {:ok, csv} = Eurostatx.Async.await(id, agency: :comext, timeout: 120_000)
  """
  @spec await(String.t(), keyword()) :: Client.response()
  def await(request_id, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @await_schema) do
      interval = opts[:interval] || Application.get_env(:eurostatx, :async_interval, 5_000)
      deadline = System.monotonic_time(:millisecond) + opts[:timeout]
      poll(request_id, opts[:agency] || :eurostat, opts[:decode], interval, deadline)
    end
  end

  defp poll(request_id, agency, decode, interval, deadline) do
    case status(request_id, agency: agency) do
      {:ok, :available} ->
        fetch_data(request_id, agency, decode)

      {:ok, pending} when pending in [:submitted, :processing] ->
        if System.monotonic_time(:millisecond) + interval < deadline do
          Process.sleep(interval)
          poll(request_id, agency, decode, interval, deadline)
        else
          {:error, Client.queued_error(request_id)}
        end

      {:ok, :unknown_request} ->
        {:error,
         Error.new(:not_found, "UNKNOWN_REQUEST: Unknown request.", request_id: request_id)}

      {:ok, failed} ->
        message =
          "The asynchronous request #{request_id} #{if failed == :expired, do: "expired", else: "failed"}. " <>
            "Repeat the original request."

        {:error, Error.new(:async_failed, message, request_id: request_id)}

      {:error, error} ->
        {:error, %{error | request_id: request_id}}
    end
  end

  # <ns1:status><ns1:key>...</ns1:key><ns1:status>AVAILABLE</ns1:status></ns1:status>
  defp parse_status(body) do
    with [_match, status] <-
           Regex.run(~r{<(?:\w+:)?status>\s*([A-Z_]+)\s*</(?:\w+:)?status>}, body),
         {:ok, status} <- Map.fetch(@statuses, status) do
      {:ok, status}
    else
      _unexpected ->
        {:error, Error.new(:api_error, "Unexpected asynchronous status response: #{body}")}
    end
  end
end
