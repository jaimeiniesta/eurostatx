defmodule Eurostatx.Files do
  @moduledoc """
  Functions for the files API (`api/dissemination/files`), which replaced the
  former Bulk Download Listing in October 2023. See
  [Migrating from Bulkdownload](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-migrating/bulkdownload).

  It serves:

    - the **inventories** of datasets and code lists, with their last change
      and their download links, which are handy to automate periodic
      downloads (see the [examples](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-faq/examples));
    - the files of the `comext` folder (bulk Comext data) and the `metadata`
      folder (reference metadata in SDMX, `*_esms.sdmx.zip`), and their
      directory listings.

  Datasets and code lists are not downloaded from here anymore: use
  `Eurostatx.Data` and `Eurostatx.Codelists` (or the download links of the
  inventory).

  ## Endpoints

    - `inventory/1` - [`files/inventory?type={data|codelist}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-migrating/bulkdownload) - Inventory of datasets or code lists
    - `list/2` - [`files?format=csv&dir={dir}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-migrating/bulkdownload) - Directory listing
    - `download/2` - [`files?file={path}`](https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access/api-migrating/bulkdownload) - Downloads a file
  """

  alias Eurostatx.Client
  alias Eurostatx.Error
  alias Eurostatx.Utils

  @inventory_schema Utils.schema([
                      :language,
                      {:type,
                       [
                         type: {:in, [:data, :codelist]},
                         default: :data,
                         doc: "`:data` (datasets and tables, default) or `:codelist`.",
                         type_doc: "`:data | :codelist`"
                       ]}
                    ])

  @list_schema Utils.schema([
                 {:sort,
                  [
                    type: {:in, [:name, :date, :size]},
                    doc: "Sort by `:name` (default), `:date` or `:size`.",
                    type_doc: "`:name | :date | :size`"
                  ]},
                 {:order,
                  [
                    type: {:in, [:asc, :desc]},
                    doc: "`:asc` (default) or `:desc`.",
                    type_doc: "`:asc | :desc`"
                  ]},
                 {:hierarchy,
                  [
                    type: :boolean,
                    doc:
                      "List the subdirectories recursively. Names are then relative to `dir`, " <>
                        "and `:sort` and `:order` are ignored."
                  ]}
               ])

  @doc """
  Gets the inventory of datasets (`type: :data`) or code lists
  (`type: :codelist`).

  Returns one map per item, with the columns of the inventory file as keys,
  untouched. For datasets: `"Code"`, `"Type"`, `"Source dataset"`,
  `"Last data change"`, `"Last structural change"`,
  `"Data download url (tsv)"`, `"Data download url (csv)"`,
  `"Data download url (sdmx)"`, `"Data structure download url"` and
  `"Open in Data Browser url"`.

  ## Options

  #{NimbleOptions.docs(@inventory_schema)}

  ## Examples

      iex> {:ok, [dataset | _]} = Eurostatx.Files.inventory()
      iex> Map.take(dataset, ["Code", "Type", "Last data change"])
      %{"Code" => "AACT_ALI01", "Type" => "DATASET", "Last data change" => "2026-05-13T11:00:00+0200"}

      iex> {:ok, [%{"Code" => "ACCIDENT", "Version" => _} | _]} = Eurostatx.Files.inventory(type: :codelist)
  """
  @spec inventory(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def inventory(opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @inventory_schema),
         {:ok, tsv} <-
           Client.get(
             ["files", "inventory"],
             [{"type", opts[:type]}, {"lang", Utils.language(opts)}],
             decode: :text
           ) do
      case tsv |> String.split(["\r\n", "\n"], trim: true) |> Enum.map(&String.split(&1, "\t")) do
        [] ->
          {:ok, []}

        [header | rows] ->
          {:ok,
           Enum.map(
             rows,
             &(header |> Enum.zip(&1 ++ List.duplicate("", length(header))) |> Map.new())
           )}
      end
    end
  end

  @doc """
  Lists the content of a directory (`""` for the root, `"comext"`,
  `"metadata"`...).

  Every entry has a `"name"`, a `"path"` (to pass to `download/2`), a
  `"type"` (`"DIR"` for directories, the extension of the file otherwise), its
  `"size"` in bytes (`nil` for directories) and its last modification
  `"date"` (`DateTime`).

  ## Options

  #{NimbleOptions.docs(@list_schema)}

  ## Examples

      iex> {:ok, [file | _]} = Eurostatx.Files.list("metadata", sort: :date, order: :desc)
      iex> file
      %{
        "name" => "rd_esms.sdmx.zip",
        "path" => "metadata/rd_esms.sdmx.zip",
        "type" => "sdmx",
        "size" => 707365,
        "date" => ~U[2026-10-13 15:16:58.478Z]
      }
  """
  @spec list(String.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(dir \\ "", opts \\ []) do
    with {:ok, opts} <- Utils.validate(opts, @list_schema),
         {:ok, csv} <-
           Client.get(
             ["files", ""],
             [
               {"format", "csv"},
               {"dir", dir},
               {"sort", opts[:sort]},
               {"order", opts[:order]},
               {"hierarchy", opts[:hierarchy]},
               {"dateFormat", "ISO"},
               {"sizeFormat", "NONE"}
             ],
             decode: :text
           ) do
      dir = String.trim(dir, "/")

      entries =
        csv
        |> NimbleCSV.RFC4180.parse_string(skip_headers: true)
        |> Enum.map(fn [name, size, type, date | _rest] ->
          %{
            "name" => name,
            "path" => if(dir == "", do: name, else: dir <> "/" <> name),
            "type" => type,
            "size" => to_integer(size),
            "date" => to_datetime(date)
          }
        end)

      {:ok, entries}
    end
  end

  @doc """
  Downloads a file, given its path relative to the root of the files API.
  Returns the content as a binary, untouched (ZIP and 7z archives are not
  extracted). Missing files return an error of type `:not_found`.

  ## Examples

      iex> {:ok, <<"PK", _rest::binary>>} = Eurostatx.Files.download("metadata/nama_10_gdp_esms.sdmx.zip")

      iex> {:error, %Eurostatx.Error{type: :not_found}} = Eurostatx.Files.download("metadata/nope.zip")
  """
  @spec download(String.t(), keyword()) :: Client.response()
  def download(path, _opts \\ []) when is_binary(path) do
    Client.get(["files", ""], [{"file", path}], decode: :binary)
  end

  defp to_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> nil
    end
  end

  defp to_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end
end
