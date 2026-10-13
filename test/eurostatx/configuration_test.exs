defmodule Eurostatx.ConfigurationTest do
  # Changes the application environment, so it can't run concurrently with other tests
  use Eurostatx.Case, async: false

  alias Eurostatx.Client

  setup do
    previous = Application.get_all_env(:eurostatx)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:eurostatx),
          not Keyword.has_key?(previous, key),
          do: Application.delete_env(:eurostatx, key)

      for {key, value} <- previous, do: Application.put_env(:eurostatx, key, value)
    end)
  end

  test ":base_urls overrides the base URL of an agency" do
    Application.put_env(:eurostatx, :base_urls, %{eurostat: "https://example.com/api/"})

    assert Client.base_url(:eurostat) == "https://example.com/api"
    assert Client.base_url(:comext) == "https://ec.europa.eu/eurostat/api/comext/dissemination"
  end

  test ":language sets the default language of the labels" do
    Application.put_env(:eurostatx, :language, :fr)
    stub_eurostat({:fixture, "statistics_nama_10_gdp_fr.json"})

    assert {:ok, _json} = Eurostatx.Statistics.data("nama_10_gdp")
    assert [{"lang", "FR"} | _rest] = assert_eurostat_request("statistics/1.0/data/nama_10_gdp")
  end

  test ":async_timeout sets how long to wait for asynchronous responses" do
    Application.put_env(:eurostatx, :async_timeout, 0)
    stub_eurostat({:fixture, "async_queued.xml"})

    assert {:error, %Eurostatx.Error{type: :queued, request_id: "91430d7b" <> _}} =
             Eurostatx.Data.get("DS-045409", format: :csv)
  end

  test ":req_options are merged into the request" do
    Application.put_env(:eurostatx, :req_options,
      plug: {Req.Test, Eurostatx.Client},
      retry: false,
      headers: [x_test: "1"]
    )

    stub_eurostat({200, "{}"})
    assert {:ok, %{}} = Client.get(["statistics"])
    assert [%{headers: headers}] = eurostat_requests()
    assert {"x-test", "1"} in headers
  end
end
