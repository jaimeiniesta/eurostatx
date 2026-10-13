defmodule Eurostatx.Case do
  @moduledoc """
  Test case for code that talks to the Eurostat APIs.

  Requests are routed to `Req.Test` (see `config/test.exs`) and answered with
  real responses captured from the APIs (`test/support/fixtures`). Every
  request is reported to the test process so tests can assert on the exact
  endpoint, agency and query parameters.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  @fixtures_path Path.expand("fixtures", __DIR__)

  # Path prefixes of the base URLs of every agency (see Eurostatx.Client)
  @prefixes [
    {"/eurostat/api/comext/dissemination/", :comext},
    {"/eurostat/api/dissemination/", :eurostat},
    {"/ecfin/redisstat/api/dissemination/", :ecfin},
    {"/empl/redisstat/api/dissemination/", :empl},
    {"/grow/redisstat/api/dissemination/", :grow},
    {"/taxation_customs/redisstat/api/dissemination/", :taxud}
  ]

  using do
    quote do
      import Eurostatx.Case
    end
  end

  @doc "Raw body of a fixture (the name includes the extension)."
  def fixture(name), do: File.read!(Path.join(@fixtures_path, name))

  @doc "Decoded JSON fixture."
  def fixture!(name), do: name |> fixture() |> JSON.decode!()

  @doc """
  Stubs the Eurostat APIs.

  `response` can be:

    - `{:fixture, name}` - 200 with the body of the fixture
    - `{:gzip, response}` - the response with its body gzipped, without a
      `Content-Encoding` header, as Eurostat sends SDMX responses
    - `{status, {:fixture, name}}` - the given status and fixture
    - `{status, body}` - the given status and raw body
    - a map of `"endpoint" => response` to route by endpoint (the path
      relative to the base URL), e.g.
      `%{"sdmx/2.1/dataflow/ESTAT/NAMA_10_GDP" => {:fixture, "..."}}`. The value
      can also be a list of responses, returned in order (the last one is
      repeated), to simulate polling.
    - a `fun(conn)` plug
  """
  def stub_eurostat(response) do
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(Eurostatx.Client, fn conn ->
      {agency, endpoint} = endpoint(conn.request_path)

      request = %{
        host: conn.host,
        path: conn.request_path,
        agency: agency,
        endpoint: endpoint,
        params: conn.query_string |> URI.query_decoder() |> Enum.to_list(),
        headers: conn.req_headers
      }

      send(test_pid, {:eurostat_request, request})
      respond(conn, response, request, counter)
    end)
  end

  @doc """
  Asserts that a request was made to `endpoint` (e.g.
  `"statistics/1.0/data/nama_10_gdp"`) and returns its query params as a list
  of `{key, value}` string tuples.
  """
  def assert_eurostat_request(endpoint) do
    assert_received {:eurostat_request, %{endpoint: ^endpoint} = request}
    request.params
  end

  @doc "Returns every request received so far, in order."
  def eurostat_requests(acc \\ []) do
    receive do
      {:eurostat_request, request} -> eurostat_requests([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp respond(conn, {:fixture, name}, _request, _counter),
    do: send_body(conn, 200, fixture(name), content_type(name))

  defp respond(conn, {:gzip, response}, request, counter) do
    conn
    |> Plug.Conn.register_before_send(fn conn ->
      %{conn | resp_body: :zlib.gzip(conn.resp_body)}
    end)
    |> respond(response, request, counter)
  end

  defp respond(conn, {status, {:fixture, name}}, _request, _counter),
    do: send_body(conn, status, fixture(name), content_type(name))

  defp respond(conn, {status, body}, _request, _counter) when is_integer(status),
    do: send_body(conn, status, body, "application/json")

  defp respond(conn, fun, _request, _counter) when is_function(fun, 1), do: fun.(conn)

  defp respond(conn, routes, %{endpoint: endpoint} = request, counter) when is_map(routes) do
    case Map.fetch(routes, endpoint) do
      {:ok, responses} when is_list(responses) ->
        index =
          Agent.get_and_update(
            counter,
            &{Map.get(&1, endpoint, 0), Map.update(&1, endpoint, 1, fn n -> n + 1 end)}
          )

        respond(conn, Enum.at(responses, index, List.last(responses)), request, counter)

      {:ok, response} ->
        respond(conn, response, request, counter)

      :error ->
        send_body(conn, 500, "Unexpected request in test: #{endpoint}", "text/plain")
    end
  end

  defp send_body(conn, status, body, content_type) do
    conn
    |> Plug.Conn.put_resp_content_type(content_type, nil)
    |> Plug.Conn.send_resp(status, body)
  end

  @content_types %{
    ".json" => "application/json",
    ".xml" => "application/xml",
    ".rss" => "application/xml",
    ".xsd" => "application/xml",
    ".csv" => "text/csv",
    ".tsv" => "text/tab-separated-values",
    ".txt" => "text/plain",
    ".html" => "text/html"
  }

  defp content_type(name),
    do: Map.get(@content_types, Path.extname(name), "application/octet-stream")

  # "/eurostat/api/dissemination/statistics/1.0/data/X" -> {:eurostat, "statistics/1.0/data/X"}
  defp endpoint(path) do
    Enum.find_value(@prefixes, {nil, path}, fn {prefix, agency} ->
      if String.starts_with?(path, prefix), do: {agency, String.replace_prefix(path, prefix, "")}
    end)
  end
end
