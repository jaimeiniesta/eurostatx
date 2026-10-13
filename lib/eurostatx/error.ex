defmodule Eurostatx.Error do
  @moduledoc """
  Structured error type returned by every `Eurostatx` function.

  ## Error Types

    - `:not_found` - The requested resource does not exist: unknown dataset,
      code list, file or asynchronous request key. Eurostat answers with an
      HTTP 404, a SOAP fault such as `ERR_NOT_FOUND_4` or `UNKNOWN_REQUEST`.
    - `:invalid_query` - The query was rejected (HTTP 400). For example, a
      dimension value that does not exist in the dataset
      (`INVALID_QUERY_DIMENSION_VALUE`, fault code `150`), a malformed key or
      operator (fault code `140`), or incompatible parameters of the
      Statistics API.
    - `:no_results` - The query is valid but did not match any observation
      (`NO_RESULTS`).
    - `:too_big` - The extraction is above the 5,000,000 cells limit of the
      API (`EXTRACTION_TOO_BIG`, HTTP 413). Add filters to the query.
    - `:queued` - Eurostat queued the request for asynchronous processing and
      the data was not ready within `:async_timeout`. When the API gave a
      request key, it is in `:request_id`: pass it to `Eurostatx.Async.await/2`
      to get the data later.
    - `:async_failed` - An asynchronous request ended with the `ERROR` or
      `EXPIRED` status.
    - `:api_error` - Any other error answered by the API (HTTP 5xx,
      unexpected responses...).
    - `:decode_error` - The response could not be decompressed or decoded.
    - `:request_error` - The HTTP request could not be completed (timeout,
      DNS failure, connection refused...).
    - `:option_error` - The options given to a function were invalid.

  Besides the type and message, the error keeps the HTTP `:status` and the
  Eurostat fault `:code` (`"100"`, `"140"`, `"150"`, `"413"`...) when available.

  `Eurostatx.Error` is an exception, so the bang (`!`) functions raise it directly.
  """

  @type error_type ::
          :not_found
          | :invalid_query
          | :no_results
          | :too_big
          | :queued
          | :async_failed
          | :api_error
          | :decode_error
          | :request_error
          | :option_error

  @type t :: %__MODULE__{
          type: error_type(),
          message: String.t(),
          status: non_neg_integer() | nil,
          code: String.t() | nil,
          request_id: String.t() | nil
        }

  defexception [:type, :message, :status, :code, :request_id]

  @doc false
  @spec new(error_type(), String.t(), keyword()) :: t()
  def new(type, message, fields \\ []) do
    struct!(__MODULE__, [type: type, message: message] ++ fields)
  end

  @impl true
  def message(%__MODULE__{message: message, status: nil}), do: message
  def message(%__MODULE__{message: message, status: status}), do: "(HTTP #{status}) #{message}"
end
