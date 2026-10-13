defmodule Eurostatx.SDMX do
  @moduledoc false

  # Parsers for the SDMX-ML structure messages (2.1 and 3.0) used by
  # Eurostatx.Datasets, Eurostatx.Codelists and Eurostatx.Structure.
  #
  # SDMX 3.0 references other artefacts with URNs in the text of elements:
  #   <s:Enumeration>urn:sdmx:org.sdmx.infomodel.codelist.Codelist=ESTAT:FREQ(3.9)</s:Enumeration>
  # SDMX 2.1 uses Ref elements:
  #   <s:Enumeration><Ref agencyID="ESTAT" class="Codelist" id="FREQ" version="3.9"/></s:Enumeration>

  alias Eurostatx.XML

  @doc """
  Parses the first data structure definition (DSD) of a structure message.
  """
  def data_structure(root, language) do
    case XML.find(root, "DataStructure") do
      nil ->
        nil

      dsd ->
        components = XML.child(dsd, "DataStructureComponents")
        dimension_list = components && XML.child(components, "DimensionList")

        %{
          "id" => XML.attribute(dsd, "id"),
          "agency" => XML.attribute(dsd, "agencyID"),
          "version" => XML.attribute(dsd, "version"),
          "name" => XML.localized(dsd, "Name", language),
          "dimensions" =>
            dimension_list
            |> children("Dimension")
            |> Enum.with_index(1)
            |> Enum.map(&dimension/1),
          "time_dimension" =>
            dimension_list |> children("TimeDimension") |> List.first() |> XML.attribute("id"),
          "attributes" =>
            components
            |> XML.path(["AttributeList"])
            |> children("Attribute")
            |> Enum.map(&attribute/1),
          "measures" =>
            components
            |> XML.path(["MeasureList"])
            |> children(nil)
            |> Enum.filter(&(XML.local_name(&1) in ["Measure", "PrimaryMeasure"]))
            |> Enum.map(&XML.attribute(&1, "id"))
        }
    end
  end

  defp children(nil, _name), do: []
  defp children(element, name), do: XML.children(element, name)

  defp dimension({element, index}) do
    position = XML.attribute(element, "position")

    %{
      "id" => XML.attribute(element, "id"),
      "position" => if(position, do: String.to_integer(position), else: index),
      "concept" => element |> XML.child("ConceptIdentity") |> reference(),
      "codelist" => element |> XML.path(["LocalRepresentation", "Enumeration"]) |> reference()
    }
  end

  defp attribute(element) do
    relationship =
      element |> XML.child("AttributeRelationship") |> then(&(&1 && XML.children(&1)))

    %{
      "id" => XML.attribute(element, "id"),
      "concept" => element |> XML.child("ConceptIdentity") |> reference(),
      "codelist" => element |> XML.path(["LocalRepresentation", "Enumeration"]) |> reference(),
      "attached_to" => relationship |> List.wrap() |> List.first() |> attachment()
    }
  end

  # SDMX 2.1 attaches observation attributes to the PrimaryMeasure, 3.0 to the Observation
  defp attachment(nil), do: nil

  defp attachment(element) do
    case XML.local_name(element) do
      local when local in ["Observation", "PrimaryMeasure", "Measure"] -> "observation"
      local when local in ["None", "Dataflow"] -> "dataset"
      "Dimension" -> "dimension"
      "Group" -> "group"
      local -> String.downcase(local)
    end
  end

  @doc """
  Reads a reference to another artefact, either as a 2.1 `Ref` child element
  or as a 3.0 URN text. Returns `%{"agency", "id", "version"}` plus `"item"`
  for references to an item (concept, code...).
  """
  def reference(nil), do: nil

  def reference(element) do
    case XML.child(element, "Ref") do
      nil ->
        urn(XML.text(element))

      ref ->
        %{
          "agency" => XML.attribute(ref, "agencyID"),
          "id" => XML.attribute(ref, "maintainableParentID") || XML.attribute(ref, "id"),
          "version" =>
            XML.attribute(ref, "maintainableParentVersion") || XML.attribute(ref, "version"),
          "item" => if(XML.attribute(ref, "maintainableParentID"), do: XML.attribute(ref, "id"))
        }
    end
  end

  # urn:sdmx:org.sdmx.infomodel.conceptscheme.Concept=ESTAT:NAMA_10_GDP(118.1).freq
  defp urn(nil), do: nil

  defp urn(urn) do
    case Regex.run(~r/=([^:=]+):([^(]+)\(([^)]*)\)(?:\.(.+))?$/, urn) do
      [_match, agency, id, version] ->
        %{"agency" => agency, "id" => id, "version" => version, "item" => nil}

      [_match, agency, id, version, item] ->
        %{"agency" => agency, "id" => id, "version" => version, "item" => item}

      nil ->
        nil
    end
  end

  @doc """
  Parses the cube regions of the data constraints (3.0) or content
  constraints (2.1) of a structure message into a map of dimension => values.
  """
  def constraint(root) do
    root
    |> XML.find_all("CubeRegion")
    |> Enum.reject(&(XML.attribute(&1, "include") == "false"))
    |> Enum.flat_map(&XML.children(&1, "KeyValue"))
    |> Enum.reduce(%{}, fn key_value, acc ->
      values = key_value |> XML.children("Value") |> Enum.map(&XML.text/1)
      Map.update(acc, XML.attribute(key_value, "id"), values, &(&1 ++ values))
    end)
  end

  @doc "Parses every codelist of a structure message, keyed by id."
  def codelists(root, language) do
    root
    |> XML.find_all("Codelist")
    |> Map.new(fn codelist ->
      {XML.attribute(codelist, "id"),
       %{
         "id" => XML.attribute(codelist, "id"),
         "agency" => XML.attribute(codelist, "agencyID"),
         "version" => XML.attribute(codelist, "version"),
         "name" => XML.localized(codelist, "Name", language),
         "codes" =>
           codelist
           |> XML.children("Code")
           |> Enum.map(
             &%{"code" => XML.attribute(&1, "id"), "name" => XML.localized(&1, "Name", language)}
           )
       }}
    end)
  end

  @doc "Parses the concepts of every concept scheme, keyed by {scheme id, concept id}."
  def concepts(root, language) do
    for scheme <- XML.find_all(root, "ConceptScheme"),
        concept <- XML.children(scheme, "Concept"),
        into: %{} do
      {{XML.attribute(scheme, "id"), XML.attribute(concept, "id")},
       XML.localized(concept, "Name", language)}
    end
  end

  @doc """
  Lists the maintainable artefacts (dataflows, codelists...) of a structure
  message: id, agency, version and name.
  """
  def artefacts(root, type, language) do
    root
    |> XML.find_all(type)
    |> Enum.map(fn artefact ->
      %{
        "id" => XML.attribute(artefact, "id"),
        "agency" => XML.attribute(artefact, "agencyID"),
        "version" => XML.attribute(artefact, "version"),
        "name" => XML.localized(artefact, "Name", language)
      }
    end)
  end
end
