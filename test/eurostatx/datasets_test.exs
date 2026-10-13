defmodule Eurostatx.DatasetsTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Datasets
  alias Eurostatx.Error

  doctest Eurostatx.Datasets, only: [summary: 1]

  describe "list/1" do
    test "lists the dataflows of the SDMX 2.1 API in JSON, summarized" do
      stub_eurostat({:fixture, "dataflows_all.json"})

      assert {:ok, datasets} = Datasets.list(language: :de)

      assert assert_eurostat_request("sdmx/2.1/dataflow/ESTAT/all") ==
               [{"format", "JSON"}, {"lang", "de"}]

      assert %{
               "id" => "NAMA_10_GDP",
               "agency" => "ESTAT",
               "version" => "1.0",
               "type" => "DATASET",
               "data_structure" => %{"id" => "NAMA_10_GDP", "agency" => "ESTAT"},
               "oldest_period" => "1975",
               "doi" => "10.2908/NAMA_10_GDP",
               "source" => "Eurostat"
             } = Enum.find(datasets, &(&1["id"] == "NAMA_10_GDP"))

      assert Enum.all?(datasets, &is_integer(&1["observations"]))
      assert Enum.all?(datasets, &match?(%DateTime{}, &1["data_updated_at"]))
    end

    test "lists the datasets of other agencies" do
      stub_eurostat({:fixture, "dataflows_all.json"})

      assert {:ok, _datasets} = Datasets.list(agency: :comext)
      assert [%{agency: :comext, endpoint: "sdmx/2.1/dataflow/ESTAT/all"}] = eurostat_requests()

      assert {:ok, _datasets} = Datasets.list(agency: :grow)
      assert [%{agency: :grow, endpoint: "sdmx/2.1/dataflow/GROW/all"}] = eurostat_requests()
    end
  end

  describe "get/2" do
    test "gets the dataflow in JSON with SDMX 3.0" do
      stub_eurostat({:fixture, "dataflow_nama_10_gdp.json"})

      assert {:ok, %{"class" => "dataset", "extension" => %{"id" => "NAMA_10_GDP"}}} =
               Datasets.get("nama_10_gdp")

      assert assert_eurostat_request("sdmx/3.0/structure/dataflow/ESTAT/nama_10_gdp") ==
               [{"format", "JSON"}, {"lang", "en"}]
    end

    test "gets the dataflow with SDMX 2.1 in French" do
      stub_eurostat({:fixture, "dataflow_nama_10_gdp_fr.json"})

      assert {:ok, %{"label" => "Produit intérieur brut" <> _}} =
               Datasets.get("nama_10_gdp", sdmx_version: "2.1", language: :fr)

      assert [{"format", "JSON"}, {"lang", "fr"}] =
               assert_eurostat_request("sdmx/2.1/dataflow/ESTAT/nama_10_gdp")
    end

    test "returns not found errors" do
      stub_eurostat({404, {:fixture, "fault_not_found.xml"}})
      assert {:error, %Error{type: :not_found}} = Datasets.get("nope")
    end
  end

  describe "summary/1" do
    test "summarizes the annotations of a dataflow" do
      summary = "dataflow_nama_10_gdp.json" |> fixture!() |> Datasets.summary()

      assert summary == %{
               "id" => "NAMA_10_GDP",
               "label" =>
                 "Gross domestic product (GDP) and main components (output, expenditure and income) - annual data",
               "agency" => "ESTAT",
               "version" => "1.0",
               "type" => "DATASET",
               "data_structure" => %{
                 "id" => "NAMA_10_GDP",
                 "agency" => "ESTAT",
                 "version" => "138.0"
               },
               "observations" => 1_084_124,
               "oldest_period" => "1975",
               "latest_period" => "2025",
               "data_updated_at" => ~U[2026-10-09 21:00:00Z],
               "structure_updated_at" => ~U[2026-09-08 09:00:00Z],
               "created_at" => ~U[2014-09-04 12:58:03Z],
               "metadata_html" =>
                 "https://ec.europa.eu/eurostat/cache/metadata/en/nama_10_gdp_esms.htm",
               "metadata_sdmx" =>
                 "https://ec.europa.eu/eurostat/api/dissemination/files?file=metadata/nama_10_gdp_esms.sdmx.zip",
               "doi" => "10.2908/NAMA_10_GDP",
               "source" => "Eurostat"
             }
    end

    test "tolerates missing annotations" do
      assert %{"id" => nil, "observations" => nil, "data_updated_at" => nil} =
               Datasets.summary(%{})
    end
  end

  describe "structure/2" do
    test "parses the data structure of the dataflow" do
      stub_eurostat({:fixture, "dataflow_nama_10_gdp_children_3_0.xml"})

      assert {:ok, structure} = Datasets.structure("nama_10_gdp")

      assert [{"references", "children"}] =
               assert_eurostat_request("sdmx/3.0/structure/dataflow/ESTAT/nama_10_gdp")

      assert %{
               "id" => "NAMA_10_GDP",
               "agency" => "ESTAT",
               "version" => "138.0",
               "time_dimension" => "TIME_PERIOD",
               "measures" => ["OBS_VALUE"]
             } = structure

      assert Enum.map(structure["dimensions"], &{&1["id"], &1["position"]}) ==
               [{"freq", 1}, {"unit", 2}, {"na_item", 3}, {"geo", 4}]

      assert hd(structure["dimensions"]) == %{
               "id" => "freq",
               "position" => 1,
               "concept" => %{
                 "agency" => "ESTAT",
                 "id" => "NAMA_10_GDP",
                 "version" => "118.1",
                 "item" => "freq"
               },
               "codelist" => %{
                 "agency" => "ESTAT",
                 "id" => "FREQ",
                 "version" => "3.9",
                 "item" => nil
               }
             }

      assert [%{"id" => "OBS_FLAG", "attached_to" => "observation"}, %{"id" => "CONF_STATUS"}] =
               structure["attributes"]
    end

    test "parses SDMX 2.1 references into the same structure" do
      stub_eurostat(%{
        "sdmx/3.0/structure/dataflow/ESTAT/nama_10_gdp" =>
          {:fixture, "dataflow_nama_10_gdp_children_3_0.xml"},
        "sdmx/2.1/dataflow/ESTAT/nama_10_gdp" =>
          {:fixture, "dataflow_nama_10_gdp_children_2_1.xml"}
      })

      assert {:ok, sdmx_3_0} = Datasets.structure("nama_10_gdp")
      assert {:ok, sdmx_2_1} = Datasets.structure("nama_10_gdp", sdmx_version: "2.1")
      assert sdmx_3_0 == sdmx_2_1
    end

    test "reads data structures with other ids (REDISSTAT)" do
      stub_eurostat({:fixture, "dataflow_lmp_expme_hr_children_2_1.xml"})

      assert {:ok, %{"id" => "LMP_EXP", "agency" => "EMPL", "dimensions" => dimensions}} =
               Datasets.structure("LMP_EXPME$HR", agency: :empl)

      assert Enum.map(dimensions, & &1["id"]) == ~w(FREQ GEO UNIT LMP_TYPE EXPTYPE)

      assert [%{agency: :empl, endpoint: "sdmx/2.1/dataflow/EMPL/LMP_EXPME$HR"}] =
               eurostat_requests()
    end

    test "returns an error when there is no data structure" do
      stub_eurostat({:fixture, "codelists_stubs.xml"})
      assert {:error, %Error{type: :not_found}} = Datasets.structure("nama_10_gdp")
    end
  end

  describe "availability/2" do
    test "parses the data constraint (SDMX 3.0)" do
      stub_eurostat({:fixture, "dataconstraint_nama_10_gdp.xml"})

      assert {:ok, availability} = Datasets.availability("nama_10_gdp")
      assert_eurostat_request("sdmx/3.0/structure/dataconstraint/ESTAT/nama_10_gdp")

      assert Map.keys(availability) |> Enum.sort() == ~w(TIME_PERIOD freq geo na_item unit)
      assert availability["freq"] == ["A"]
      assert "DE" in availability["geo"]
      assert hd(availability["TIME_PERIOD"]) == "1975"
    end

    test "parses the content constraint (SDMX 2.1)" do
      stub_eurostat(%{
        "sdmx/3.0/structure/dataconstraint/ESTAT/nama_10_gdp" =>
          {:fixture, "dataconstraint_nama_10_gdp.xml"},
        "sdmx/2.1/contentconstraint/ESTAT/nama_10_gdp" =>
          {:fixture, "contentconstraint_nama_10_gdp.xml"}
      })

      assert {:ok, sdmx_2_1} = Datasets.availability("nama_10_gdp", sdmx_version: "2.1")
      assert {:ok, sdmx_3_0} = Datasets.availability("nama_10_gdp")
      assert Map.keys(sdmx_2_1) == Map.keys(sdmx_3_0)
      assert sdmx_2_1["unit"] == sdmx_3_0["unit"]
    end
  end

  describe "values/2" do
    test "returns the codes used by each dimension with their labels" do
      stub_eurostat({:fixture, "dataflow_tps00001_descendants_3_0.xml"})

      assert {:ok, dimensions} = Datasets.values("tps00001")

      assert assert_eurostat_request("sdmx/3.0/structure/dataflow/ESTAT/tps00001") ==
               [{"references", "descendants"}, {"detail", "referencepartial"}]

      assert Enum.map(dimensions, &{&1["id"], &1["position"], &1["name"], &1["codelist"]}) == [
               {"freq", 1, "Time frequency", "FREQ"},
               {"indic_de", 2, "Demographic indicator", "INDIC_DE"},
               {"geo", 3, "Geopolitical entity (reporting)", "GEO"}
             ]

      assert [%{"code" => "A", "name" => "Annual"}] = hd(dimensions)["values"]
      geo = List.last(dimensions)["values"]
      assert %{"code" => "DE", "name" => "Germany"} in geo
    end

    test "returns the labels in the requested language, with SDMX 2.1" do
      stub_eurostat({:fixture, "dataflow_tps00001_descendants_2_1.xml"})

      assert {:ok, [%{"name" => "Zeitliche Frequenz", "values" => [%{"name" => "Jährlich"}]} | _]} =
               Datasets.values("tps00001", language: :de, sdmx_version: "2.1")

      assert_eurostat_request("sdmx/2.1/dataflow/ESTAT/tps00001")
    end
  end
end
