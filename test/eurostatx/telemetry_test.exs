defmodule Eurostatx.TelemetryTest do
  # Telemetry handlers are global, so these tests can't run concurrently with others
  use Eurostatx.Case, async: false

  import ExUnit.CaptureLog

  alias Eurostatx.Telemetry.Logger, as: TelemetryLogger

  setup context do
    test_pid = self()
    handler_id = "eurostatx-test-#{inspect(context.test)}"

    :telemetry.attach_many(
      handler_id,
      [
        [:eurostatx, :request, :start],
        [:eurostatx, :request, :stop],
        [:eurostatx, :request, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits start and stop events for successful requests" do
    stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

    assert {:ok, _json} = Eurostatx.Statistics.data("nama_10_gdp", last_periods: 1)

    assert_received {:telemetry, [:eurostatx, :request, :start], %{system_time: _},
                     start_metadata}

    assert %{
             api: :statistics,
             agency: :eurostat,
             path: "statistics/1.0/data/nama_10_gdp",
             params: [{"lang", "EN"}, {"lastTimePeriod", "1"}],
             url: url
           } = start_metadata

    assert url ==
             "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/nama_10_gdp?lang=EN&lastTimePeriod=1"

    assert_received {:telemetry, [:eurostatx, :request, :stop], %{duration: duration},
                     stop_metadata}

    assert is_integer(duration)
    assert %{status: 200, result: :ok, api: :statistics} = stop_metadata
  end

  test "includes the error in the stop event" do
    stub_eurostat({404, {:fixture, "fault_not_found.xml"}})

    assert {:error, _error} = Eurostatx.Datasets.get("nope")

    assert_received {:telemetry, [:eurostatx, :request, :stop], _measurements, metadata}

    assert %{status: 404, result: :error, api: :sdmx, error: %Eurostatx.Error{type: :not_found}} =
             metadata
  end

  test "reports queued requests" do
    stub_eurostat({:fixture, "async_queued.xml"})

    assert {:error, %Eurostatx.Error{type: :queued}} =
             Eurostatx.Data.get("DS-045409", format: :csv, async_timeout: 0)

    assert_received {:telemetry, [:eurostatx, :request, :stop], _measurements, metadata}

    assert %{result: :queued, request_id: "91430d7b-0fdc-4dac-9d06-3b7126518120", agency: :comext} =
             metadata
  end

  test "emits an exception event when the request raises" do
    stub_eurostat(fn _conn -> raise "boom" end)

    assert_raise RuntimeError, "boom", fn -> Eurostatx.Catalogue.toc_schema() end

    assert_received {:telemetry, [:eurostatx, :request, :exception], %{duration: _},
                     %{kind: :error, api: :catalogue}}
  end

  describe "Eurostatx.Telemetry.Logger" do
    setup do
      on_exit(fn -> TelemetryLogger.detach() end)
    end

    test "logs successful requests, errors and queued requests" do
      assert :ok = TelemetryLogger.attach(level: :warning)
      assert {:error, :already_exists} = TelemetryLogger.attach()

      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      log = capture_log(fn -> Eurostatx.Statistics.data("nama_10_gdp", last_periods: 1) end)

      assert log =~
               ~s([eurostatx] GET statistics/1.0/data/nama_10_gdp - 200 in )

      assert log =~ ~s/(params: [{"lang", "EN"}, {"lastTimePeriod", "1"}])/

      stub_eurostat({404, {:fixture, "fault_not_found.xml"}})
      log = capture_log(fn -> Eurostatx.Datasets.get("nope") end)
      assert log =~ "[eurostatx] GET sdmx/3.0/structure/dataflow/ESTAT/nope - error in "
      assert log =~ "(HTTP 404) ERR_NOT_FOUND_4"

      stub_eurostat({:fixture, "async_queued.xml"})
      log = capture_log(fn -> Eurostatx.Data.get("DS-045409", format: :csv, async_timeout: 0) end)
      assert log =~ "queued in"
      assert log =~ "(request 91430d7b-0fdc-4dac-9d06-3b7126518120)"
    end

    test "logs exceptions" do
      TelemetryLogger.attach(level: :warning, handler_id: "custom")
      on_exit(fn -> TelemetryLogger.detach("custom") end)

      stub_eurostat(fn _conn -> raise "boom" end)

      log = capture_log(fn -> catch_error(Eurostatx.Catalogue.toc_schema()) end)
      assert log =~ "[eurostatx] GET catalogue/toc/TableOfContent.xsd - exception in"
      assert log =~ "boom"
    end

    test "detach/1 returns an error for unknown handlers" do
      assert {:error, :not_found} = TelemetryLogger.detach("nope")
    end
  end
end
