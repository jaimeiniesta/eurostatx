defmodule Eurostatx.Codelists do
  @moduledoc """
  Functions for the code lists of the SDMX structure queries.

  A code list is the list of codes (and their labels) that a dimension or an
  attribute can take: `GEO` for the geopolitical entities, `UNIT` for the
  units of measure, `OBS_FLAG` for the observation flags... Code lists are
  shared by many datasets and may contain more codes than the ones used by a
  given dataset (see `Eurostatx.Datasets.values/2` for those).

  Code lists are **versioned** and final: a given version never changes, so
  it is safe to cache it.

  ## Endpoints

    - `list/1` - [`codelist/{agency}/all?detail=allstubs`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/structure-queries) - Every code list (id, version and name)
    - `get/2` - [`codelist/{agency}/{id}?format=JSON`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/structure-queries) - A code list in JSON
    - `codes/2` - The codes of a code list with their labels

  For other formats (SDMX-ML, TSV) see `Eurostatx.Structure.get/3`.
  """

  alias Eurostatx.Client
  alias Eurostatx.Error
  alias Eurostatx.SDMX
  alias Eurostatx.Utils
  alias Eurostatx.XML

  @version_spec [
    type: :string,
    doc: "Version of the code list, e.g. `\"3.9\"`. The latest one by default."
  ]

  @list_schema Utils.schema([:language, :agency, :sdmx_version])
  @get_schema Utils.schema([:language, :agency, :sdmx_version, {:version, @version_spec}])

  @doc """
  Lists every code list of an agency, with its `"id"`, `"agency"`,
  `"version"` and `"name"`.

  ## Options

  #{NimbleOptions.docs(@list_schema)}

  ## Examples

      iex> {:ok, codelists} = Eurostatx.Codelists.list()
      iex> Enum.find(codelists, &(&1["id"] == "FREQ"))
      %{"id" => "FREQ", "agency" => "ESTAT", "version" => "3.9", "name" => "Time frequency"}
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @list_schema),
         agency = opts[:agency] || :eurostat,
         {:ok, version} <- Utils.sdmx_version(agency, opts),
         {:ok, xml} <-
           Client.get(list_path(version, agency), [{"detail", "allstubs"}], agency: agency),
         {:ok, root} <- XML.parse(xml) do
      {:ok, SDMX.artefacts(root, "Codelist", Utils.language(opts))}
    end
  end

  @doc """
  Gets a code list in JSON, untouched.

  The response is a JSON-stat `"dimension"`: `"category"` has the codes in
  order (`"index"`) and their labels (`"label"`), and `"extension"` the
  version and annotations of the code list.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> Eurostatx.Codelists.get("freq")
      {:ok,
       %{
         "class" => "dimension",
         "label" => "Time frequency",
         "category" => %{
           "index" => ["P", "A", "S", "Q", "M", "W", "B", "D", "H", "I", "NAP", "A3"],
           "label" => %{"A" => "Annual", "M" => "Monthly", "Q" => "Quarterly", ...}
         },
         "extension" => %{"id" => "FREQ", "version" => "3.9", ...},
         ...
       }}
  """
  @spec get(String.t(), keyword()) :: Client.response()
  def get(id, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema),
         agency = opts[:agency] || :eurostat,
         {:ok, version} <- Utils.sdmx_version(agency, opts) do
      Client.get(
        get_path(version, agency, id, opts[:version]),
        [{"format", "JSON"}, {"lang", Utils.language(opts)}],
        agency: agency
      )
    end
  end

  @doc """
  Gets the codes of a code list with their labels, in order.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> {:ok, codes} = Eurostatx.Codelists.codes("freq", language: :fr)
      iex> Enum.take(codes, 3)
      [%{"code" => "P", "name" => "Pluri-annuel"}, %{"code" => "A", "name" => "Annuel"}, %{"code" => "S", "name" => "Semestriel"}]
  """
  @spec codes(String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def codes(id, opts \\ []) do
    with {:ok, json} <- get(id, opts) do
      category = json["category"] || %{}
      labels = category["label"] || %{}

      codes =
        case category["index"] do
          index when is_list(index) ->
            index

          index when is_map(index) ->
            index |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

          nil ->
            Map.keys(labels)
        end

      {:ok, Enum.map(codes, &%{"code" => &1, "name" => labels[&1]})}
    end
  end

  defp list_path("3.0", agency),
    do: ["sdmx", "3.0", "structure", "codelist", Client.agency_id(agency), "*"]

  defp list_path("2.1", agency),
    do: ["sdmx", "2.1", "codelist", Client.agency_id(agency), "all"]

  defp get_path("3.0", agency, id, version),
    do:
      ["sdmx", "3.0", "structure", "codelist", Client.agency_id(agency), id] ++ List.wrap(version)

  defp get_path("2.1", agency, id, version),
    do: ["sdmx", "2.1", "codelist", Client.agency_id(agency), id] ++ List.wrap(version)
end
