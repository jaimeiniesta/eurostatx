defmodule Eurostatx.AsyncTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Async
  alias Eurostatx.Error

  @id "91430d7b-0fdc-4dac-9d06-3b7126518120"
  @status "1.0/async/status/" <> @id
  @data "1.0/async/data/" <> @id

  describe "status/2" do
    test "parses the status" do
      stub_eurostat(%{
        @status => [
          {:fixture, "async_status_submitted.xml"},
          {:fixture, "async_status_available.xml"}
        ]
      })

      assert {:ok, :submitted} = Async.status(@id, agency: :comext)
      assert {:ok, :available} = Async.status(@id, agency: :comext)
      assert [%{agency: :comext}, %{agency: :comext}] = eurostat_requests()
    end

    test "returns not found for unknown keys" do
      stub_eurostat({400, {:fixture, "async_unknown_request.xml"}})

      assert {:error, %Error{type: :not_found, message: "UNKNOWN_REQUEST: Unknown request."}} =
               Async.status("98de05ea-540a-43d3-903b-7c9e14faf808")
    end

    test "returns an error for unexpected responses" do
      stub_eurostat({200, "<xml/>"})
      assert {:error, %Error{type: :api_error}} = Async.status(@id)
    end
  end

  describe "data/2" do
    test "returns the data" do
      stub_eurostat({:fixture, "async_data.csv"})

      assert {:ok, "DATAFLOW,LAST UPDATE," <> _} = Async.data(@id, agency: :comext)
      assert_eurostat_request(@data)
    end

    test "decodes JSON-stat unless decode: :text" do
      stub_eurostat({:gzip, {:fixture, "sdmx3_data_nama_10_gdp.json"}})

      assert {:ok, %{"class" => "dataset"}} = Async.data(@id)
      assert {:ok, "{" <> _} = Async.data(@id, decode: :text)
    end

    test "returns a :queued error with the request id while the data is not ready" do
      stub_eurostat({400, {:fixture, "async_data_not_ready.xml"}})

      assert {:error,
              %Error{type: :queued, request_id: @id, message: "DATA_NOT_YET_AVAILABLE" <> _}} =
               Async.data(@id)
    end
  end

  describe "await/2" do
    test "polls the status until the data is available" do
      stub_eurostat(%{
        @status => [
          {:fixture, "async_status_submitted.xml"},
          {:fixture, "async_status_submitted.xml"},
          {:fixture, "async_status_available.xml"}
        ],
        @data => {:fixture, "async_data.csv"}
      })

      assert {:ok, "DATAFLOW," <> _} = Async.await(@id, agency: :comext, interval: 0)
      assert Enum.map(eurostat_requests(), & &1.endpoint) == [@status, @status, @status, @data]
    end

    test "returns a :queued error after the timeout" do
      stub_eurostat({:fixture, "async_status_submitted.xml"})

      assert {:error, %Error{type: :queued, request_id: @id}} =
               Async.await(@id, timeout: 20, interval: 5)
    end

    test "returns :async_failed for expired requests" do
      expired = String.replace(fixture("async_status_available.xml"), "AVAILABLE", "EXPIRED")
      stub_eurostat({200, expired})

      assert {:error, %Error{type: :async_failed, request_id: @id, message: message}} =
               Async.await(@id)

      assert message =~ "expired"
    end

    test "returns not found for unknown requests" do
      stub_eurostat({400, {:fixture, "async_unknown_request.xml"}})
      assert {:error, %Error{type: :not_found, request_id: @id}} = Async.await(@id)
    end
  end
end
