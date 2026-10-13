defmodule Eurostatx.Client do
  @moduledoc """
  Low-level HTTP client for the Eurostat APIs, built on `Req`.

  Every request has the shape documented by Eurostat:

  ```
  https://{api_base_uri}/{path}[?params]
  ```

  where `{api_base_uri}` depends on the agency (see "Agencies" below) and
  `{path}` selects the API: `statistics/1.0/...`, `sdmx/2.1/...`,
  `sdmx/3.0/...`, `catalogue/...`, `1.0/async/...` or `files/...`.

  This module handles URL construction, query string encoding (including
  repeated parameters such as `geo=DE&geo=FR` and the `c[DIM]` filters of
  SDMX 3.0), decompression, response decoding, error normalization,
  asynchronous responses and telemetry. All the endpoint modules
  (`Eurostatx.Data`, `Eurostatx.Statistics`...) delegate to it, but you can
  also use it directly to call any endpoint:

      iex> Eurostatx.Client.get(["statistics", "1.0", "data", "TPS00001"], geo: "DE", lastTimePeriod: 1)
      {:ok, %{"class" => "dataset", "value" => %{"0" => 83467117}, ...}}

  ## Agencies

  Besides Eurostat, the same APIs are served for the Comext/Prodcom databases
  and for other Directorates-General of the European Commission (REDISSTAT).

  | Agency       | Base URL                                                     | SDMX agency ID |
  | ------------ | ------------------------------------------------------------ | -------------- |
  | `:eurostat`  | `https://ec.europa.eu/eurostat/api/dissemination`            | `ESTAT`        |
  | `:comext`    | `https://ec.europa.eu/eurostat/api/comext/dissemination`     | `ESTAT`        |
  | `:ecfin`     | `https://webgate.ec.europa.eu/ecfin/redisstat/api/dissemination` | `ECFIN`    |
  | `:empl`      | `https://webgate.ec.europa.eu/empl/redisstat/api/dissemination`  | `EMPL`     |
  | `:grow`      | `https://webgate.ec.europa.eu/grow/redisstat/api/dissemination`  | `GROW`     |
  | `:taxud`     | `https://webgate.ec.europa.eu/taxation_customs/redisstat/api/dissemination` | `TAXUD` |

  ## Response handling

    - Compressed responses are decompressed. Eurostat gzips SDMX responses
      without a `Content-Encoding` header, so the body is checked for the gzip
      magic bytes.
    - JSON bodies (JSON-stat and the API errors) are decoded. Every other
      format (SDMX-ML, SDMX-CSV, TSV, RSS...) is returned as a binary.
    - Error responses, either SOAP faults (`<S:Fault>`), JSON errors or HTML
      pages, are normalized into `Eurostatx.Error`. See its docs for the types.

  ## Asynchronous responses

  Big extractions are not answered directly: the SDMX APIs answer with a
  request key and the Statistics API with an HTTP 413 and an
  `ASYNCHRONOUS_RESPONSE` message.
  By default the client waits for the data: it polls `Eurostatx.Async` (SDMX)
  or repeats the request (Statistics) every `:async_interval` milliseconds
  until the data is available or `:async_timeout` expires, in which case it
  returns `{:error, %Eurostatx.Error{type: :queued}}`. Set `async_timeout: 0`
  to get that error right away.

  ## Configuration

  ```elixir
  config :eurostatx,
    language: :en,              # :en (default), :fr or :de
    timeout: 120_000,           # receive timeout of each request in ms
    async_timeout: 300_000,     # how long to wait for asynchronous responses in ms
    async_interval: 5_000,      # interval between asynchronous status checks in ms
    base_urls: %{},             # override base URLs per agency, e.g. %{eurostat: "https://..."}
    req_options: []             # extra options for Req.new/1
  ```

  `:req_options` is merged into the `Req` request, so you can tweak retries,
  add a proxy or plug a `Req.Test` stub in your test suite:

  ```elixir
  # config/test.exs
  config :eurostatx, req_options: [plug: {Req.Test, Eurostatx.Client}, retry: false]
  ```

  ## Telemetry

  Every HTTP request is wrapped in an `[:eurostatx, :request]` telemetry span.
  See `Eurostatx.Telemetry` for event names, measurements and metadata.
  """

  alias Eurostatx.Async
  alias Eurostatx.Error
  alias Eurostatx.Telemetry

  @type response :: {:ok, term()} | {:error, Error.t()}
  @type agency :: :eurostat | :comext | :ecfin | :empl | :grow | :taxud
  @type segment :: String.t() | integer()

  @base_urls %{
    eurostat: "https://ec.europa.eu/eurostat/api/dissemination",
    comext: "https://ec.europa.eu/eurostat/api/comext/dissemination",
    ecfin: "https://webgate.ec.europa.eu/ecfin/redisstat/api/dissemination",
    empl: "https://webgate.ec.europa.eu/empl/redisstat/api/dissemination",
    grow: "https://webgate.ec.europa.eu/grow/redisstat/api/dissemination",
    taxud: "https://webgate.ec.europa.eu/taxation_customs/redisstat/api/dissemination"
  }

  @agency_ids %{
    eurostat: "ESTAT",
    comext: "ESTAT",
    ecfin: "ECFIN",
    empl: "EMPL",
    grow: "GROW",
    taxud: "TAXUD"
  }

  @default_timeout 120_000
  @default_async_timeout 300_000
  @default_async_interval 5_000

  # Only the beginning of a body is inspected to detect an asynchronous answer
  @envelope_prefix_size 600

  @doc """
  Makes a GET request to the Eurostat APIs.

  ## Arguments

    - `segments` - the path relative to the base URL of the agency, as a list
      of segments, e.g. `["statistics", "1.0", "data", "NAMA_10_GDP"]`. Each
      segment is percent-encoded, keeping the characters used by SDMX keys
      and wildcards (`.`, `+`, `*`, `~`, `,`, `$`, `@`).
    - `params` - query parameters as a list of `{key, value}` tuples using the
      Eurostat names (`lang`, `geo`, `c[geo]`, `startPeriod`...). Repeated keys
      are kept, `nil` values are dropped.
    - `opts`:
      - `:agency` - see "Agencies" in the module docs. Default `:eurostat`.
      - `:decode` - `:auto` (default) decompresses the body and decodes JSON
        responses, `:text` only decompresses it and `:binary` returns the
        body untouched (for file downloads).
      - `:async_timeout` - milliseconds to wait for asynchronous responses.
        Defaults to the `:async_timeout` application setting (5 minutes).
      - `:async_interval` - milliseconds between status checks. Defaults to
        the `:async_interval` application setting (5 seconds).
  """
  @spec get([segment()], [{atom() | String.t(), term()}], keyword()) :: response()
  def get(segments, params \\ [], opts \\ []) do
    agency = Keyword.get(opts, :agency, :eurostat)

    params =
      for {key, value} <- params, not is_nil(value), do: {to_string(key), to_string(value)}

    deadline = System.monotonic_time(:millisecond) + async_timeout(opts)
    do_get(segments, params, agency, opts, deadline)
  end

  defp do_get(segments, params, agency, opts, deadline) do
    case request(segments, params, agency, opts) do
      # The Statistics API does not give a key: the same request must be repeated
      {:queued, nil} ->
        if wait(deadline, opts),
          do: do_get(segments, params, agency, opts, deadline),
          else: {:error, queued_error(nil)}

      {:queued, request_id} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining > 0 do
          Async.await(request_id,
            agency: agency,
            timeout: remaining,
            interval: async_interval(opts),
            decode: Keyword.get(opts, :decode, :auto)
          )
        else
          {:error, queued_error(request_id)}
        end

      result ->
        result
    end
  end

  defp wait(deadline, opts) do
    interval = async_interval(opts)

    if System.monotonic_time(:millisecond) + interval < deadline do
      Process.sleep(interval)
      true
    else
      false
    end
  end

  @doc false
  @spec queued_error(String.t() | nil) :: Error.t()
  def queued_error(nil) do
    Error.new(
      :queued,
      "Eurostat is processing the request asynchronously and the data was not ready " <>
        "within :async_timeout. Repeat the request later."
    )
  end

  def queued_error(request_id) do
    Error.new(
      :queued,
      "Eurostat is processing the request asynchronously and the data was not ready " <>
        "within :async_timeout. Get it later with Eurostatx.Async.await(#{inspect(request_id)}).",
      request_id: request_id
    )
  end

  defp request(segments, params, agency, opts) do
    path = Enum.map_join(segments, "/", &encode_segment/1)
    url = build_url(agency, path, params)
    metadata = %{api: api(segments), path: path, url: url, params: params, agency: agency}

    Telemetry.span(metadata, fn -> execute(url, Keyword.get(opts, :decode, :auto)) end)
  end

  @doc false
  @spec build_url(agency(), String.t(), [{String.t(), String.t()}]) :: String.t()
  def build_url(agency, path, params) do
    url = base_url(agency) <> "/" <> path

    case params do
      [] -> url
      params -> url <> "?" <> URI.encode_query(params, :rfc3986)
    end
  end

  @doc """
  Returns the base URL of an agency, taking the `:base_urls` application
  setting into account.

      iex> Eurostatx.Client.base_url(:comext)
      "https://ec.europa.eu/eurostat/api/comext/dissemination"
  """
  @spec base_url(agency()) :: String.t()
  def base_url(agency) do
    (Application.get_env(:eurostatx, :base_urls) || %{})
    |> Map.get(agency, Map.fetch!(@base_urls, agency))
    |> String.trim_trailing("/")
  end

  @doc """
  Returns the SDMX agency ID used in the paths of an agency.

      iex> Eurostatx.Client.agency_id(:empl)
      "EMPL"
  """
  @spec agency_id(agency()) :: String.t()
  def agency_id(agency), do: Map.fetch!(@agency_ids, agency)

  @doc false
  def agencies, do: Map.keys(@base_urls)

  defp execute(url, decode) do
    request =
      [
        url: url,
        decode_body: false,
        receive_timeout: Application.get_env(:eurostatx, :timeout, @default_timeout),
        headers: [user_agent: "eurostatx/#{Application.spec(:eurostatx, :vsn)} (Elixir)"]
      ]
      |> Keyword.merge(Application.get_env(:eurostatx, :req_options, []))
      |> Req.new()

    case Req.get(request) do
      {:ok, %Req.Response{status: status, body: body} = response} when status in 200..299 ->
        {success(body, content_type(response), decode), status}

      {:ok, %Req.Response{status: status, body: body}} ->
        {failure(status, body), status}

      {:error, exception} ->
        message = "Request failed: #{Exception.message(exception)}"
        {{:error, Error.new(:request_error, message)}, nil}
    end
  end

  # The Statistics API answers big extractions with an HTTP 413 and
  # {"error": [{"status": 413, "label": "ASYNCHRONOUS_RESPONSE. ..."}]}: the
  # same request must be repeated later.
  defp failure(status, body) do
    case error_from_body(status, body) do
      %Error{message: "ASYNCHRONOUS_RESPONSE" <> _rest} -> {:queued, nil}
      error -> {:error, error}
    end
  end

  defp success(body, _content_type, :binary), do: {:ok, body}

  defp success(body, content_type, decode) do
    with {:ok, body} <- gunzip(body) do
      cond do
        queued?(body) -> queued(body)
        decode == :auto and json?(body, content_type) -> decode_json(body)
        true -> {:ok, body}
      end
    end
  end

  defp gunzip(<<0x1F, 0x8B, _rest::binary>> = body) do
    {:ok, :zlib.gunzip(body)}
  rescue
    error in ErlangError ->
      {:error,
       Error.new(:decode_error, "Invalid gzip body: #{Exception.message(error)}", status: 200)}
  end

  defp gunzip(body), do: {:ok, body}

  defp json?(body, content_type) do
    String.contains?(content_type, "json") or
      match?(<<char, _rest::binary>> when char in [?{, ?[], String.trim_leading(prefix(body)))
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, %{"warning" => warning} = decoded} ->
        if asynchronous_warning?(warning), do: {:queued, nil}, else: {:ok, decoded}

      {:ok, %{"error" => _error} = decoded} ->
        {:error, error_from_json(200, decoded)}

      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        {:error, Error.new(:decode_error, "Invalid JSON: #{inspect(reason)}", status: 200)}
    end
  end

  # The format documented in the guide (the API answers with an HTTP 413, see failure/2):
  # {"warning":{"status":413,"label":"ASYNCHRONOUS_RESPONSE. Your request will be treated..."}}
  defp asynchronous_warning?(warnings) do
    warnings
    |> List.wrap()
    |> Enum.any?(fn warning ->
      is_map(warning) and
        (to_string(warning["status"]) == "413" or
           String.contains?(to_string(warning["label"]), "ASYNCHRONOUS"))
    end)
  end

  # <env:Envelope ...><ns0:syncResponse ...><queued><id>...</id><status>SUBMITTED</status>
  defp queued?(body) do
    prefix = prefix(body)
    # The status of the async API is an "asyncResponse": do not mistake it for this one
    String.contains?(prefix, "Envelope") and
      (String.contains?(prefix, ":syncResponse") or String.contains?(prefix, "<syncResponse"))
  end

  defp queued(body) do
    case Regex.run(~r{<queued>.*?<id>\s*([^<\s]+)\s*</id>}s, body) do
      [_, request_id] ->
        {:queued, request_id}

      nil ->
        {:error, Error.new(:api_error, "Unexpected asynchronous response: #{body}", status: 200)}
    end
  end

  defp prefix(body), do: binary_part(body, 0, min(byte_size(body), @envelope_prefix_size))

  @doc false
  # Builds an Eurostatx.Error from the body of an error response: a SOAP fault,
  # a JSON error or an HTML page.
  @spec error_from_body(non_neg_integer(), binary()) :: Error.t()
  def error_from_body(status, body) do
    body =
      case gunzip(body) do
        {:ok, unzipped} -> unzipped
        {:error, _error} -> body
      end

    cond do
      fault = soap_fault(body) ->
        {code, message} = fault
        Error.new(error_type(status, code, message), message, status: status, code: code)

      json?(body, "") ->
        case JSON.decode(body) do
          {:ok, decoded} -> error_from_json(status, decoded)
          {:error, _reason} -> text_error(status, body)
        end

      true ->
        text_error(status, body)
    end
  end

  defp soap_fault(body) do
    with [_, code] <- Regex.run(~r{<faultcode>(.*?)</faultcode>}s, body),
         [_, message] <- Regex.run(~r{<faultstring>(.*?)</faultstring>}s, body) do
      {String.trim(code), message |> unescape_xml() |> String.trim()}
    else
      _no_fault -> nil
    end
  end

  # {"error": [{"status": 400, "id": 400, "label": "..."}]} (the docs show an object, the API a list)
  defp error_from_json(status, %{"error" => errors}) do
    error = errors |> List.wrap() |> List.first() || %{}
    status = if status == 200, do: parse_status(error["status"]), else: status
    code = if error["id"], do: to_string(error["id"])
    message = to_string(error["label"] || "Eurostat API error")

    Error.new(error_type(status, code, message), message, status: status, code: code)
  end

  defp error_from_json(status, decoded) do
    Error.new(error_type(status, nil, ""), "Unexpected response: #{inspect(decoded)}",
      status: status
    )
  end

  defp text_error(status, body) do
    text =
      body
      |> ensure_utf8()
      |> String.replace(~r{<(style|script)[^>]*>.*?</\1>}is, " ")
      |> String.replace(~r{<[^>]*>}, " ")
      |> String.replace(~r{\s+}, " ")
      |> String.trim()

    # HTML pages of the files API: "... File nope.zip does not exist or is not readable on the server ..."
    text =
      case Regex.run(~r{File .+? does not exist[^.<]*?on the server}, text) do
        [sentence] -> sentence
        nil -> String.slice(text, 0, 300)
      end

    message = if text == "", do: "Unexpected response from the Eurostat API", else: text
    Error.new(error_type(status, nil, message), message, status: status)
  end

  # Eurostat error messages start with a constant, e.g. "ERR_NOT_FOUND_4: NOPE (...)"
  @error_messages [
    {"EXTRACTION_TOO_BIG", :too_big},
    {"NO_RESULTS", :no_results},
    {"DATA_NOT_YET_AVAILABLE", :queued},
    {"ASYNCHRONOUS_RESPONSE", :queued},
    {"ERR_NOT_FOUND", :not_found},
    {"UNKNOWN_REQUEST", :not_found}
  ]

  defp error_type(status, code, message) do
    Enum.find_value(@error_messages, fn {constant, type} ->
      if String.contains?(message, constant), do: type
    end) || status_error_type(status, code)
  end

  defp status_error_type(413, _code), do: :too_big
  defp status_error_type(_status, "413"), do: :too_big
  defp status_error_type(404, _code), do: :not_found
  defp status_error_type(400, _code), do: :invalid_query
  defp status_error_type(_status, code) when code in ["140", "150"], do: :invalid_query
  defp status_error_type(_status, _code), do: :api_error

  defp parse_status(status) when is_integer(status), do: status

  defp parse_status(status) when is_binary(status) do
    case Integer.parse(status) do
      {status, ""} -> status
      _other -> 200
    end
  end

  defp parse_status(_status), do: 200

  @doc false
  def unescape_xml(text) do
    text
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&amp;", "&")
  end

  defp ensure_utf8(text) do
    if String.valid?(text), do: text, else: :unicode.characters_to_binary(text, :latin1)
  end

  defp content_type(%Req.Response{} = response) do
    response |> Req.Response.get_header("content-type") |> Enum.join(";") |> String.downcase()
  end

  defp encode_segment(segment) do
    segment
    |> to_string()
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 in ~c"*+~,$@:"))
  end

  defp api(["statistics" | _rest]), do: :statistics
  defp api(["sdmx" | _rest]), do: :sdmx
  defp api(["catalogue" | _rest]), do: :catalogue
  defp api(["1.0", "async" | _rest]), do: :async
  defp api(["files" | _rest]), do: :files
  defp api(_segments), do: :other

  defp async_timeout(opts) do
    Keyword.get_lazy(opts, :async_timeout, fn ->
      Application.get_env(:eurostatx, :async_timeout, @default_async_timeout)
    end)
  end

  defp async_interval(opts) do
    Keyword.get_lazy(opts, :async_interval, fn ->
      Application.get_env(:eurostatx, :async_interval, @default_async_interval)
    end)
  end

  @doc false
  def default_language, do: Application.get_env(:eurostatx, :language, :en)
end
