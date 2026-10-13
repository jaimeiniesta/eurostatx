defmodule Eurostatx.StructureTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Error
  alias Eurostatx.Structure

  test "gets an artefact with SDMX 3.0 in SDMX-ML" do
    stub_eurostat({:fixture, "dataflow_nama_10_gdp_children_3_0.xml"})

    assert {:ok, "<?xml" <> _} = Structure.get(:datastructure, "NAMA_10_GDP")
    assert [] = assert_eurostat_request("sdmx/3.0/structure/datastructure/ESTAT/NAMA_10_GDP")
  end

  test "maps the types, ids and versions of each SDMX version" do
    stub_eurostat({:fixture, "dataconstraint_nama_10_gdp.xml"})

    for {args, opts, endpoint} <- [
          {[:constraint, "X"], [], "sdmx/3.0/structure/dataconstraint/ESTAT/X"},
          {[:constraint, "X"], [sdmx_version: "2.1"], "sdmx/2.1/contentconstraint/ESTAT/X"},
          {[:codelist, :all], [], "sdmx/3.0/structure/codelist/ESTAT/*"},
          {[:codelist, :all], [sdmx_version: "2.1"], "sdmx/2.1/codelist/ESTAT/all"},
          {[:conceptscheme, "X"], [version: "118.1"],
           "sdmx/3.0/structure/conceptscheme/ESTAT/X/118.1"},
          {[:categorisation, :all], [sdmx_version: "2.1"], "sdmx/2.1/categorisation/ESTAT/all"},
          {[:categoryscheme, :all], [agency: :empl], "sdmx/2.1/categoryscheme/EMPL/all"}
        ] do
      assert {:ok, _xml} = apply(Structure, :get, args ++ [opts])
      assert_eurostat_request(endpoint)
    end
  end

  test "lists every artefact of a type by default" do
    stub_eurostat({:fixture, "codelists_stubs.xml"})

    assert {:ok, _xml} = Structure.get(:codelist)
    assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/*")
  end

  test "translates detail and references" do
    stub_eurostat({:fixture, "dataflow_tps00001_descendants_3_0.xml"})

    assert {:ok, _xml} =
             Structure.get(:dataflow, "TPS00001",
               detail: :reference_partial,
               references: :descendants
             )

    assert assert_eurostat_request("sdmx/3.0/structure/dataflow/ESTAT/TPS00001") ==
             [{"detail", "referencepartial"}, {"references", "descendants"}]

    for {detail, value} <- [all_stubs: "allstubs", all_complete_stubs: "allcompletestubs"],
        {references, reference} <- [parents_and_siblings: "parentsandsiblings", none: "none"] do
      assert {:ok, _xml} =
               Structure.get(:codelist, "FREQ", detail: detail, references: references)

      assert assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/FREQ") ==
               [{"detail", value}, {"references", reference}]
    end
  end

  test "requests JSON and decodes it" do
    stub_eurostat({:fixture, "codelist_freq.json"})

    assert {:ok, %{"class" => "dimension"}} =
             Structure.get(:codelist, "FREQ", format: :json, language: :de)

    assert assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/FREQ") ==
             [{"format", "JSON"}, {"lang", "de"}]
  end

  test "requests TSV, with a language only with SDMX 2.1" do
    stub_eurostat({:fixture, "codelist_freq_de.tsv"})

    assert {:ok, "P\tMehrjährig" <> _} =
             Structure.get(:codelist, "FREQ", format: :tsv, language: :de, sdmx_version: "2.1")

    assert assert_eurostat_request("sdmx/2.1/codelist/ESTAT/FREQ") == [
             {"format", "TSV"},
             {"lang", "de"}
           ]

    assert {:ok, _tsv} = Structure.get(:codelist, "FREQ", format: :tsv)

    assert assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/FREQ") ==
             [{"format", "TSV"}, {"formatVersion", "2.0"}]

    assert {:error, %Error{type: :option_error}} =
             Structure.get(:codelist, "FREQ", format: :tsv, language: :de)
  end

  test "validates the arguments" do
    assert {:error, %Error{type: :option_error}} = Structure.get(:table, "X")
    assert {:error, %Error{type: :option_error}} = Structure.get(:codelist, :all, version: "1.0")

    assert {:error, %Error{type: :option_error}} =
             Structure.get(:codelist, "X", detail: :everything)

    assert {:error, %Error{type: :option_error}} =
             Structure.get(:codelist, "X", agency: :empl, sdmx_version: "3.0")
  end
end
