defmodule Eurostatx.Catalogue.TOCHandler do
  @moduledoc false

  # Saxy handler that reads the XML table of contents
  # (catalogue/toc/xml, about 23 MB) without building the whole tree:
  #
  #   <nt:branch>                      folders
  #     <nt:title language="en">...</nt:title>
  #     <nt:code>general</nt:code>
  #     <nt:children>
  #       <nt:leaf type="dataset">     datasets and tables
  #         <nt:title language="en">...</nt:title>
  #         <nt:code>nama_10_gdp</nt:code>
  #         <nt:lastUpdate>09.10.2026</nt:lastUpdate>
  #         <nt:metadata format="html">...</nt:metadata>
  #         <nt:downloadLink format="tsv">...</nt:downloadLink>
  #         ...

  @behaviour Saxy.Handler

  alias Eurostatx.Catalogue

  # Element => key of the item. Localized elements keep the requested language.
  @localized %{
    "title" => "title",
    "unit" => "unit",
    "source" => "source",
    "shortDescription" => "short_description"
  }

  @plain %{
    "code" => "code",
    "lastUpdate" => "last_update",
    "lastModified" => "last_structure_change",
    "dataStart" => "data_start",
    "dataEnd" => "data_end",
    "values" => "values"
  }

  @by_format %{
    {"metadata", "html"} => "metadata_html",
    {"metadata", "sdmx"} => "metadata_sdmx",
    {"downloadLink", "tsv"} => "download_tsv",
    {"downloadLink", "sdmx"} => "download_sdmx"
  }

  def initial_state(language) do
    # stack: items being read (innermost first); field: {key, language} of the
    # element whose text is being read; text: its characters; items: results
    %{language: language, stack: [], field: nil, text: [], items: [], position: 0}
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  def handle_event(:end_document, _data, state) do
    items =
      state.items
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&finish(&1, state.language))

    {:ok, items}
  end

  def handle_event(:start_element, {name, attributes}, state) do
    case local(name) do
      node when node in ["branch", "leaf"] ->
        parent = List.first(state.stack)

        item = %{
          position: state.position,
          level: length(state.stack),
          parent: parent && parent.fields["code"],
          type: if(node == "branch", do: "folder", else: attribute(attributes, "type")),
          fields: %{},
          localized: %{}
        }

        {:ok, %{state | stack: [item | state.stack], position: state.position + 1}}

      local ->
        {:ok, %{state | field: field(local, attributes), text: []}}
    end
  end

  def handle_event(:characters, chars, %{field: field} = state) when not is_nil(field) do
    {:ok, %{state | text: [state.text | chars]}}
  end

  def handle_event(:characters, _chars, state), do: {:ok, state}

  def handle_event(:end_element, name, state) do
    case {local(name), state.stack} do
      {node, [item | rest]} when node in ["branch", "leaf"] ->
        {:ok, %{state | stack: rest, items: [item | state.items], field: nil}}

      {_local, [item | rest]} when not is_nil(state.field) ->
        item = store(item, state.field, state.text |> IO.iodata_to_binary() |> String.trim())
        {:ok, %{state | stack: [item | rest], field: nil, text: []}}

      _other ->
        {:ok, %{state | field: nil, text: []}}
    end
  end

  defp field(local, attributes) do
    cond do
      key = @localized[local] -> {:localized, key, attribute(attributes, "language")}
      key = @plain[local] -> {:plain, key}
      key = @by_format[{local, attribute(attributes, "format")}] -> {:plain, key}
      true -> nil
    end
  end

  defp store(item, _field, ""), do: item

  defp store(item, {:plain, key}, text), do: %{item | fields: Map.put(item.fields, key, text)}

  defp store(item, {:localized, key, language}, text) do
    %{item | localized: Map.put(item.localized, {key, language}, text)}
  end

  # Items keep every language until the end, where the requested one is picked
  # (falling back to English)
  defp finish(item, language) do
    localized =
      for key <- Map.values(@localized), into: %{} do
        {key, item.localized[{key, language}] || item.localized[{key, "en"}]}
      end

    fields = item.fields

    Map.merge(localized, %{
      "code" => fields["code"],
      "type" => item.type,
      "level" => item.level,
      "parent" => item.parent,
      "last_update" => fields["last_update"] && Catalogue.__toc_date__(fields["last_update"]),
      "last_structure_change" =>
        fields["last_structure_change"] && Catalogue.__toc_date__(fields["last_structure_change"]),
      "data_start" => fields["data_start"],
      "data_end" => fields["data_end"],
      "values" => fields["values"] && Catalogue.__toc_integer__(fields["values"]),
      "metadata_html" => fields["metadata_html"],
      "metadata_sdmx" => fields["metadata_sdmx"],
      "download_tsv" => fields["download_tsv"],
      "download_sdmx" => fields["download_sdmx"]
    })
  end

  defp attribute(attributes, name) do
    Enum.find_value(attributes, fn {key, value} -> if key == name, do: value end)
  end

  defp local(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [local] -> local
    end
  end
end
