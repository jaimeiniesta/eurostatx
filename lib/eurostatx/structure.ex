defmodule Eurostatx.Structure do
  @moduledoc """
  Generic access to the SDMX structure queries of the
  [SDMX 3.0](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx3-0/structure-queries)
  and [SDMX 2.1](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/structure-queries)
  APIs.

  `get/3` retrieves any structural metadata artefact, raw: SDMX-ML by
  default, or JSON and TSV for the formats that support them. Use it for
  metadata harvesting and for the artefacts without a dedicated function, such
  as concept schemes or the navigation tree (category schemes and
  categorisations). `Eurostatx.Datasets` and `Eurostatx.Codelists` parse the
  most common artefacts.

  ## Artefact types

  | Type              | SDMX artefact                                  |
  | ----------------- | ---------------------------------------------- |
  | `:dataflow`       | Dataflows: the datasets                        |
  | `:datastructure`  | Data structure definitions (DSD)               |
  | `:codelist`       | Code lists                                     |
  | `:conceptscheme`  | Concept schemes: labels of the dimensions      |
  | `:constraint`     | Data constraints (3.0) / content constraints (2.1): codes used by a dataset |
  | `:categoryscheme` | Category schemes: the navigation tree          |
  | `:categorisation` | Categorisations: datasets in the navigation tree |

  Code lists, concept schemes and DSDs are versioned and final: a version
  never changes. Dataflows and constraints are always version `1.0` and
  change with every update.

  ## Endpoints

    - `get/3` - [`sdmx/3.0/structure/{type}/{agency}/{id}/{version}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx3-0/structure-queries)
      or [`sdmx/2.1/{type}/{agency}/{id}/{version}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/structure-queries)
  """

  alias Eurostatx.Client
  alias Eurostatx.Utils

  @types [
    :dataflow,
    :datastructure,
    :codelist,
    :conceptscheme,
    :constraint,
    :categoryscheme,
    :categorisation
  ]

  @details %{
    full: "full",
    all_stubs: "allstubs",
    reference_stubs: "referencestubs",
    all_complete_stubs: "allcompletestubs",
    reference_complete_stubs: "referencecompletestubs",
    reference_partial: "referencepartial"
  }

  @references %{
    none: "none",
    parents: "parents",
    parents_and_siblings: "parentsandsiblings",
    children: "children",
    descendants: "descendants",
    all: "all"
  }

  @get_schema Utils.schema([
                :language,
                :agency,
                :sdmx_version,
                {:version,
                 [
                   type: :string,
                   doc:
                     "Version of the artefact, e.g. `\"138.0\"`. The latest one by default. " <>
                       "Not allowed when listing every artefact (`:all`)."
                 ]},
                {:detail,
                 [
                   type: {:in, Map.keys(@details)},
                   doc:
                     "Amount of information: `:full` (default), `:all_stubs` (only ids and " <>
                       "names), `:all_complete_stubs` (plus descriptions and annotations), " <>
                       "`:reference_stubs`, `:reference_complete_stubs` or " <>
                       "`:reference_partial` (referenced code lists only with the codes used " <>
                       "by a dataflow, with `references: :children` or `:descendants`).",
                   type_doc: "atom"
                 ]},
                {:references,
                 [
                   type: {:in, Map.keys(@references)},
                   doc:
                     "Referenced artefacts to include: `:none` (default), `:parents`, " <>
                       "`:parents_and_siblings`, `:children`, `:descendants` or `:all`. " <>
                       "Eurostat does not support every combination, see the API guides.",
                   type_doc: "atom"
                 ]},
                {:format,
                 [
                   type: {:in, [:xml, :json, :tsv]},
                   default: :xml,
                   doc:
                     "`:xml` (SDMX-ML, default), `:json` (dataflows and code lists) or `:tsv` " <>
                       "(code lists; every language in columns with SDMX 3.0). JSON is decoded; XML and " <>
                       "TSV are returned as binaries.",
                   type_doc: "`:xml | :json | :tsv`"
                 ]}
              ])

  @doc """
  Gets a structural metadata artefact, or every artefact of a type with `:all`.

  `id` is the id of the artefact (case-insensitive) or `:all`. With SDMX 3.0
  the dataflow listing is empty: list the datasets with SDMX 2.1 or with
  `Eurostatx.Datasets.list/1`.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      # The DSD of a dataset, in SDMX-ML 3.0
      iex> {:ok, "<?xml" <> _} = Eurostatx.Structure.get(:datastructure, "NAMA_10_GDP")

      # A dataflow with its DSD, concept scheme and code lists, only with the codes it uses
      iex> {:ok, _xml} =
      ...>   Eurostatx.Structure.get(:dataflow, "NAMA_10_GDP",
      ...>     references: :descendants,
      ...>     detail: :reference_partial
      ...>   )

      # A code list in TSV, in German
      iex> Eurostatx.Structure.get(:codelist, "FREQ", format: :tsv, language: :de, sdmx_version: "2.1")
      {:ok, "P\\tMehrjährig\\r\\nA\\tJährlich\\r\\nS\\tHalbjährlich, pro Semester\\r\\n..."}

      # Every code list (stubs) and the navigation tree
      iex> {:ok, _xml} = Eurostatx.Structure.get(:codelist, :all, detail: :all_stubs)
      iex> {:ok, _xml} = Eurostatx.Structure.get(:categoryscheme, :all, sdmx_version: "2.1")
  """
  @spec get(atom(), String.t() | :all, keyword()) :: Client.response()
  def get(type, id \\ :all, opts \\ [])

  def get(type, id, opts) when type in @types and (id == :all or is_binary(id)) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema),
         agency = opts[:agency] || :eurostat,
         {:ok, version} <- Utils.sdmx_version(agency, opts),
         :ok <- validate_version(id, opts),
         :ok <- validate_tsv_language(version, opts) do
      Client.get(path(version, type, agency, id, opts[:version]), params(version, opts),
        agency: agency
      )
    end
  end

  def get(type, id, _opts) do
    Utils.option_error(
      "expected a type in #{inspect(@types)} and an id or :all, got: #{inspect({type, id})}"
    )
  end

  defp validate_version(:all, opts) do
    if opts[:version],
      do: Utils.option_error(":version cannot be used to list every artefact (:all)"),
      else: :ok
  end

  defp validate_version(_id, _opts), do: :ok

  defp validate_tsv_language("3.0", opts) do
    if opts[:format] == :tsv and opts[:language] not in [nil, :en],
      do:
        Utils.option_error(
          "SDMX 3.0 TSV code lists have a column per language and do not accept :language, use sdmx_version: \"2.1\" for a single language"
        ),
      else: :ok
  end

  defp validate_tsv_language(_version, _opts), do: :ok

  defp path("3.0", type, agency, id, version) do
    type = if type == :constraint, do: "dataconstraint", else: to_string(type)
    id = if id == :all, do: "*", else: id
    ["sdmx", "3.0", "structure", type, Client.agency_id(agency), id] ++ List.wrap(version)
  end

  defp path("2.1", type, agency, id, version) do
    type = if type == :constraint, do: "contentconstraint", else: to_string(type)
    id = if id == :all, do: "all", else: id
    ["sdmx", "2.1", type, Client.agency_id(agency), id] ++ List.wrap(version)
  end

  defp params(version, opts) do
    format_params =
      case {opts[:format], version} do
        {:xml, _version} ->
          []

        {:json, _version} ->
          [{"format", "JSON"}, {"lang", Utils.language(opts)}]

        # SDMX 3.0 TSV code lists have every language in columns and reject the lang parameter
        {:tsv, "3.0"} ->
          [{"format", "TSV"}, {"formatVersion", "2.0"}]

        {:tsv, "2.1"} ->
          [{"format", "TSV"}, {"lang", Utils.language(opts)}]
      end

    [
      {"detail", @details[opts[:detail]]},
      {"references", @references[opts[:references]]}
    ] ++ format_params
  end
end
