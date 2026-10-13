defmodule Eurostatx.Catalogue do
  @moduledoc """
  Functions for the [Catalogue API](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/catalogue-api),
  for dataset discovery.

    - The **table of contents** (TOC) is Eurostat's navigation tree: folders
      (themes and sections), datasets and pre-defined tables, with their last
      update, time coverage and number of values. `search/2` finds datasets in it.
    - The **RSS feed** lists the datasets and code lists created, updated or
      deleted in the last 7 days.
    - The **DCAT** catalogue describes every dataset in RDF (DCAT-AP), as sent
      to the [data.europa.eu](https://data.europa.eu) portal.
    - The **metabase** lists, for every dataset, the codes used by each dimension.

  Eurostat refreshes them twice a day, at 11:00 and 23:00 (Brussels time),
  when datasets are updated.

  ## Endpoints

    - `toc/1` - [`catalogue/toc/txt`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/catalogue-api/toc) or `catalogue/toc/xml` - The table of contents
    - `search/2` - Datasets and tables of the table of contents matching a text
    - `toc_schema/1` - [`catalogue/toc/TableOfContent.xsd`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/catalogue-api/toc) - The XML schema of the table of contents
    - `rss/1` - [`catalogue/rss/{lang}/statistics-update.rss`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/catalogue-api/rss) - The latest updates
    - `dcat/2` - [`catalogue/dcat/{agency}/{FULL|UPDATES}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/catalogue-api/dcat) - The DCAT-AP catalogue
    - `metabase/1` - [`catalogue/metabase.txt.gz`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-detailed-guidelines/catalogue-api/metabase) - The codes used by every dataset
    - `metabase_as_data_frame/1` - The metabase as an `Explorer.DataFrame`

  The REDISSTAT agencies only serve the DCAT catalogue.
  """

  alias Eurostatx.Catalogue.TOCHandler
  alias Eurostatx.Client
  alias Eurostatx.Error
  alias Eurostatx.Utils
  alias Eurostatx.XML
  alias Explorer.DataFrame, as: DF

  NimbleCSV.define(Eurostatx.Catalogue.TSVParser, separator: "\t", escape: "\"", moduledoc: false)

  alias Eurostatx.Catalogue.TSVParser

  @toc_schema Utils.schema([
                :language,
                {:format,
                 [
                   type: {:in, [:txt, :xml]},
                   default: :txt,
                   doc:
                     "`:txt` (default, about 2 MB per language) or `:xml` (multilingual, about " <>
                       "23 MB, with the units, sources, descriptions and metadata links).",
                   type_doc: "`:txt | :xml`"
                 ]}
              ])

  @search_schema Utils.schema([
                   :language,
                   {:types,
                    [
                      type: {:list, {:in, [:dataset, :table, :folder]}},
                      default: [:dataset, :table],
                      doc: "Types of items to return: `:dataset`, `:table` and/or `:folder`."
                    ]},
                   {:toc,
                    [
                      type: {:list, {:map, :string, :any}},
                      doc:
                        "A table of contents previously fetched with `toc/1`, to search it " <>
                          "without downloading it again."
                    ]}
                 ])

  @rss_schema Utils.schema([:language])
  @dcat_schema Utils.schema([
                 :agency,
                 {:raw,
                  [
                    type: :boolean,
                    default: false,
                    doc: "Return the ZIP archive as a binary instead of its files."
                  ]}
               ])
  @metabase_schema Utils.schema([
                     {:datasets,
                      [
                        type: {:list, :string},
                        doc:
                          "Only keep these datasets (codes are case-insensitive). The whole " <>
                            "file is downloaded anyway (about 4 MB compressed, 1.3 million lines)."
                      ]}
                   ])

  @doc """
  Gets the table of contents: every folder, dataset and table of the Eurostat
  navigation tree, in tree order.

  Every item is a map with:

    - `"code"`, `"title"` and `"type"` (`"folder"`, `"dataset"` or `"table"`)
    - `"level"` (0 for the root) and `"parent"` (the code of its folder)
    - `"last_update"` and `"last_structure_change"` (`Date`s)
    - `"data_start"` and `"data_end"` (periods, e.g. `"1991-Q1"`)
    - `"values"` (the number of values, integer)

  The XML format adds `"unit"`, `"source"`, `"short_description"`,
  `"metadata_html"`, `"metadata_sdmx"`, `"download_tsv"` and `"download_sdmx"`.
  Titles and descriptions follow `:language`.

  Datasets can appear in several folders, so their codes are not unique.

  ## Options

  #{NimbleOptions.docs(@toc_schema)}

  ## Examples

      iex> {:ok, toc} = Eurostatx.Catalogue.toc()
      iex> Enum.find(toc, &(&1["code"] == "nama_10_gdp"))
      %{
        "code" => "nama_10_gdp",
        "title" => "Gross domestic product (GDP) and main components (output, expenditure and income) - annual data",
        "type" => "dataset",
        "level" => 4,
        "parent" => "ei_qna",
        "last_update" => ~D[2026-10-09],
        "last_structure_change" => ~D[2026-09-08],
        "data_start" => "1975",
        "data_end" => "2025",
        "values" => 1084124
      }
  """
  @spec toc(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def toc(opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @toc_schema) do
      case opts[:format] do
        :txt -> toc_txt(Utils.language(opts))
        :xml -> toc_xml(Utils.language(opts))
      end
    end
  end

  defp toc_txt(language) do
    with {:ok, txt} <-
           Client.get(["catalogue", "toc", "txt"], [{"lang", language}], decode: :text) do
      rows = TSVParser.parse_string(txt, skip_headers: true)

      {items, _stack} =
        Enum.map_reduce(rows, [], fn row, stack ->
          [title, code, type, last_update, last_change, data_start, data_end, values] =
            Enum.take(row ++ List.duplicate("", 8), 8)

          level = div(String.length(title) - String.length(String.trim_leading(title)), 4)
          {parent, stack} = parent(stack, level, String.trim(code))

          item = %{
            "code" => String.trim(code),
            "title" => String.trim(title),
            "type" => String.trim(type),
            "level" => level,
            "parent" => parent,
            "last_update" => toc_date(last_update),
            "last_structure_change" => toc_date(last_change),
            "data_start" => blank_to_nil(data_start),
            "data_end" => blank_to_nil(data_end),
            "values" => toc_integer(values)
          }

          {item, stack}
        end)

      {:ok, items}
    end
  end

  # The stack keeps the {level, code} of the current branch of the tree
  defp parent(stack, level, code) do
    stack = Enum.drop_while(stack, fn {stack_level, _code} -> stack_level >= level end)

    parent =
      case stack do
        [{_level, parent} | _rest] -> parent
        [] -> nil
      end

    {parent, [{level, code} | stack]}
  end

  defp toc_xml(language) do
    with {:ok, xml} <- Client.get(["catalogue", "toc", "xml"], [], decode: :text) do
      case Saxy.parse_string(xml, TOCHandler, TOCHandler.initial_state(language)) do
        {:ok, items} ->
          {:ok, items}

        {:error, error} ->
          {:error, Error.new(:decode_error, "Invalid XML: #{Exception.message(error)}")}
      end
    end
  end

  @doc """
  Searches the datasets and tables of the table of contents whose code or
  title contains a text (case-insensitive) or match a regular expression.

  Each dataset is returned once, even if it appears in several folders.

  ## Options

  #{NimbleOptions.docs(@search_schema)}

  ## Examples

      iex> {:ok, results} = Eurostatx.Catalogue.search("unemployment by sex and age")
      iex> results |> Enum.map(&{&1["code"], &1["title"]}) |> Enum.take(2)
      [
        {"une_rt_a_h", "Unemployment by sex and age - annual data (1992–2020)"},
        {"une_rt_q_h", "Unemployment by sex and age - quarterly data (1992–2020)"}
      ]

      iex> {:ok, toc} = Eurostatx.Catalogue.toc()
      iex> {:ok, results} = Eurostatx.Catalogue.search(~r/^tps0000[1-3]$/, toc: toc)
      iex> Enum.map(results, & &1["code"])
      ["tps00003", "tps00001"]
  """
  @spec search(String.t() | Regex.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def search(query, opts \\ []) when is_binary(query) or is_struct(query, Regex) do
    with {:ok, opts} <- Utils.validate(opts, @search_schema),
         {:ok, toc} <- search_toc(opts) do
      types = Enum.map(opts[:types], &to_string/1)
      matches? = matcher(query)

      results =
        toc
        |> Enum.filter(
          &(&1["type"] in types and (matches?.(&1["code"]) or matches?.(&1["title"])))
        )
        |> Enum.uniq_by(& &1["code"])

      {:ok, results}
    end
  end

  defp search_toc(opts) do
    case opts[:toc] do
      nil -> toc(Keyword.take(opts, [:language]))
      toc -> {:ok, toc}
    end
  end

  defp matcher(%Regex{} = regex), do: &(is_binary(&1) and Regex.match?(regex, &1))

  defp matcher(text) do
    text = String.downcase(text)
    &(is_binary(&1) and String.contains?(String.downcase(&1), text))
  end

  @doc """
  Gets the XML schema (XSD) of the XML table of contents, as a binary.

  ## Examples

      iex> {:ok, "<?xml" <> _} = Eurostatx.Catalogue.toc_schema()
  """
  @spec toc_schema(keyword()) :: Client.response()
  def toc_schema(_opts \\ []) do
    Client.get(["catalogue", "toc", "TableOfContent.xsd"], [], decode: :text)
  end

  @doc """
  Gets the RSS feed with the datasets and code lists created, updated or
  deleted in the last 7 days.

  Returns the `"title"`, `"description"`, `"language"` and `"pub_date"` of the
  feed and its `"items"`, sorted by date (newest first). Every item has:

    - `"code"` - the code of the dataset or code list, in uppercase
    - `"category"` - the event: `NEW_DATASET`, `DELETED_DATASET`,
      `UPDATED_DATASET_DATA`, `UPDATED_DATASET_STRUCTURE`,
      `UPDATED_DATASET_STRUCTURE_DATA`, `NEW_CODE_LIST`, `UPDATED_CODE_LIST` or
      `DELETED_CODE_LIST`
    - `"title"`, `"description"` (the title of the dataset or code list) and `"link"`
    - `"pub_date"` - a `NaiveDateTime` (Brussels time)

  ## Options

  #{NimbleOptions.docs(@rss_schema)}

  ## Examples

      iex> {:ok, %{"items" => [item | _]}} = Eurostatx.Catalogue.rss()
      iex> item
      %{
        "code" => "AVIA_TF_ACA",
        "category" => "UPDATED_DATASET_DATA",
        "title" => "AVIA_TF_ACA - \\"Dataset: updated data\\"",
        "description" => "Air transport by aircraft model, transport coverage and main airports",
        "link" => "https://ec.europa.eu/eurostat/databrowser/product/page/AVIA_TF_ACA",
        "pub_date" => ~N[2026-10-13 11:23:00.0]
      }
  """
  @spec rss(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def rss(opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @rss_schema),
         {:ok, xml} <-
           Client.get(
             ["catalogue", "rss", Utils.language(opts), "statistics-update.rss"],
             [],
             decode: :text
           ),
         {:ok, root} <- XML.parse(xml),
         {_name, _attributes, _children} = channel <-
           XML.child(root, "channel") || invalid_rss() do
      items =
        channel
        |> XML.children("item")
        |> Enum.map(fn item ->
          title = item |> XML.child("title") |> XML.text()

          %{
            "code" => title && title |> String.split(" - ", parts: 2) |> hd() |> String.trim(),
            "category" => item |> XML.child("category") |> XML.text(),
            "title" => title,
            "description" => item |> XML.child("description") |> XML.text(),
            "link" => item |> XML.child("link") |> XML.text(),
            "pub_date" => item |> XML.child("pubDate") |> XML.text() |> to_naive_datetime()
          }
        end)

      {:ok,
       %{
         "title" => channel |> XML.child("title") |> XML.text(),
         "description" => channel |> XML.child("description") |> XML.text(),
         "language" => channel |> XML.child("language") |> XML.text(),
         "pub_date" => channel |> XML.child("pubDate") |> XML.text() |> to_naive_datetime(),
         "items" => items
       }}
    end
  end

  defp invalid_rss, do: {:error, Error.new(:decode_error, "Invalid RSS feed: no channel")}

  @doc """
  Gets the catalogue of datasets in RDF, following the DCAT application
  profile for data portals in Europe (DCAT-AP).

  `extraction` is `:full` (every dataset, the default) or `:updates` (the
  datasets updated since the last release). The catalogue is a ZIP archive
  with a `manifest.xml` and one RDF file per dataset; it is unzipped in memory
  and returned as a list of `{path, content}` tuples, unless `raw: true`.

  ## Options

  #{NimbleOptions.docs(@dcat_schema)}

  ## Examples

      iex> {:ok, files} = Eurostatx.Catalogue.dcat(:updates)
      iex> files |> Enum.map(&elem(&1, 0)) |> Enum.take(2)
      ["manifest.xml", "datasets/nasq_10_f_cp.rdf"]

      iex> {:ok, <<"PK", _rest::binary>>} = Eurostatx.Catalogue.dcat(:full, raw: true)
  """
  @spec dcat(:full | :updates, keyword()) ::
          {:ok, [{String.t(), binary()}] | binary()} | {:error, Error.t()}
  def dcat(extraction \\ :full, opts \\ []) when extraction in [:full, :updates] do
    with {:ok, opts} <- Utils.validate(opts, @dcat_schema),
         agency = opts[:agency] || :eurostat,
         {:ok, zip} <-
           Client.get(
             [
               "catalogue",
               "dcat",
               Client.agency_id(agency),
               extraction |> to_string() |> String.upcase()
             ],
             [],
             agency: agency,
             decode: :binary
           ) do
      if opts[:raw], do: {:ok, zip}, else: unzip(zip)
    end
  end

  defp unzip(zip) do
    case :zip.unzip(zip, [:memory]) do
      {:ok, files} ->
        {:ok,
         files
         |> Enum.map(fn {path, content} -> {to_string(path), content} end)
         |> Enum.reject(fn {path, _content} -> String.ends_with?(path, "/") end)}

      {:error, reason} ->
        {:error, Error.new(:decode_error, "Invalid ZIP archive: #{inspect(reason)}")}
    end
  end

  @doc """
  Gets the metabase: the codes used by every dimension of every dataset.

  Returns a map of dataset code to a map of dimension code to the list of
  codes, in the order of the file (time periods are in descending order).
  Dataset and dimension codes are lowercase, as in the file. The time
  dimension is `"time"`, and the frequency (`freq`) is not included.

  ## Options

  #{NimbleOptions.docs(@metabase_schema)}

  ## Examples

      iex> {:ok, metabase} = Eurostatx.Catalogue.metabase(datasets: ["nama_10_gdp"])
      iex> metabase["nama_10_gdp"] |> Map.keys()
      ["geo", "na_item", "time", "unit"]
      iex> metabase["nama_10_gdp"]["time"] |> Enum.take(3)
      ["2025", "2024", "2023"]
  """
  @spec metabase(keyword()) ::
          {:ok, %{String.t() => %{String.t() => [String.t()]}}} | {:error, Error.t()}
  def metabase(opts \\ []) do
    with {:ok, rows} <- metabase_rows(opts) do
      metabase =
        rows
        |> Enum.reduce(%{}, &add_metabase_row/2)
        |> Map.new(fn {dataset, dimensions} -> {dataset, reverse_codes(dimensions)} end)

      {:ok, metabase}
    end
  end

  defp add_metabase_row({dataset, dimension, code}, metabase) do
    Map.update(metabase, dataset, %{dimension => [code]}, fn dimensions ->
      Map.update(dimensions, dimension, [code], &[code | &1])
    end)
  end

  defp reverse_codes(dimensions) do
    Map.new(dimensions, fn {dimension, codes} -> {dimension, Enum.reverse(codes)} end)
  end

  @doc """
  Same as `metabase/1` except that it returns an `Explorer.DataFrame` with
  the columns `dataset`, `dimension` and `code`, one row per line of the file.

  ## Options

  #{NimbleOptions.docs(@metabase_schema)}
  """
  @spec metabase_as_data_frame(keyword()) :: {:ok, DF.t()} | {:error, Error.t()}
  def metabase_as_data_frame(opts \\ []) do
    with {:ok, rows} <- metabase_rows(opts) do
      {datasets, dimensions, codes} =
        rows
        |> Enum.reduce({[], [], []}, fn {dataset, dimension, code}, {ds, dims, cs} ->
          {[dataset | ds], [dimension | dims], [code | cs]}
        end)

      {:ok,
       DF.new(
         dataset: Enum.reverse(datasets),
         dimension: Enum.reverse(dimensions),
         code: Enum.reverse(codes)
       )}
    end
  end

  defp metabase_rows(opts) do
    with {:ok, opts} <- Utils.validate(opts, @metabase_schema),
         {:ok, text} <- Client.get(["catalogue", "metabase.txt.gz"], [], decode: :text) do
      keep = opts[:datasets] && MapSet.new(opts[:datasets], &String.downcase/1)

      rows =
        for line <- :binary.split(text, "\n", [:global]),
            [dataset, dimension, code] <- [:binary.split(line, "\t", [:global])],
            is_nil(keep) or MapSet.member?(keep, String.downcase(dataset)),
            do: metabase_row(dataset, dimension, code, keep)

      {:ok, rows}
    end
  end

  # Without a filter, rows reference the whole file. With a filter they are
  # copied, so that the file can be garbage collected.
  defp metabase_row(dataset, dimension, code, nil), do: {dataset, dimension, String.trim(code)}

  defp metabase_row(dataset, dimension, code, _keep) do
    {:binary.copy(dataset), :binary.copy(dimension), :binary.copy(String.trim(code))}
  end

  defp toc_date(value) do
    case String.split(String.trim(value), ".") do
      [day, month, year] ->
        with {day, ""} <- Integer.parse(day),
             {month, ""} <- Integer.parse(month),
             {year, ""} <- Integer.parse(year),
             {:ok, date} <- Date.new(year, month, day) do
          date
        else
          _invalid -> nil
        end

      _other ->
        nil
    end
  end

  defp toc_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp to_naive_datetime(nil), do: nil

  defp to_naive_datetime(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  @doc false
  # Exposed for Eurostatx.Catalogue.TOCHandler
  def __toc_date__(value), do: toc_date(value)

  @doc false
  def __toc_integer__(value), do: toc_integer(value)
end
