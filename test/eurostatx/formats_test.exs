defmodule Eurostatx.FormatsTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.DataFrame
  alias Eurostatx.JSONStat
  alias Eurostatx.Period
  alias Eurostatx.TSV
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series

  doctest Eurostatx.Period
  doctest Eurostatx.JSONStat
  doctest Eurostatx.TSV
  doctest Eurostatx.DataFrame

  describe "Period.to_date/1" do
    test "supports every period of the SDMX and ISO 8601 notations" do
      for {period, date} <- [
            {"2015", ~D[2015-01-01]},
            {"2015-A1", ~D[2015-01-01]},
            {"2015-S1", ~D[2015-01-01]},
            {"2015-Q4", ~D[2015-10-01]},
            {"2015-T3", ~D[2015-09-01]},
            {"2015-02", ~D[2015-02-01]},
            {"2015-M12", ~D[2015-12-01]},
            {"2015-W01", ~D[2014-12-29]},
            {"2020-W53", ~D[2020-12-28]},
            {"2015-12-31", ~D[2015-12-31]},
            {"2015-D032", ~D[2015-02-01]},
            {" 2015-q2 ", ~D[2015-04-01]}
          ] do
        assert Period.to_date(period) == date, "#{period}"
      end
    end

    test "returns nil for invalid periods" do
      for period <- [
            "2015-Q5",
            "2015-13",
            "2015-W54",
            "2015-D366",
            "2015-02-30",
            "abcd",
            "",
            nil,
            2015
          ] do
        assert Period.to_date(period) == nil, inspect(period)
      end
    end
  end

  describe "JSONStat" do
    test "converts the Statistics API responses" do
      records = "statistics_nama_10_gdp.json" |> fixture!() |> JSONStat.to_records(labels: true)

      assert length(records) == 6

      assert hd(records) == %{
               "freq" => "A",
               "freq_label" => "Annual",
               "unit" => "CP_MEUR",
               "unit_label" => "Current prices, million euro",
               "na_item" => "B1GQ",
               "na_item_label" => "Gross domestic product at market prices",
               "geo" => "DE",
               "geo_label" => "Germany",
               "time" => "2023",
               "value" => 4_254_930.0,
               "flag" => "p",
               "flag_label" => "provisional"
             }

      assert %{"geo" => "FR", "time" => "2023", "value" => 2_833_826.4, "flag" => nil} =
               Enum.at(records, 3)
    end

    test "supports dense values, a single status and arrays of codes" do
      json = %{
        "id" => ["geo", "time"],
        "size" => [1, 3],
        "role" => %{"time" => ["time"]},
        "dimension" => %{
          "geo" => %{"category" => %{"label" => %{"DE" => "Germany"}}},
          "time" => %{"category" => %{"index" => ["2023", "2024", "2025"]}}
        },
        "value" => [1, nil, 3.5],
        "status" => "e"
      }

      assert JSONStat.to_records(json) == [
               %{"geo" => "DE", "time" => "2023", "value" => 1.0, "flag" => "e"},
               %{"geo" => "DE", "time" => "2024", "value" => nil, "flag" => "e"},
               %{"geo" => "DE", "time" => "2025", "value" => 3.5, "flag" => "e"}
             ]
    end

    test "renames the time dimension of the REDISSTAT datasets" do
      json = fixture!("statistics_lmp_expme_hr.json")

      assert [%{"time" => _, "EXPTYPE" => "XTOT"} = record | _] = JSONStat.to_records(json)
      refute Map.has_key?(record, "TIME_PERIOD")

      assert %{"id" => "TIME_PERIOD", "role" => "time"} =
               json |> JSONStat.dimensions() |> List.last()
    end

    test "returns no records for empty datasets" do
      assert "statistics_empty.json" |> fixture!() |> JSONStat.to_records() == []
      assert JSONStat.to_records(%{}) == []
    end
  end

  describe "TSV" do
    test "parses the TSV of the SDMX APIs" do
      records = TSV.parse(fixture("sdmx3_data_nama_10_gdp.tsv"))

      assert length(records) == 8

      assert hd(records) == %{
               "freq" => "A",
               "unit" => "CP_MEUR",
               "na_item" => "B1GQ",
               "geo" => "DE",
               "time" => "2022",
               "value" => 4_010_630.0,
               "flag" => nil
             }

      assert %{"time" => "2023", "flag" => "p"} = Enum.at(records, 1)
    end

    test "skips the values that are not available" do
      records = TSV.parse(fixture("sdmx21_data_demo_gind_all.tsv"))

      assert Enum.map(records, &{&1["indic_de"], &1["geo"], &1["time"]}) == [
               {"NATT", "FR", "2020"},
               {"NATT", "FR", "2021"},
               {"POPTRT", "FR", "2020"},
               {"POPTRT", "FR", "2021"}
             ]
    end

    test "parses empty bodies" do
      assert TSV.parse("") == []
    end
  end

  describe "DataFrame" do
    test "from_json_stat/2 builds a typed long data frame" do
      df = "sdmx3_data_nama_10_gdp.json" |> fixture!() |> DataFrame.from_json_stat()

      assert DF.dtypes(df) == %{
               "freq" => :string,
               "unit" => :string,
               "na_item" => :string,
               "geo" => :string,
               "time" => :string,
               "date" => :date,
               "value" => {:f, 64},
               "flag" => :string
             }

      assert DF.n_rows(df) == 8
    end

    test "from_tsv/1 and from_json_stat/2 give the same observations" do
      from_tsv = DataFrame.from_tsv(fixture("sdmx3_data_nama_10_gdp.tsv"))
      from_json = DataFrame.from_json_stat(fixture!("sdmx3_data_nama_10_gdp.json"))

      assert DF.to_rows(from_tsv) == DF.to_rows(from_json)
    end

    test "from_csv/1 loads SDMX-CSV with float values" do
      df = DataFrame.from_csv(fixture("sdmx21_data_nama_10_gdp.csv"))

      assert DF.names(df) ==
               ["DATAFLOW", "LAST UPDATE"] ++
                 ~w(freq unit na_item geo TIME_PERIOD OBS_VALUE OBS_FLAG CONF_STATUS)

      assert df["OBS_VALUE"].dtype == {:f, 64}
      assert df["TIME_PERIOD"] |> Series.to_list() == ~w(2024 2025 2024 2025)
    end

    test "from_csv/1 loads SDMX-CSV 2.0 with labels" do
      df = DataFrame.from_csv(fixture("sdmx3_data_nama_10_gdp_labels_fr.csv"))

      assert "Entité géopolitique (déclarante)" in DF.names(df)
      assert df["OBS_VALUE"] |> Series.first() == 4_010_630.0
    end

    test "to_wide/2 names the series after the dimensions that vary" do
      long = DataFrame.from_json_stat(fixture!("sdmx3_data_nama_10_gdp.json"))

      wide = DataFrame.to_wide(long)
      assert DF.names(wide) == ~w(date DE FR)
      assert DF.n_rows(wide) == 4

      single = long |> DF.filter_with(&Series.equal(&1["geo"], "DE")) |> DataFrame.to_wide()
      assert DF.names(single) == ~w(date value)
    end

    test "to_wide/2 indexes by time when there are no dates" do
      long =
        DF.new(
          [geo: ["DE"], time: ["2020-2024"], date: [nil], value: [1.0], flag: [nil]],
          dtypes: [date: :date]
        )

      assert long |> DataFrame.to_wide() |> DF.names() == ~w(time value)
    end

    test "to_wide/2 with an empty data frame" do
      empty = DataFrame.from_json_stat(fixture!("statistics_empty.json"))
      assert empty |> DataFrame.to_wide() |> DF.names() == ["date"]
    end

    test "from_records/1 flattens nested maps and encodes lists" do
      df =
        DataFrame.from_records([
          %{"id" => "A", "data_structure" => %{"id" => "X"}, "tags" => ["a"], "n" => 1},
          %{"id" => "B", "data_structure" => nil, "n" => 2.5, "date" => ~D[2026-01-01]}
        ])

      assert DF.names(df) |> Enum.sort() == ~w(data_structure data_structure.id date id n tags)
      assert df["n"] |> Series.to_list() == [1.0, 2.5]
      assert df["tags"] |> Series.to_list() == [~s(["a"]), nil]
      assert df["date"].dtype == :date
    end

    test "from_records/1 converts mixed columns to strings" do
      df = DataFrame.from_records([%{"x" => 1}, %{"x" => "a"}, %{"x" => true}])
      assert df["x"] |> Series.to_list() == ["1", "a", "true"]
    end
  end
end
