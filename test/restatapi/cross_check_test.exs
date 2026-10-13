defmodule Eurostatx.RestatapiCrossCheckTest do
  @moduledoc """
  Cross-checks Eurostatx against [restatapi](https://github.com/eurostat/restatapi),
  the R package published by Eurostat in its GitHub organization.

  The same queries are run with restatapi (inside Docker, see `queries.R`) and
  with Eurostatx against the live APIs, and their results are compared.

      mix test --only restatapi

  Set `RESTATAPI_OUTPUT=path/to/output` to reuse the results of a previous R
  run instead of running the R queries again.
  """

  use ExUnit.Case, async: false

  alias Eurostatx.Catalogue
  alias Eurostatx.Codelists
  alias Eurostatx.Data
  alias Eurostatx.Datasets
  alias Eurostatx.Statistics
  alias Explorer.DataFrame, as: DF

  @moduletag :restatapi
  @moduletag timeout: :timer.minutes(15)

  @image "eurostatx-restatapi"
  @dir Path.expand(".", __DIR__)

  setup_all do
    output = System.get_env("RESTATAPI_OUTPUT") || run_restatapi!()

    # Talk to the real APIs instead of the Req.Test stubs
    previous = Application.get_env(:eurostatx, :req_options)
    Application.put_env(:eurostatx, :req_options, [])
    on_exit(fn -> Application.put_env(:eurostatx, :req_options, previous) end)

    {:ok, output: output}
  end

  describe "data" do
    test "annual data filtered by dimension, with flags", %{output: output} do
      expected = r_observations(output, "data_nama_10_gdp", ~w(geo unit na_item))

      opts = [
        filters: [geo: ["DE", "FR"], unit: "CP_MEUR", na_item: "B1GQ"],
        start_period: 2015,
        end_period: 2020
      ]

      for df <- [
            Data.get_as_data_frame!("nama_10_gdp", opts),
            Data.get_as_data_frame!("nama_10_gdp", [sdmx_version: "2.1"] ++ opts),
            Statistics.data_as_data_frame!("nama_10_gdp", opts)
          ] do
        assert observations(df, ~w(geo unit na_item)) == expected
      end
    end

    test "monthly data selected with an SDMX 2.1 key", %{output: output} do
      expected = r_observations(output, "data_prc_hicp_minr", ~w(geo unit coicop18))

      by_key =
        Data.get_as_data_frame!("prc_hicp_minr",
          key: "M.RCH_A.TOTAL.EA+DE",
          start_period: "2025-01",
          end_period: "2025-12",
          sdmx_version: "2.1"
        )

      by_filters =
        Data.get_as_data_frame!("prc_hicp_minr",
          filters: [freq: "M", unit: "RCH_A", coicop18: "TOTAL", geo: ["EA", "DE"]],
          start_period: "2025-01",
          end_period: "2025-12"
        )

      assert observations(by_key, ~w(geo unit coicop18)) == expected
      assert observations(by_filters, ~w(geo unit coicop18)) == expected
      assert by_key["date"] |> Explorer.Series.to_list() |> Enum.all?(&(&1.day == 1))
    end

    test "quarterly data", %{output: output} do
      expected = r_observations(output, "data_namq_10_gdp", ~w(geo unit s_adj na_item))

      df =
        Data.get_as_data_frame!("namq_10_gdp",
          filters: [geo: "ES", unit: "CLV_PCH_PRE", s_adj: "SCA", na_item: "B1GQ"],
          start_period: 2022,
          end_period: 2024
        )

      assert observations(df, ~w(geo unit s_adj na_item)) == expected

      assert df |> DF.select(["time", "date"]) |> DF.to_rows() |> hd() ==
               %{"time" => "2022-Q1", "date" => ~D[2022-01-01]}
    end

    test "a whole dataset in TSV", %{output: output} do
      expected =
        output
        |> r_rows("raw_tps00001")
        |> Enum.flat_map(fn row ->
          case Float.parse(row["values"]) do
            {value, ""} ->
              [{row["freq"], row["indic_de"], row["geo"], row["time"], value, flag(row["flags"])}]

            _not_available ->
              []
          end
        end)
        |> Enum.sort()

      {:ok, tsv} = Data.get("tps00001", format: :tsv)

      actual =
        tsv
        |> Eurostatx.DataFrame.from_tsv()
        |> DF.to_rows()
        |> Enum.reject(&is_nil(&1["value"]))
        |> Enum.map(&{&1["freq"], &1["indic_de"], &1["geo"], &1["time"], &1["value"], &1["flag"]})
        |> Enum.sort()

      assert actual == expected
    end
  end

  describe "metadata" do
    test "codes and labels used by the dimensions of a dataset", %{output: output} do
      assert values("nama_10_gdp", []) == r_dsd(output, "dsd_nama_10_gdp")
      assert values("tps00001", language: :de) == r_dsd(output, "dsd_tps00001_de")
    end

    test "code lists", %{output: output} do
      for {name, id, opts} <- [
            {"codelist_freq", "freq", []},
            {"codelist_unit_fr", "unit", [language: :fr]}
          ] do
        {:ok, codes} = Codelists.codes(id, opts)
        expected = Enum.map(r_rows(output, name), &{&1["code"], &1["name"]})

        assert Enum.map(codes, &{&1["code"], &1["name"]}) == expected
      end
    end

    test "table of contents", %{output: output} do
      # restatapi keeps blank periods as " ", does not trim the non-breaking spaces at
      # the end of some titles and drops the items listed in several folders
      expected =
        output
        |> r_rows("toc_txt")
        |> Enum.map(fn row ->
          {row["code"], String.trim(row["title"]), row["type"], row["lastUpdate"],
           row["lastModified"], blank(row["dataStart"]), blank(row["dataEnd"]), row["values"]}
        end)

      {:ok, toc} = Catalogue.toc()

      actual =
        toc
        |> Enum.reject(&(&1["type"] == "folder"))
        |> Enum.map(fn item ->
          {item["code"], item["title"], item["type"], r_date(item["last_update"]),
           r_date(item["last_structure_change"]), item["data_start"], item["data_end"],
           item["values"]}
        end)
        |> Enum.uniq()

      assert actual == expected
    end
  end

  # Observations as sorted {dimension codes..., time, value, flag} tuples
  defp observations(df, dimensions) do
    df
    |> DF.to_rows()
    |> Enum.map(fn row ->
      List.to_tuple(Enum.map(dimensions, &row[&1]) ++ [row["time"], row["value"], row["flag"]])
    end)
    |> Enum.sort()
  end

  defp r_observations(output, name, dimensions) do
    output
    |> r_rows(name)
    |> Enum.map(fn row ->
      List.to_tuple(
        Enum.map(dimensions, &row[&1]) ++ [row["time"], row["values"] * 1.0, flag(row["flags"])]
      )
    end)
    |> Enum.sort()
  end

  defp values(dataset, opts) do
    {:ok, dimensions} = Datasets.values(dataset, opts)

    for dimension <- dimensions, value <- dimension["values"] do
      {dimension["id"], value["code"], value["name"]}
    end
    |> Enum.sort()
  end

  defp r_dsd(output, name) do
    output |> r_rows(name) |> Enum.map(&{&1["concept"], &1["code"], &1["name"]}) |> Enum.sort()
  end

  defp blank(value), do: if(String.trim(value || "") == "", do: nil, else: value)

  defp flag(""), do: nil
  defp flag(flag), do: flag

  # restatapi formats TOC dates as "2026.10.09"
  defp r_date(nil), do: nil
  defp r_date(%Date{} = date), do: Calendar.strftime(date, "%Y.%m.%d")

  defp r_rows(output, name) do
    output
    |> Path.join("#{name}.json")
    |> File.read!()
    |> JSON.decode!()
  end

  defp run_restatapi! do
    unless System.find_executable("docker"),
      do: raise("Docker is required to run the restatapi cross-check")

    {_output, status} = System.cmd("docker", ["image", "inspect", @image], stderr_to_stdout: true)

    if status != 0 do
      {output, 0} = System.cmd("docker", ["build", "-t", @image, @dir], stderr_to_stdout: true)
      IO.puts(output)
    end

    output =
      Path.join(System.tmp_dir!(), "eurostatx-restatapi-#{System.unique_integer([:positive])}")

    File.mkdir_p!(output)

    args = [
      "run",
      "--rm",
      "-v",
      "#{@dir}:/work",
      "-v",
      "#{output}:/out",
      @image,
      "Rscript",
      "queries.R",
      "/out"
    ]

    {log, status} = System.cmd("docker", args, stderr_to_stdout: true)
    if status != 0, do: raise("restatapi queries failed:\n#{log}")

    output
  end
end
