defmodule Eurostatx.CodelistsTest do
  use Eurostatx.Case, async: true

  alias Eurostatx.Codelists
  alias Eurostatx.Error

  test "list/1 lists the code lists (stubs)" do
    stub_eurostat({:fixture, "codelists_stubs.xml"})

    assert {:ok, codelists} = Codelists.list()

    assert [{"detail", "allstubs"}] =
             assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/*")

    assert %{"id" => "FREQ", "agency" => "ESTAT", "version" => "3.9", "name" => "Time frequency"} in codelists
    assert length(codelists) == 3

    assert {:ok, [_ | _]} = Codelists.list(sdmx_version: "2.1", language: :fr)
    assert_eurostat_request("sdmx/2.1/codelist/ESTAT/all")
  end

  test "get/2 gets the code list in JSON" do
    stub_eurostat({:fixture, "codelist_freq.json"})

    assert {:ok, %{"class" => "dimension", "label" => "Time frequency"}} = Codelists.get("freq")

    assert assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/freq") ==
             [{"format", "JSON"}, {"lang", "en"}]

    assert {:ok, _json} = Codelists.get("freq", version: "3.9", sdmx_version: "2.1")
    assert_eurostat_request("sdmx/2.1/codelist/ESTAT/freq/3.9")
  end

  test "codes/2 returns the codes in order with their labels" do
    stub_eurostat({:fixture, "codelist_freq_fr.json"})

    assert {:ok, codes} = Codelists.codes("freq", language: :fr)
    assert {"lang", "fr"} in assert_eurostat_request("sdmx/3.0/structure/codelist/ESTAT/freq")

    assert Enum.map(codes, & &1["code"]) == ~w(P A S Q M W B D H I NAP A3)
    assert Enum.at(codes, 1) == %{"code" => "A", "name" => "Annuel"}
  end

  test "codes/2 returns the errors" do
    stub_eurostat({404, {:fixture, "fault_not_found.xml"}})
    assert {:error, %Error{type: :not_found}} = Codelists.codes("nope")
  end
end
