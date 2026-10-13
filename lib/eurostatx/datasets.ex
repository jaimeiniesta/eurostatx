defmodule Eurostatx.Datasets do
  @moduledoc """
  Discovery and metadata of datasets, from the SDMX structure queries.

  In SDMX, a dataset is described by a **dataflow** (its title, annotations
  and the reference to its structure), a **data structure definition** (DSD:
  the dimensions, in key order, attributes and measures) and a **data
  constraint** (the codes actually used by each dimension). The codes and
  labels of each dimension come from **code lists** (see
  `Eurostatx.Codelists`) and the labels of the dimensions from **concept
  schemes**.

  The usual workflow to query a dataset is:

      # 1. Find the dataset (or search the table of contents with Eurostatx.Catalogue.search/2)
      {:ok, datasets} = Eurostatx.Datasets.list()

      # 2. Discover its dimensions and the codes they use, with their labels
      {:ok, dimensions} = Eurostatx.Datasets.values("nama_10_gdp")

      # 3. Get the data
      Eurostatx.Data.get_as_data_frame!("nama_10_gdp", filters: [geo: "DE", unit: "CP_MEUR", na_item: "B1GQ"])

  ## Endpoints

    - `list/1` - [`sdmx/2.1/dataflow/{agency}/all`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx2-1/structure-queries) - Every dataset, summarized
    - `get/2` - [`dataflow/{agency}/{dataset}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/sdmx3-0/structure-queries) - The dataflow of a dataset in JSON
    - `structure/2` - `dataflow/{agency}/{dataset}?references=children` - Its data structure definition
    - `availability/2` - `dataconstraint/{agency}/{dataset}` - The codes used by each dimension
    - `values/2` - `dataflow/{agency}/{dataset}?references=descendants&detail=referencepartial` - The codes used by each dimension, with labels
    - `summary/1` - Summarizes a dataflow (no request)
  """

  alias Eurostatx.Client
  alias Eurostatx.Error
  alias Eurostatx.SDMX
  alias Eurostatx.Utils
  alias Eurostatx.XML

  @list_schema Utils.schema([:language, :agency])
  @get_schema Utils.schema([:language, :agency, :sdmx_version])

  @doc """
  Lists every dataset (dataflow) of an agency, summarized with `summary/1`.

  The listing comes from the SDMX 2.1 API in JSON: the SDMX 3.0 API does not
  list dataflows. The response for Eurostat is about 20 MB.

  ## Options

  #{NimbleOptions.docs(@list_schema)}

  ## Examples

      iex> {:ok, datasets} = Eurostatx.Datasets.list()
      iex> Enum.find(datasets, &(&1["id"] == "NAMA_10_GDP"))
      %{
        "id" => "NAMA_10_GDP",
        "label" => "Gross domestic product (GDP) and main components (output, expenditure and income) - annual data",
        "agency" => "ESTAT",
        "type" => "DATASET",
        "observations" => 1084124,
        "oldest_period" => "1975",
        "latest_period" => "2025",
        "data_updated_at" => ~U[2026-10-09 21:00:00Z],
        ...
      }

      # Comext and Prodcom datasets
      iex> {:ok, [%{"id" => "DS-" <> _} | _]} = Eurostatx.Datasets.list(agency: :comext)
  """
  @spec list(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @list_schema),
         agency = opts[:agency] || :eurostat,
         {:ok, json} <-
           Client.get(
             ["sdmx", "2.1", "dataflow", Client.agency_id(agency), "all"],
             [{"format", "JSON"}, {"lang", Utils.language(opts)}],
             agency: agency
           ) do
      items = get_in(json, ["link", "item"]) || []
      {:ok, Enum.map(items, &summary/1)}
    end
  end

  @doc """
  Gets the dataflow of a dataset in JSON, untouched.

  The dataflow has the title of the dataset (`"label"`) and, in
  `"extension"`, its identifiers, the reference to its data structure and
  Eurostat's annotations: number of observations, oldest and latest periods,
  dates of the last data and structure updates, links to the reference
  metadata... Use `summary/1` to read them.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> Eurostatx.Datasets.get("nama_10_gdp")
      {:ok,
       %{
         "class" => "dataset",
         "label" => "Gross domestic product (GDP) and main components (output, expenditure and income) - annual data",
         "extension" => %{
           "id" => "NAMA_10_GDP",
           "agencyId" => "ESTAT",
           "datastructure" => %{"id" => "NAMA_10_GDP", "agencyId" => "ESTAT", "version" => "138.0"},
           "annotation" => [%{"type" => "CREATED", "date" => "2014-09-04T14:58:03+0200"}, ...],
           ...
         },
         ...
       }}

      iex> {:error, %Eurostatx.Error{type: :not_found}} = Eurostatx.Datasets.get("nope")
  """
  @spec get(String.t(), keyword()) :: Client.response()
  def get(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema),
         agency = Utils.agency(dataset, opts),
         {:ok, version} <- Utils.sdmx_version(agency, opts) do
      Client.get(
        dataflow_path(version, agency, dataset),
        [{"format", "JSON"}, {"lang", Utils.language(opts)}],
        agency: agency
      )
    end
  end

  @doc """
  Summarizes a dataflow, as returned by `get/2` or listed by `list/1`.

  The summary has the `"id"`, `"label"`, `"agency"` and `"version"` of the
  dataflow, its `"data_structure"` (id, agency and version of the DSD) and the
  values of Eurostat's annotations:

  | key                      | annotation                    |
  | ------------------------ | ----------------------------- |
  | `"type"`                 | `DISSEMINATION_OBJECT_TYPE` (`"DATASET"` or `"TABLE"`) |
  | `"observations"`         | `OBS_COUNT` (integer)         |
  | `"oldest_period"`        | `OBS_PERIOD_OVERALL_OLDEST`   |
  | `"latest_period"`        | `OBS_PERIOD_OVERALL_LATEST`   |
  | `"data_updated_at"`      | `UPDATE_DATA` (`DateTime`)    |
  | `"structure_updated_at"` | `UPDATE_STRUCTURE` (`DateTime`) |
  | `"created_at"`           | `CREATED` (`DateTime`)        |
  | `"metadata_html"`        | `ESMS_HTML` link              |
  | `"metadata_sdmx"`        | `ESMS_SDMX` link              |
  | `"doi"`                  | `DISSEMINATION_DOI_XML`       |
  | `"source"`               | `SOURCE_INSTITUTIONS`         |

  Missing annotations are `nil`. `"data_updated_at"` is handy to check
  whether a dataset changed since it was last downloaded.

  ## Examples

      iex> Eurostatx.Datasets.summary(%{
      ...>   "label" => "Population on 1 January",
      ...>   "extension" => %{
      ...>     "id" => "TPS00001", "agencyId" => "ESTAT", "version" => "1.0",
      ...>     "annotation" => [
      ...>       %{"type" => "OBS_COUNT", "title" => "1234"},
      ...>       %{"type" => "UPDATE_DATA", "date" => "2026-03-20T11:00:00+0100"}
      ...>     ]
      ...>   }
      ...> }) |> Map.take(["id", "label", "observations", "data_updated_at"])
      %{"id" => "TPS00001", "label" => "Population on 1 January", "observations" => 1234, "data_updated_at" => ~U[2026-03-20 10:00:00Z]}
  """
  @spec summary(map()) :: map()
  def summary(dataflow) do
    extension = dataflow["extension"] || %{}
    annotations = extension["annotation"] || []
    annotation = fn type -> Enum.find(annotations, &(&1["type"] == type)) || %{} end
    data_structure = extension["datastructure"]

    %{
      "id" => extension["id"],
      "label" => dataflow["label"],
      "agency" => extension["agencyId"],
      "version" => extension["version"],
      "type" => annotation.("DISSEMINATION_OBJECT_TYPE")["title"],
      "data_structure" =>
        data_structure &&
          %{
            "id" => data_structure["id"],
            "agency" => data_structure["agencyId"],
            "version" => data_structure["version"]
          },
      "observations" => to_integer(annotation.("OBS_COUNT")["title"]),
      "oldest_period" => annotation.("OBS_PERIOD_OVERALL_OLDEST")["title"],
      "latest_period" => annotation.("OBS_PERIOD_OVERALL_LATEST")["title"],
      "data_updated_at" => to_datetime(annotation.("UPDATE_DATA")["date"]),
      "structure_updated_at" => to_datetime(annotation.("UPDATE_STRUCTURE")["date"]),
      "created_at" => to_datetime(annotation.("CREATED")["date"]),
      "metadata_html" => annotation.("ESMS_HTML")["href"],
      "metadata_sdmx" => annotation.("ESMS_SDMX")["href"],
      "doi" => doi(annotation.("DISSEMINATION_DOI_XML")["title"]),
      "source" => annotation.("SOURCE_INSTITUTIONS")["text"]
    }
  end

  @doc """
  Gets the data structure definition (DSD) of a dataset: its dimensions, in
  the order of the series keys, its time dimension, attributes and measures.

  Each dimension has its `"id"`, `"position"`, `"concept"` and `"codelist"`
  (references with `"agency"`, `"id"` and `"version"`). The DSD is read from
  the dataflow with `references=children`, so it works even when the DSD and
  the dataset have different ids.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> {:ok, structure} = Eurostatx.Datasets.structure("nama_10_gdp")
      iex> Enum.map(structure["dimensions"], & &1["id"])
      ["freq", "unit", "na_item", "geo"]
      iex> structure["time_dimension"]
      "TIME_PERIOD"
      iex> hd(structure["dimensions"])
      %{
        "id" => "freq",
        "position" => 1,
        "concept" => %{"agency" => "ESTAT", "id" => "NAMA_10_GDP", "version" => "118.1", "item" => "freq"},
        "codelist" => %{"agency" => "ESTAT", "id" => "FREQ", "version" => "3.9", "item" => nil}
      }
  """
  @spec structure(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def structure(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema),
         {:ok, root} <- fetch_xml(dataset, opts, [{"references", "children"}]),
         %{} = structure <- SDMX.data_structure(root, Utils.language(opts)) || missing(dataset) do
      {:ok, structure}
    end
  end

  @doc """
  Gets the codes actually used by each dimension of a dataset, including the
  time periods, from its data constraint.

  Use it to validate queries before sending them: Eurostat rejects queries
  with codes that are not used by the dataset. The time periods
  (`"TIME_PERIOD"`) give the range of the data, and the length of each list
  the size of the dimension, which helps estimating the cost of an extraction
  (see `Eurostatx.Async`).

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> {:ok, availability} = Eurostatx.Datasets.availability("nama_10_gdp")
      iex> availability["freq"]
      ["A"]
      iex> availability["TIME_PERIOD"] |> Enum.take(3)
      ["1975", "1976", "1977"]
  """
  @spec availability(String.t(), keyword()) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, Error.t()}
  def availability(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema),
         agency = Utils.agency(dataset, opts),
         {:ok, version} <- Utils.sdmx_version(agency, opts),
         {:ok, xml} <- Client.get(constraint_path(version, agency, dataset), [], agency: agency),
         {:ok, root} <- XML.parse(xml) do
      {:ok, SDMX.constraint(root)}
    end
  end

  @doc """
  Gets the dimensions of a dataset with the codes they use and their labels,
  in the requested language.

  Returns one map per dimension, in key order, with its `"id"`, `"position"`,
  `"name"` (the label of the dimension), `"codelist"` (the id of its code
  list) and `"values"`: the codes used by the dataset, with their `"name"`.
  The time dimension is not included; see `availability/2` for the periods.

  ## Options

  #{NimbleOptions.docs(@get_schema)}

  ## Examples

      iex> {:ok, dimensions} = Eurostatx.Datasets.values("tps00001")
      iex> Enum.map(dimensions, &{&1["id"], &1["name"], length(&1["values"])})
      [{"freq", "Time frequency", 1}, {"indic_de", "Demographic indicator", 1}, {"geo", "Geopolitical entity (reporting)", 54}]
      iex> dimensions |> List.last() |> Map.fetch!("values") |> Enum.take(2)
      [%{"code" => "EU27_2020", "name" => "European Union - 27 countries (from 2020)"}, %{"code" => "EA21", "name" => "Euro area – 21 countries (from 2026)"}]

      # Labels in German
      iex> {:ok, [%{"name" => "Zeitliche Frequenz"} | _]} = Eurostatx.Datasets.values("tps00001", language: :de)
  """
  @spec values(String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def values(dataset, opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @get_schema),
         {:ok, root} <-
           fetch_xml(dataset, opts, [
             {"references", "descendants"},
             {"detail", "referencepartial"}
           ]),
         language = Utils.language(opts),
         %{} = structure <- SDMX.data_structure(root, language) || missing(dataset) do
      concepts = SDMX.concepts(root, language)
      codelists = SDMX.codelists(root, language)

      dimensions =
        Enum.map(structure["dimensions"], fn dimension ->
          concept = dimension["concept"] || %{}
          codelist = dimension["codelist"] || %{}

          %{
            "id" => dimension["id"],
            "position" => dimension["position"],
            "name" => concepts[{concept["id"], concept["item"]}],
            "codelist" => codelist["id"],
            "values" => get_in(codelists, [codelist["id"], "codes"]) || []
          }
        end)

      {:ok, dimensions}
    end
  end

  defp fetch_xml(dataset, opts, params) do
    agency = Utils.agency(dataset, opts)

    with {:ok, version} <- Utils.sdmx_version(agency, opts),
         {:ok, xml} <- Client.get(dataflow_path(version, agency, dataset), params, agency: agency) do
      XML.parse(xml)
    end
  end

  defp dataflow_path("3.0", agency, dataset),
    do: ["sdmx", "3.0", "structure", "dataflow", Client.agency_id(agency), dataset]

  defp dataflow_path("2.1", agency, dataset),
    do: ["sdmx", "2.1", "dataflow", Client.agency_id(agency), dataset]

  defp constraint_path("3.0", agency, dataset),
    do: ["sdmx", "3.0", "structure", "dataconstraint", Client.agency_id(agency), dataset]

  defp constraint_path("2.1", agency, dataset),
    do: ["sdmx", "2.1", "contentconstraint", Client.agency_id(agency), dataset]

  defp missing(dataset) do
    {:error, Error.new(:not_found, "No data structure found for #{dataset}")}
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp to_datetime(nil), do: nil

  defp to_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp doi(nil), do: nil

  defp doi(xml) do
    case Regex.run(~r"(10\.\d{4,}/[^<\"\s]+)", xml) do
      [_match, doi] -> doi
      nil -> nil
    end
  end
end
