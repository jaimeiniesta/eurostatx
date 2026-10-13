defmodule Eurostatx.CatalogueTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Catalogue
  alias Eurostatx.Error
  alias Explorer.DataFrame, as: DF

  describe "toc/1" do
    test "parses the text table of contents with levels and parents" do
      stub_eurostat({:fixture, "toc_en.txt"})

      assert {:ok, [root, general | _] = toc} = Catalogue.toc(language: :fr)
      assert assert_eurostat_request("catalogue/toc/txt") == [{"lang", "fr"}]

      assert root == %{
               "code" => "data",
               "title" => "Database by themes",
               "type" => "folder",
               "level" => 0,
               "parent" => nil,
               "last_update" => nil,
               "last_structure_change" => nil,
               "data_start" => nil,
               "data_end" => nil,
               "values" => nil
             }

      assert %{"code" => "general", "level" => 1, "parent" => "data"} = general

      assert %{
               "title" => "Current account - quarterly data",
               "type" => "table",
               "level" => 4,
               "parent" => "ei_bp",
               "last_update" => ~D[2026-10-02],
               "last_structure_change" => ~D[2026-10-02],
               "data_start" => "1991-Q1",
               "data_end" => "2026-Q2",
               "values" => 314_789
             } = Enum.find(toc, &(&1["code"] == "ei_bpm6ca_q"))
    end

    test "parses the XML table of contents in the requested language" do
      stub_eurostat({:fixture, "toc.xml"})

      assert {:ok, toc} = Catalogue.toc(format: :xml, language: :de)
      assert assert_eurostat_request("catalogue/toc/xml") == []

      assert Enum.map(toc, &{&1["code"], &1["type"], &1["level"], &1["parent"]}) == [
               {"data", "folder", 0, nil},
               {"general", "folder", 1, "data"},
               {"euroind", "folder", 2, "general"},
               {"ei_bp", "folder", 3, "euroind"},
               {"ei_bpm6ca_q", "table", 4, "ei_bp"},
               {"ei_bpm6fa_q", "table", 4, "ei_bp"}
             ]

      assert %{
               "title" => "Leistungsbilanz - vierteljährliche Daten",
               "last_update" => ~D[2026-10-02],
               "data_start" => "1991-Q1",
               "values" => 314_789,
               "source" => "Eurostat",
               "unit" => nil,
               "metadata_html" =>
                 "https://ec.europa.eu/eurostat/cache/metadata/en/ei_bp_esms.htm",
               "download_tsv" =>
                 "https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/data/EI_BPM6CA_Q?format=tsv&compressed=true"
             } = Enum.at(toc, 4)
    end
  end

  describe "search/2" do
    setup do
      stub_eurostat({:fixture, "toc_en.txt"})
      {:ok, toc} = Catalogue.toc()
      {:ok, toc: toc}
    end

    test "matches titles and codes, case-insensitive", %{toc: toc} do
      assert {:ok, [%{"code" => "ei_bpm6ca_q"}, %{"code" => "ei_bpm6ca_m"}]} =
               Catalogue.search("CURRENT ACCOUNT", toc: toc)

      assert {:ok, [%{"code" => "ei_bpm6fa_q"}]} = Catalogue.search("bpm6fa_q", toc: toc)
    end

    test "matches regular expressions", %{toc: toc} do
      assert {:ok, results} = Catalogue.search(~r/_q$/, toc: toc)
      assert Enum.all?(results, &String.ends_with?(&1["code"], "_q"))
    end

    test "filters by type", %{toc: toc} do
      assert {:ok, [%{"code" => "ei_bp"}]} =
               Catalogue.search("balance of payments", toc: toc, types: [:folder])

      assert {:ok, []} = Catalogue.search("balance of payments", toc: toc)
    end

    test "downloads the table of contents when not given" do
      assert {:ok, [_ | _]} = Catalogue.search("account", language: :de)

      assert [
               %{endpoint: "catalogue/toc/txt"},
               %{endpoint: "catalogue/toc/txt", params: [{"lang", "de"}]}
             ] =
               eurostat_requests()
    end
  end

  test "toc_schema/1 returns the XSD" do
    stub_eurostat({:fixture, "toc.xsd"})

    assert {:ok, "<?xml" <> _} = Catalogue.toc_schema()
    assert_eurostat_request("catalogue/toc/TableOfContent.xsd")
  end

  test "rss/1 parses the feed" do
    stub_eurostat({:fixture, "rss_en.rss"})

    assert {:ok, feed} = Catalogue.rss(language: :fr)
    assert_eurostat_request("catalogue/rss/fr/statistics-update.rss")

    assert %{
             "title" => "ESTAT - Data and Data Structure updates",
             "language" => "en",
             "pub_date" => ~N[2026-10-13 11:25:00],
             "items" => [item | _] = items
           } = feed

    assert length(items) == 3

    assert item == %{
             "code" => "AVIA_TF_ACA",
             "category" => "UPDATED_DATASET_DATA",
             "title" => "AVIA_TF_ACA - \"Dataset: updated data\"",
             "description" =>
               "Air transport by aircraft model, transport coverage and main airports",
             "link" => "https://ec.europa.eu/eurostat/databrowser/product/page/AVIA_TF_ACA",
             "pub_date" => ~N[2026-10-13 11:23:00.0]
           }
  end

  test "rss/1 returns an error for invalid feeds" do
    stub_eurostat({200, "<rss version=\"2.0\"></rss>"})
    assert {:error, %Error{type: :decode_error}} = Catalogue.rss()
  end

  describe "dcat/2" do
    test "unzips the catalogue" do
      stub_eurostat({:fixture, "dcat_updates.zip"})

      assert {:ok, [{"manifest.xml", "<?xml" <> _} | datasets]} = Catalogue.dcat(:updates)
      assert_eurostat_request("catalogue/dcat/ESTAT/UPDATES")

      assert [{"datasets/" <> _, _rdf}, {"datasets/" <> _, _}] = datasets
    end

    test "returns the zip archive with raw: true, for any agency" do
      stub_eurostat({:fixture, "dcat_updates.zip"})

      assert {:ok, <<"PK", _rest::binary>>} = Catalogue.dcat(:full, raw: true, agency: :ecfin)
      assert [%{agency: :ecfin, endpoint: "catalogue/dcat/ECFIN/FULL"}] = eurostat_requests()
    end

    test "returns an error for invalid archives" do
      stub_eurostat({200, "not a zip"})
      assert {:error, %Error{type: :decode_error}} = Catalogue.dcat()
    end
  end

  describe "metabase/1" do
    test "returns the codes of every dimension of every dataset" do
      stub_eurostat({:fixture, "metabase.txt.gz"})

      assert {:ok, %{"aact_ali01" => dimensions} = metabase} = Catalogue.metabase()
      assert_eurostat_request("catalogue/metabase.txt.gz")

      assert Map.keys(metabase) == ["aact_ali01"]
      assert hd(dimensions["am_item"]) == "AM400000"
      assert "EU" in dimensions["geo"]
    end

    test "filters datasets" do
      stub_eurostat({:fixture, "metabase.txt.gz"})

      assert {:ok, %{}} = Catalogue.metabase(datasets: ["nope"])
      assert {:ok, %{"aact_ali01" => _}} = Catalogue.metabase(datasets: ["AACT_ALI01"])
    end

    test "returns a data frame" do
      stub_eurostat({:fixture, "metabase.txt.gz"})

      assert {:ok, df} = Catalogue.metabase_as_data_frame()
      assert DF.names(df) == ~w(dataset dimension code)
      assert DF.n_rows(df) == 25
    end
  end
end
