defmodule Eurostatx.XML do
  @moduledoc false

  # Small helpers on top of Saxy's simple form to read the SDMX-ML, RSS and
  # SOAP documents of the Eurostat APIs. Element names are matched by their
  # local name, ignoring namespace prefixes (`s:Dimension`, `str:Dimension`
  # and `Dimension` are the same element), so the same code reads SDMX 2.1
  # and 3.0 messages. No atoms are created from the documents.

  alias Eurostatx.Error

  @type element :: {String.t(), [{String.t(), String.t()}], [element() | String.t()]}

  @doc "Parses an XML document into Saxy's simple form."
  @spec parse(binary()) :: {:ok, element()} | {:error, Error.t()}
  def parse(xml) do
    case Saxy.SimpleForm.parse_string(xml) do
      {:ok, root} ->
        {:ok, root}

      {:error, error} ->
        {:error, Error.new(:decode_error, "Invalid XML: #{Exception.message(error)}")}
    end
  end

  @doc "Local name of an element, without its namespace prefix."
  @spec local_name(element() | String.t()) :: String.t()
  def local_name({name, _attributes, _children}), do: local_name(name)

  def local_name(name) when is_binary(name) do
    case String.split(name, ":", parts: 2) do
      [_prefix, local] -> local
      [local] -> local
    end
  end

  @doc "Direct child elements, optionally only the ones with a local name."
  @spec children(element(), String.t() | nil) :: [element()]
  def children(element, name \\ nil)

  def children({_name, _attributes, children}, nil), do: Enum.filter(children, &is_tuple/1)

  def children({_name, _attributes, children}, name) do
    Enum.filter(children, &(is_tuple(&1) and local_name(&1) == name))
  end

  @doc "First direct child element with a local name."
  @spec child(element(), String.t()) :: element() | nil
  def child(element, name), do: element |> children(name) |> List.first()

  @doc "Every descendant element with a local name, in document order."
  @spec find_all(element(), String.t()) :: [element()]
  def find_all({_name, _attributes, children}, name) do
    Enum.flat_map(children, fn
      {_child_name, _attributes, _children} = child ->
        if local_name(child) == name, do: [child], else: find_all(child, name)

      _text ->
        []
    end)
  end

  @doc "First descendant element with a local name."
  @spec find(element(), String.t()) :: element() | nil
  def find(element, name), do: element |> find_all(name) |> List.first()

  @doc "Follows a path of local names through direct children."
  @spec path(element() | nil, [String.t()]) :: element() | nil
  def path(element, []), do: element
  def path(nil, _names), do: nil
  def path(element, [name | rest]), do: element |> child(name) |> path(rest)

  @doc "Value of an attribute (by its full or local name)."
  @spec attribute(element() | nil, String.t()) :: String.t() | nil
  def attribute(nil, _name), do: nil

  def attribute({_name, attributes, _children}, name) do
    Enum.find_value(attributes, fn {key, value} ->
      if key == name or local_name(key) == name, do: value
    end)
  end

  @doc "Text content of an element (concatenated and trimmed), or nil."
  @spec text(element() | nil) :: String.t() | nil
  def text(nil), do: nil

  def text({_name, _attributes, children}) do
    text =
      children
      |> Enum.map_join(fn
        text when is_binary(text) -> text
        element -> text(element) || ""
      end)
      |> String.trim()

    if text == "", do: nil, else: text
  end

  @doc """
  Text of the localized child elements with a local name (`Name`,
  `Description`, `title`...) in `language`, falling back to English and then
  to the first one. The language is read from `xml:lang` or `language`.
  """
  @spec localized(element(), String.t(), String.t()) :: String.t() | nil
  def localized(element, name, language) do
    candidates =
      element
      |> children(name)
      |> Enum.map(&{attribute(&1, "lang") || attribute(&1, "language"), text(&1)})
      |> Enum.reject(fn {_language, text} -> is_nil(text) end)

    Enum.find_value(candidates, fn {lang, text} -> if lang == language, do: text end) ||
      Enum.find_value(candidates, fn {lang, text} -> if lang == "en", do: text end) ||
      Enum.find_value(candidates, fn {_lang, text} -> text end)
  end
end
