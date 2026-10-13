defmodule Eurostatx.IntegrationTest do
  @moduledoc """
  Runs Eurostatx against the live Eurostat APIs.

      mix test --include integration

  These tests check invariants (shapes, types, errors...) rather than values,
  since the data changes with every release. Requests are made one at a time,
  as Eurostat asks.
  """

  use ExUnit.Case, async: false

  alias Eurostatx.Error
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @gdp [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"]

  setup_all do
    previous = Application.get_env(:eurostatx, :req_options)
    Application.put_env(:eurostatx, :req_options, [])
    on_exit(fn -> Application.put_env(:eurostatx, :req_options, previous) end)
  end

  describe "data" do
    test "the Statistics API and the SDMX APIs return the same observations" do
      opts = [filters: @gdp, start_period: 2015, end_period: 2020]

      statistics = Eurostatx.Statistics.data_as_data_frame!("nama_10_gdp", opts)
      sdmx_3_0 = Eurostatx.Data.get_as_data_frame!("nama_10_gdp", opts)
      sdmx_2_1 = Eurostatx.Data.get_as_data_frame!("nama_10_gdp", [sdmx_version: "2.1"] ++ opts)

      assert DF.n_rows(statistics) == 12
      assert DF.to_rows(statistics) == DF.to_rows(sdmx_3_0)
      assert DF.to_rows(statistics) == DF.to_rows(sdmx_2_1)
      assert statistics["value"].dtype == {:f, 64}
      assert Series.nil_count(statistics["date"]) == 0
    end

    test "JSON-stat, TSV and SDMX-CSV have the same values" do
      opts = [key: "A.CP_MEUR.B1GQ.DE", start_period: 2010, end_period: 2020]

      {:ok, json} = Eurostatx.Data.get("nama_10_gdp", opts)
      {:ok, tsv} = Eurostatx.Data.get("nama_10_gdp", [format: :tsv] ++ opts)
      {:ok, csv} = Eurostatx.Data.get("nama_10_gdp", [format: :csv] ++ opts)

      from_json = Eurostatx.DataFrame.from_json_stat(json)
      from_tsv = Eurostatx.DataFrame.from_tsv(tsv)
      from_csv = Eurostatx.DataFrame.from_csv(csv)

      assert DF.to_rows(from_json) == DF.to_rows(from_tsv)
      assert Series.to_list(from_json["value"]) == Series.to_list(from_csv["OBS_VALUE"])
      assert Series.to_list(from_json["time"]) == Series.to_list(from_csv["TIME_PERIOD"])
    end

    test "SDMX-ML formats" do
      for format <- [:xml, :xml_2_1, :xml_generic] do
        assert {:ok, "<?xml" <> _} =
                 Eurostatx.Data.get("nama_10_gdp",
                   key: "A.CP_MEUR.B1GQ.DE",
                   last_n: 1,
                   format: format
                 )
      end

      assert {:ok, "<?xml" <> _} =
               Eurostatx.Data.get("nama_10_gdp",
                 key: "A.CP_MEUR.B1GQ.DE",
                 last_n: 1,
                 format: :xml,
                 sdmx_version: "2.1"
               )
    end

    test "quarterly and monthly periods become dates" do
      df =
        Eurostatx.Statistics.data_as_data_frame!("prc_hicp_minr",
          filters: [geo: "EA", unit: "RCH_A", coicop18: "TOTAL"],
          last_periods: 3
        )

      assert DF.n_rows(df) == 3
      assert Enum.all?(Series.to_list(df["date"]), &(&1.day == 1))

      quarterly =
        Eurostatx.Data.get_as_data_frame!("namq_10_gdp",
          filters: [geo: "DE", unit: "CLV_PCH_PRE", s_adj: "SCA", na_item: "B1GQ"],
          last_n: 2
        )

      assert [%Date{}, %Date{}] = Series.to_list(quarterly["date"])
      assert quarterly["time"] |> Series.to_list() |> Enum.all?(&(&1 =~ ~r/^\d{4}-Q[1-4]$/))
    end

    test "errors" do
      assert {:error, %Error{type: :not_found}} = Eurostatx.Statistics.data("nope_nope")
      assert {:error, %Error{type: :not_found}} = Eurostatx.Data.get("nope_nope")

      assert {:error, %Error{type: :invalid_query, code: "150"}} =
               Eurostatx.Data.get("nama_10_gdp", filters: [geo: "XX"])

      assert {:error, %Error{type: :invalid_query}} =
               Eurostatx.Data.get("nama_10_gdp", key: "A.CP_MEUR.B1GQ.DE+FR")

      assert {:error, %Error{type: :too_big}} =
               Eurostatx.Data.get("DS-045409",
                 key: "A.PT...2.QUANTITY_IN_100KG",
                 sdmx_version: "2.1"
               )

      # Unknown values are not errors in the Statistics API: the result is empty
      assert {:ok, %{"value" => empty}} =
               Eurostatx.Statistics.data("nama_10_gdp",
                 filters: [geo: "XX", unit: "CP_MEUR", na_item: "B1GQ"]
               )

      assert empty == %{}
    end
  end

  describe "metadata" do
    test "datasets, structure, availability and values agree" do
      {:ok, summary} =
        with {:ok, json} <- Eurostatx.Datasets.get("nama_10_gdp"),
             do: {:ok, Eurostatx.Datasets.summary(json)}

      {:ok, structure} = Eurostatx.Datasets.structure("nama_10_gdp")
      {:ok, structure_2_1} = Eurostatx.Datasets.structure("nama_10_gdp", sdmx_version: "2.1")
      {:ok, availability} = Eurostatx.Datasets.availability("nama_10_gdp")
      {:ok, values} = Eurostatx.Datasets.values("nama_10_gdp")

      assert summary["id"] == "NAMA_10_GDP"
      assert is_integer(summary["observations"])
      assert %DateTime{} = summary["data_updated_at"]
      assert summary["data_structure"]["version"] == structure["version"]

      assert structure == structure_2_1
      dimensions = Enum.map(structure["dimensions"], & &1["id"])
      assert dimensions == Enum.map(values, & &1["id"])
      assert Enum.sort(Map.keys(availability)) == Enum.sort(["TIME_PERIOD" | dimensions])

      # The values used by the dataset are the available codes, with names
      for dimension <- values do
        codes = Enum.map(dimension["values"], & &1["code"])
        assert Enum.sort(codes) == Enum.sort(availability[dimension["id"]])
        assert Enum.all?(dimension["values"], &is_binary(&1["name"]))
      end
    end

    test "dataset listing and code lists" do
      {:ok, datasets} = Eurostatx.Datasets.list()
      assert length(datasets) > 5_000
      assert Enum.find(datasets, &(&1["id"] == "NAMA_10_GDP"))

      {:ok, codelists} = Eurostatx.Codelists.list()
      assert %{"version" => version} = Enum.find(codelists, &(&1["id"] == "GEO"))

      {:ok, codes} = Eurostatx.Codelists.codes("GEO", version: version, language: :de)
      assert %{"code" => "DE", "name" => "Deutschland"} in codes
    end

    test "raw structure queries" do
      for {type, id, opts} <- [
            {:conceptscheme, "NAMA_10_GDP", []},
            {:constraint, "NAMA_10_GDP", [sdmx_version: "2.1"]},
            {:datastructure, "NAMA_10_GDP", [references: :children]}
          ] do
        assert {:ok, "<?xml" <> _} = Eurostatx.Structure.get(type, id, opts)
      end

      assert {:ok, "P\t" <> _} =
               Eurostatx.Structure.get(:codelist, "FREQ",
                 format: :tsv,
                 sdmx_version: "2.1",
                 language: :fr
               )
    end
  end

  describe "catalogue, files and async" do
    test "table of contents and search" do
      {:ok, toc} = Eurostatx.Catalogue.toc()
      assert length(toc) > 5_000

      assert %{"type" => "dataset", "values" => values} =
               Enum.find(toc, &(&1["code"] == "nama_10_gdp"))

      assert is_integer(values)

      assert {:ok, [_ | _] = results} =
               Eurostatx.Catalogue.search("gross domestic product", toc: toc)

      assert Enum.all?(results, &(&1["type"] in ["dataset", "table"]))
    end

    test "RSS, DCAT and metabase" do
      assert {:ok, %{"items" => [%{"code" => _, "pub_date" => %NaiveDateTime{}} | _]}} =
               Eurostatx.Catalogue.rss()

      assert {:ok, [{"manifest.xml", _} | _]} = Eurostatx.Catalogue.dcat(:updates)

      assert {:ok, %{"nama_10_gdp" => %{"geo" => [_ | _]}}} =
               Eurostatx.Catalogue.metabase(datasets: ["nama_10_gdp"])
    end

    test "files" do
      {:ok, [%{"Code" => _, "Data download url (csv)" => "https://" <> _} | _]} =
        Eurostatx.Files.inventory()

      {:ok, [%{"path" => "metadata/" <> _ = path} | _]} = Eurostatx.Files.list("metadata")
      assert {:ok, <<"PK", _rest::binary>>} = Eurostatx.Files.download(path)

      assert {:error, %Error{type: :not_found}} =
               Eurostatx.Files.download("metadata/nope_nope.zip")
    end

    test "asynchronous requests" do
      # Different reporters or partners make Eurostat extract the data again
      key =
        "A.#{Enum.random(~w(AT BE DK FI IE PT SE))}.#{Enum.random(~w(CA NO CH JP))}..2.SUPPLEMENTARY_QUANTITY"

      case Eurostatx.Data.get("DS-045409",
             key: key,
             sdmx_version: "2.1",
             format: :csv,
             async_timeout: 0
           ) do
        {:error, %Error{type: :queued, request_id: id}} ->
          assert {:ok, status} = Eurostatx.Async.status(id, agency: :comext)
          assert status in [:submitted, :processing, :available]

          assert {:ok, "DATAFLOW," <> _} =
                   Eurostatx.Async.await(id, agency: :comext, timeout: 300_000)

        # Already cached by Eurostat
        {:ok, csv} ->
          assert "DATAFLOW," <> _ = csv
      end

      assert {:error, %Error{type: :not_found}} =
               Eurostatx.Async.status("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "other agencies" do
    test "Comext" do
      {:ok, datasets} = Eurostatx.Datasets.list(agency: :comext)
      assert Enum.all?(datasets, &String.starts_with?(&1["id"], "DS-"))
    end

    test "REDISSTAT agencies serve SDMX 2.1 and the Statistics API" do
      {:ok, [%{"id" => id} | _]} = Eurostatx.Datasets.list(agency: :empl)

      {:ok, structure} = Eurostatx.Datasets.structure(id, agency: :empl)
      assert [_ | _] = structure["dimensions"]

      df = Eurostatx.Statistics.data_as_data_frame!(id, agency: :empl, last_periods: 1)
      assert DF.n_rows(df) > 0
      assert Series.nil_count(df["date"]) == 0

      assert {:ok, "DATAFLOW," <> _} =
               Eurostatx.Data.get(id, agency: :empl, last_n: 1, format: :csv)
    end
  end
end
