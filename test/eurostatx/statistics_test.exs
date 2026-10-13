defmodule Eurostatx.StatisticsTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Error
  alias Eurostatx.Statistics
  alias Explorer.DataFrame, as: DF

  @endpoint "statistics/1.0/data/nama_10_gdp"
  @filters [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"]

  describe "data/2" do
    test "requests the dataset with filters and the language" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      assert {:ok, %{"class" => "dataset", "id" => ["freq", "unit", "na_item", "geo", "time"]}} =
               Statistics.data("nama_10_gdp", filters: @filters, last_periods: 3)

      assert assert_eurostat_request(@endpoint) == [
               {"lang", "EN"},
               {"geo", "DE"},
               {"geo", "FR"},
               {"unit", "CP_MEUR"},
               {"na_item", "B1GQ"},
               {"lastTimePeriod", "3"}
             ]
    end

    test "accepts maps of filters and integer values" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      assert {:ok, _json} =
               Statistics.data("nama_10_gdp", filters: %{"geo" => "DE", "time" => 2024})

      assert [{"lang", "EN"} | filters] = assert_eurostat_request(@endpoint)
      assert Enum.sort(filters) == [{"geo", "DE"}, {"time", "2024"}]
    end

    test "translates the time options" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      assert {:ok, _json} = Statistics.data("nama_10_gdp", time: [2020, "2022"], language: :de)

      assert assert_eurostat_request(@endpoint) == [
               {"lang", "DE"},
               {"time", "2020"},
               {"time", "2022"}
             ]

      assert {:ok, _json} =
               Statistics.data("nama_10_gdp", start_period: ~D[2020-01-01], end_period: "2022")

      assert assert_eurostat_request(@endpoint) == [
               {"lang", "EN"},
               {"sinceTimePeriod", "2020-01-01"},
               {"untilTimePeriod", "2022"}
             ]
    end

    test "sends one geoLevel per level" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      assert {:ok, _json} = Statistics.data("nama_10_gdp", geo_level: [:nuts1, :nuts2, :nuts1])

      assert assert_eurostat_request(@endpoint) ==
               [{"lang", "EN"}, {"geoLevel", "nuts1"}, {"geoLevel", "nuts2"}]

      assert {:ok, _json} = Statistics.data("nama_10_gdp", geo_level: :country)
      assert {"geoLevel", "country"} in assert_eurostat_request(@endpoint)
    end

    test "rejects incompatible time filters" do
      for opts <- [
            [time: 2020, last_periods: 2],
            [start_period: 2020, last_periods: 2],
            [time: 2020, end_period: 2022],
            [filters: [time: 2020], start_period: 2019],
            [filters: [TIME_PERIOD: 2020], last_periods: 1]
          ] do
        assert {:error, %Error{type: :option_error, message: "only one kind of time filter" <> _}} =
                 Statistics.data("nama_10_gdp", opts)
      end

      assert eurostat_requests() == []
    end

    test "rejects geo_level with a geo filter" do
      assert {:error, %Error{type: :option_error, message: ":geo_level and a geo filter" <> _}} =
               Statistics.data("nama_10_gdp", filters: [GEO: "DE"], geo_level: :country)
    end

    test "validates the options" do
      assert {:error, %Error{type: :option_error}} = Statistics.data("x", geo_level: :planet)
      assert {:error, %Error{type: :option_error}} = Statistics.data("x", filters: [geo: []])
      assert {:error, %Error{type: :option_error}} = Statistics.data("x", filters: "geo=DE")

      assert {:error, %Error{type: :option_error}} =
               Statistics.data("x", start_period: "last year")

      assert {:error, %Error{type: :option_error}} = Statistics.data("x", language: :es)
      assert {:error, %Error{type: :option_error}} = Statistics.data("x", last_periods: 0)
    end

    test "queries Comext datasets on the Comext endpoint" do
      stub_eurostat({413, {:fixture, "statistics_error_too_big.json"}})

      assert {:error, %Error{type: :too_big}} = Statistics.data("DS-045409")
      assert [%{agency: :comext, endpoint: "statistics/1.0/data/DS-045409"}] = eurostat_requests()
    end

    test "queries the REDISSTAT agencies" do
      stub_eurostat({:fixture, "statistics_lmp_expme_hr.json"})

      assert {:ok, %{"source" => "EMPL"}} = Statistics.data("LMP_EXPME$HR", agency: :empl)

      assert [%{agency: :empl, endpoint: "statistics/1.0/data/LMP_EXPME$HR"}] =
               eurostat_requests()
    end

    test "returns the errors of the API" do
      stub_eurostat({404, {:fixture, "statistics_error_not_found.json"}})
      assert {:error, %Error{type: :not_found}} = Statistics.data("nope")
    end
  end

  describe "data_as_data_frame/2" do
    test "returns one row per observation" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      df = Statistics.data_as_data_frame!("nama_10_gdp", filters: @filters, last_periods: 3)

      assert DF.names(df) == ~w(freq unit na_item geo time date value flag)
      assert df["geo"] |> Explorer.Series.to_list() == ~w(DE DE DE FR FR FR)
      assert df["date"] |> Explorer.Series.to_list() |> hd() == ~D[2023-01-01]
      assert df["value"] |> Explorer.Series.to_list() |> hd() == 4_254_930.0
      assert df["flag"] |> Explorer.Series.to_list() == ["p", "p", "p", nil, "p", "p"]

      # The data frame options are not sent to the API
      assert {"lastTimePeriod", "3"} in assert_eurostat_request(@endpoint)
    end

    test "adds labels in the requested language" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp_fr.json"})

      df = Statistics.data_as_data_frame!("nama_10_gdp", labels: true, language: :fr)

      assert "geo_label" in DF.names(df)
      assert df["geo_label"] |> Explorer.Series.to_list() |> hd() == "Allemagne"
    end

    test "pivots to one column per series" do
      stub_eurostat({:fixture, "statistics_nama_10_gdp.json"})

      df =
        Statistics.data_as_data_frame!("nama_10_gdp", shape: :wide, rename: %{"FR" => "france"})

      assert DF.to_columns(df, atom_keys: true) == %{
               date: [~D[2023-01-01], ~D[2024-01-01], ~D[2025-01-01]],
               DE: [4_254_930.0, 4_386_940.0, 4_529_710.0],
               france: [2_833_826.4, 2_935_236.2, 2_991_055.9]
             }
    end

    test "uses the time dimension of the REDISSTAT datasets (TIME_PERIOD)" do
      stub_eurostat({:fixture, "statistics_lmp_expme_hr.json"})

      df = Statistics.data_as_data_frame!("LMP_EXPME$HR", agency: :empl)

      assert DF.names(df) == ~w(FREQ GEO UNIT LMP_TYPE EXPTYPE time date value flag)
      assert Explorer.Series.nil_count(df["date"]) == 0
    end

    test "returns an empty data frame for values that do not exist" do
      stub_eurostat({:fixture, "statistics_empty.json"})

      assert {:ok, df} = Statistics.data_as_data_frame("nama_10_gdp", filters: [geo: "XX"])
      assert DF.n_rows(df) == 0
      assert "geo" in DF.names(df)
    end

    test "returns and raises errors" do
      stub_eurostat({404, {:fixture, "statistics_error_not_found.json"}})

      assert {:error, %Error{type: :not_found}} = Statistics.data_as_data_frame("nope")
      assert_raise Error, ~r/ERR_NOT_FOUND/, fn -> Statistics.data_as_data_frame!("nope") end
    end
  end
end
