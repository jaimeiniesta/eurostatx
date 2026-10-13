defmodule Eurostatx.DataTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Data
  alias Eurostatx.Error
  alias Explorer.DataFrame, as: DF

  @sdmx3 "sdmx/3.0/data/dataflow/ESTAT/nama_10_gdp/1.0"
  @filters [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"]

  describe "get/2 with SDMX 3.0" do
    test "sends the filters as component filters and requests JSON-stat" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.json"})

      assert {:ok, %{"class" => "dataset", "size" => [1, 1, 1, 2, 4]}} =
               Data.get("nama_10_gdp", filters: @filters, start_period: 2022)

      assert assert_eurostat_request(@sdmx3) == [
               {"c[geo]", "DE,FR"},
               {"c[unit]", "CP_MEUR"},
               {"c[na_item]", "B1GQ"},
               {"c[TIME_PERIOD]", "ge:2022"},
               {"format", "json"}
             ]
    end

    test "sends the key in the path" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.csv"})

      assert {:ok, "STRUCTURE,STRUCTURE_ID," <> _} =
               Data.get("nama_10_gdp", key: "A.CP_MEUR.B1GQ.DE", last_n: 2, format: :csv)

      assert assert_eurostat_request(@sdmx3 <> "/A.CP_MEUR.B1GQ.DE") == [
               {"lastNObservations", "2"},
               {"format", "csvdata"},
               {"formatVersion", "2.0"}
             ]
    end

    test "builds the key from a list, with * for every value" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.json"})

      assert {:ok, _json} = Data.get("nama_10_gdp", key: ["A", :all, nil, ["DE"], 2])
      assert_eurostat_request(@sdmx3 <> "/A.*.*.DE.2")
    end

    test "rejects keys with several values per dimension" do
      assert {:error,
              %Error{type: :option_error, message: "SDMX 3.0 keys accept a single value" <> _}} =
               Data.get("nama_10_gdp", key: ["A", "CP_MEUR", "B1GQ", ["DE", "FR"]])
    end

    test "translates the time options" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.json"})

      for {opts, time} <- [
            {[start_period: 2020, end_period: "2021-Q4"], "ge:2020+le:2021-Q4"},
            {[end_period: ~D[2021-12-31]], "le:2021-12-31"},
            {[time: [2020, 2022]], "2020,2022"},
            {[filters: [TIME_PERIOD: [2020, 2022]]], "2020,2022"}
          ] do
        assert {:ok, _json} = Data.get("nama_10_gdp", opts)
        assert assert_eurostat_request(@sdmx3) == [{"c[TIME_PERIOD]", time}, {"format", "json"}]
      end
    end

    test "rejects incompatible time options" do
      assert {:error, %Error{type: :option_error}} = Data.get("x", time: 2020, start_period: 2019)

      assert {:error, %Error{type: :option_error}} =
               Data.get("x", filters: [time: 2020], end_period: 2021)
    end

    test "translates the formats" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.xml"})

      for {format, params} <- [
            csv_1: [{"format", "csvdata"}, {"formatVersion", "1.0"}],
            tsv: [{"format", "tsv"}],
            xml: [],
            xml_2_1: [{"format", "structurespecificdata"}, {"formatVersion", "2.1"}],
            xml_generic: [{"format", "genericdata"}, {"formatVersion", "2.1"}]
          ] do
        assert {:ok, _body} = Data.get("nama_10_gdp", format: format)
        assert assert_eurostat_request(@sdmx3) == params
      end
    end

    test "translates the detail into attributes and measures" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.csv"})

      for {detail, params} <- [
            full: [],
            data_only: [{"attributes", "none"}, {"measures", "all"}],
            series_keys_only: [{"attributes", "none"}, {"measures", "none"}],
            no_data: [{"attributes", "series"}, {"measures", "none"}]
          ] do
        assert {:ok, _body} = Data.get("nama_10_gdp", detail: detail, format: :tsv)
        assert assert_eurostat_request(@sdmx3) == params ++ [{"format", "tsv"}]
      end
    end

    test "sends the SDMX-CSV options, with the language of the labels" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp_labels_fr.csv"})

      assert {:ok, "STRUCTURE,STRUCTURE_ID,STRUCTURE_NAME,freq,Fréquence" <> _} =
               Data.get("nama_10_gdp",
                 format: :csv,
                 labels: :name,
                 language: :fr,
                 last_update_date: true,
                 return_data: :all
               )

      assert assert_eurostat_request(@sdmx3) == [
               {"format", "csvdata"},
               {"formatVersion", "2.0"},
               {"labels", "name"},
               {"lang", "fr"},
               {"returnLastUpdateDate", "true"},
               {"returnData", "ALL"}
             ]
    end

    test "rejects the options of other formats" do
      assert {:error, %Error{type: :option_error, message: ":labels is only available" <> _}} =
               Data.get("x", labels: :name)

      assert {:error, %Error{type: :option_error, message: ":last_update_date" <> _}} =
               Data.get("x", format: :tsv, last_update_date: true)

      assert {:error, %Error{type: :option_error, message: ":return_data" <> _}} =
               Data.get("x", return_data: :all)

      assert {:error, %Error{type: :option_error, message: ":dimension_at_observation" <> _}} =
               Data.get("x", dimension_at_observation: "geo")

      assert eurostat_requests() == []
    end

    test "validates the options" do
      for opts <- [
            key: 123,
            key: [],
            key: ["A", %{}],
            filters: [{"", "DE"}],
            filters: [geo: [nil]],
            filters: [geo: :de],
            filters: "geo=DE",
            start_period: -1,
            start_period: "20",
            end_period: :today,
            time: [],
            time: ["2020", nil],
            format: :xlsx,
            detail: :everything,
            sdmx_version: "1.0",
            agency: :ecb
          ] do
        assert {:error, %Error{type: :option_error}} = Data.get("x", [opts]), inspect(opts)
      end

      assert eurostat_requests() == []
    end

    test "returns the errors of the API" do
      stub_eurostat({400, {:fixture, "fault_invalid_value.xml"}})

      assert {:error, %Error{type: :invalid_query, code: "150"}} =
               Data.get("nama_10_gdp", filters: [geo: "XX"])
    end

    test "queries Comext datasets on the Comext endpoint" do
      stub_eurostat({413, {:fixture, "fault_too_big.xml"}})

      assert {:error, %Error{type: :too_big}} = Data.get("DS-045409", key: "A.PT")

      assert [%{agency: :comext, endpoint: "sdmx/3.0/data/dataflow/ESTAT/DS-045409/1.0/A.PT"}] =
               eurostat_requests()
    end

    test "waits for asynchronous responses" do
      stub_eurostat(%{
        "sdmx/3.0/data/dataflow/ESTAT/DS-045409/1.0/A.FI.CA.*.2" =>
          {:fixture, "async_queued.xml"},
        "1.0/async/status/91430d7b-0fdc-4dac-9d06-3b7126518120" =>
          {:fixture, "async_status_available.xml"},
        "1.0/async/data/91430d7b-0fdc-4dac-9d06-3b7126518120" => {:fixture, "async_data.csv"}
      })

      assert {:ok, "DATAFLOW," <> _} =
               Data.get("DS-045409", key: ["A", "FI", "CA", :all, "2"], format: :csv)
    end
  end

  describe "get/2 with SDMX 2.1" do
    @sdmx21 "sdmx/2.1/data/nama_10_gdp"

    test "sends the key and the 2.1 parameters" do
      stub_eurostat({:fixture, "sdmx21_data_nama_10_gdp.csv"})

      assert {:ok, "DATAFLOW,LAST UPDATE," <> _} =
               Data.get("nama_10_gdp",
                 sdmx_version: "2.1",
                 key: ["A", "CP_MEUR", :all, ["DE", "FR"]],
                 start_period: 2024,
                 end_period: 2025,
                 first_n: 1,
                 detail: :data_only,
                 format: :csv,
                 return_data: :all
               )

      assert assert_eurostat_request(@sdmx21 <> "/A.CP_MEUR..DE+FR") == [
               {"format", "SDMX-CSV"},
               {"startPeriod", "2024"},
               {"endPeriod", "2025"},
               {"firstNObservations", "1"},
               {"detail", "dataonly"},
               {"returnData", "ALL"}
             ]
    end

    test "translates the formats" do
      stub_eurostat({:fixture, "sdmx21_data_nama_10_gdp_generic.xml"})

      for {format, params} <- [
            json: [{"format", "JSON"}],
            tsv: [{"format", "TSV"}],
            xml: [{"format", "SDMX_2.1_STRUCTURED"}],
            xml_generic: []
          ] do
        assert {:ok, _body} =
                 Data.get("nama_10_gdp", sdmx_version: "2.1", key: "A", format: format)

        assert assert_eurostat_request(@sdmx21 <> "/A") == params
      end
    end

    test "sends a single time period as a range" do
      stub_eurostat({:fixture, "sdmx21_data_nama_10_gdp.csv"})

      assert {:ok, _csv} = Data.get("nama_10_gdp", sdmx_version: "2.1", time: 2024, format: :csv)

      assert assert_eurostat_request(@sdmx21) ==
               [{"format", "SDMX-CSV"}, {"startPeriod", "2024"}, {"endPeriod", "2024"}]

      assert {:error, %Error{type: :option_error}} =
               Data.get("nama_10_gdp", sdmx_version: "2.1", time: [2020, 2024])
    end

    test "builds the key from the filters with the order of the data structure" do
      stub_eurostat(%{
        "sdmx/2.1/dataflow/ESTAT/nama_10_gdp" =>
          {:fixture, "dataflow_nama_10_gdp_children_2_1.xml"},
        "sdmx/2.1/data/nama_10_gdp/.CP_MEUR.B1GQ.DE+FR" =>
          {:fixture, "sdmx21_data_nama_10_gdp.csv"}
      })

      assert {:ok, _csv} =
               Data.get("nama_10_gdp",
                 sdmx_version: "2.1",
                 filters: [GEO: ["DE", "FR"], na_item: "B1GQ", unit: "CP_MEUR"],
                 format: :csv
               )

      assert [{"references", "children"}] =
               assert_eurostat_request("sdmx/2.1/dataflow/ESTAT/nama_10_gdp")

      assert_eurostat_request("sdmx/2.1/data/nama_10_gdp/.CP_MEUR.B1GQ.DE+FR")
    end

    test "rejects filters on unknown dimensions and filters with a key" do
      stub_eurostat({:fixture, "dataflow_nama_10_gdp_children_2_1.xml"})

      assert {:error,
              %Error{type: :option_error, message: "unknown dimensions [\"country\"]" <> _}} =
               Data.get("nama_10_gdp", sdmx_version: "2.1", filters: [country: "DE"])

      assert {:error, %Error{type: :option_error, message: "use either :key or :filters" <> _}} =
               Data.get("nama_10_gdp", sdmx_version: "2.1", filters: [geo: "DE"], key: "A")
    end

    test "is the default for the REDISSTAT agencies, which do not serve SDMX 3.0" do
      stub_eurostat({:fixture, "sdmx21_data_nama_10_gdp.csv"})

      assert {:ok, _csv} = Data.get("LMP_EXPME$HR", agency: :empl, format: :csv)
      assert [%{agency: :empl, endpoint: "sdmx/2.1/data/LMP_EXPME$HR"}] = eurostat_requests()

      assert {:error,
              %Error{type: :option_error, message: "the :empl agency only serves SDMX 2.1" <> _}} =
               Data.get("LMP_EXPME$HR", agency: :empl, sdmx_version: "3.0")
    end
  end

  describe "get_as_data_frame/2" do
    test "returns one row per observation" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.json"})

      df = Data.get_as_data_frame!("nama_10_gdp", filters: @filters, start_period: 2022)

      assert DF.names(df) == ~w(freq unit na_item geo time date value flag)
      assert DF.n_rows(df) == 8
      assert df["time"] |> Explorer.Series.to_list() |> Enum.take(4) == ~w(2022 2023 2024 2025)

      # Always JSON-stat, and the data frame options are not sent
      assert assert_eurostat_request(@sdmx3) |> List.last() == {"format", "json"}
    end

    test "supports the wide shape and labels" do
      stub_eurostat({:fixture, "sdmx3_data_nama_10_gdp.json"})

      assert {:ok, wide} = Data.get_as_data_frame("nama_10_gdp", shape: :wide)
      assert DF.names(wide) == ~w(date DE FR)

      assert {:ok, labelled} = Data.get_as_data_frame("nama_10_gdp", labels: true)
      assert labelled["unit_label"] |> Explorer.Series.first() == "Current prices, million euro"
    end

    test "returns and raises errors" do
      stub_eurostat({404, {:fixture, "fault_not_found.xml"}})

      assert {:error, %Error{type: :not_found}} = Data.get_as_data_frame("nope")
      assert_raise Error, fn -> Data.get_as_data_frame!("nope") end
    end
  end
end
