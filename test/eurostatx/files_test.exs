defmodule Eurostatx.FilesTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Error
  alias Eurostatx.Files

  test "inventory/1 parses the inventory of datasets" do
    stub_eurostat({:fixture, "inventory_data.tsv"})

    assert {:ok, [dataset | _] = datasets} = Files.inventory()
    assert assert_eurostat_request("files/inventory") == [{"type", "data"}, {"lang", "en"}]
    assert length(datasets) == 3

    assert %{
             "Code" => "AACT_ALI01",
             "Type" => "DATASET",
             "Last data change" => "2026-05-13T11:00:00+0200",
             "Data download url (csv)" =>
               "https://ec.europa.eu/eurostat/api/dissemination/sdmx/2.1/data/AACT_ALI01/?format=SDMX-CSV"
           } = dataset
  end

  test "inventory/1 parses the inventory of code lists" do
    stub_eurostat({:fixture, "inventory_codelist.tsv"})

    assert {:ok, [%{"Code" => "ACCIDENT", "Source" => "ESTAT", "Version" => "2.2"} | _]} =
             Files.inventory(type: :codelist, language: :fr)

    assert assert_eurostat_request("files/inventory") == [{"type", "codelist"}, {"lang", "fr"}]
  end

  test "list/2 lists a directory with ISO dates and sizes in bytes" do
    stub_eurostat({:fixture, "files_metadata.csv"})

    assert {:ok, [file | _]} =
             Files.list("metadata/", sort: :date, order: :desc, hierarchy: false)

    assert assert_eurostat_request("files/") == [
             {"format", "csv"},
             {"dir", "metadata/"},
             {"sort", "date"},
             {"order", "desc"},
             {"hierarchy", "false"},
             {"dateFormat", "ISO"},
             {"sizeFormat", "NONE"}
           ]

    assert file == %{
             "name" => "rd_esms.sdmx.zip",
             "path" => "metadata/rd_esms.sdmx.zip",
             "type" => "sdmx",
             "size" => 707_365,
             "date" => ~U[2026-10-13 15:16:58.478Z]
           }
  end

  test "list/2 lists the root directory" do
    stub_eurostat({:fixture, "files_root.csv"})

    assert {:ok, entries} = Files.list()

    assert %{"name" => "metadata", "path" => "metadata", "type" => "DIR", "size" => nil} =
             Enum.find(entries, &(&1["name"] == "metadata"))
  end

  test "download/2 returns the file untouched" do
    stub_eurostat({:fixture, "metabase.txt.gz"})

    assert {:ok, <<0x1F, 0x8B, _rest::binary>> = body} = Files.download("metadata/x.gz")
    assert body == fixture("metabase.txt.gz")
    assert assert_eurostat_request("files/") == [{"file", "metadata/x.gz"}]
  end

  test "download/2 returns not found errors" do
    stub_eurostat({404, {:fixture, "files_404.html"}})
    assert {:error, %Error{type: :not_found}} = Files.download("metadata/nope.zip")
  end
end
