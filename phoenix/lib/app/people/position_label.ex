defmodule App.People.PositionLabel do
  @moduledoc """
  Short, one-line labels for posts in lists where many look alike: the
  title, then the unit abbreviated segment by segment, then the grade,
  joined by `delimiter/0`:

      "Rifleman", "A Company, 1 Bn", "OR-3"            -> "Rifleman A.Co¦1Bn¦OR-3"
      "Physician", "Role 3 Field Hospital", "OF-3"     -> "Physician R.3¦F.H.¦OF-3"

  Unit abbreviation: the name splits at commas and after a number
  ("Role 3 | Field Hospital"); in each segment known unit words become
  their military abbreviation (Company → Co, Battalion → Bn, …), numbers
  and ordinals stay, other words become their initial with a dot; a number
  directly before a unit word is written together (1Bn). The full title,
  unit and grade stay available on hover (`AppWeb.PersonBadges.position`).

  In the domain, not the web layer: the label is also how sheet imports
  name a post (`App.People.AssignmentSync`), so both sides must agree.
  """

  # Broken bar: visibly a separator, never part of a title or unit name,
  # plain UTF-8 text (safe in HTML, option labels and tooltips).
  @delimiter "¦"

  @unit_words %{
    "company" => "Co",
    "battalion" => "Bn",
    "bn" => "Bn",
    "brigade" => "Bde",
    "bde" => "Bde",
    "platoon" => "Plt",
    "squad" => "Sqd",
    "section" => "Sect",
    "regiment" => "Regt",
    "division" => "Div",
    "squadron" => "Sqn",
    "battery" => "Bty",
    "headquarters" => "HQ",
    "hq" => "HQ"
  }

  @doc "The separator between label parts."
  @spec delimiter() :: String.t()
  def delimiter, do: @delimiter

  @doc "`title unit¦grade` for a post (`%{title, organization, grade}`)."
  @spec short(map()) :: String.t()
  def short(%{title: title} = post) do
    tail =
      [unit(post[:organization]), post[:grade]]
      |> List.flatten()
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(@delimiter)

    if tail == "", do: title, else: "#{title} #{tail}"
  end

  @doc "The short label of a `Position` (with `:organization` loaded)."
  @spec for_position(map()) :: String.t()
  def for_position(position) do
    short(%{
      title: position.title,
      organization: organization_name(position.organization),
      grade: position.authorised_grade
    })
  end

  defp organization_name(%{name: name}), do: name
  defp organization_name(_not_loaded), do: nil

  @doc ~S'Abbreviated unit segments: "A Company, 1 Bn" -> ["A.Co", "1Bn"].'
  @spec unit(String.t() | nil) :: [String.t()]
  def unit(nil), do: []

  def unit(name) do
    name
    |> String.split(",", trim: true)
    |> Enum.flat_map(&split_after_number/1)
    |> Enum.map(&abbreviate_segment/1)
    |> Enum.reject(&(&1 == ""))
  end

  # "Role 3 Field Hospital" -> ["Role 3", "Field Hospital"]
  defp split_after_number(segment) do
    segment
    |> String.split(~r/\s+/, trim: true)
    |> Enum.chunk_while(
      [],
      fn word, acc ->
        acc = [word | acc]

        if number?(word) and length(acc) > 1,
          do: {:cont, Enum.reverse(acc), []},
          else: {:cont, acc}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.map(&Enum.join(&1, " "))
  end

  defp abbreviate_segment(segment) do
    segment
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map(&token/1)
    |> join_tokens()
  end

  defp token(word) do
    cond do
      unit = @unit_words[String.downcase(word)] -> {:unit, unit}
      number?(word) -> {:number, word}
      String.length(word) == 1 -> {:letter, String.upcase(word)}
      true -> {:initial, String.first(word) |> String.upcase()}
    end
  end

  # Numbers stick to a following unit word (1Bn); a single letter or an
  # initial takes a dot before whatever follows (A.Co, R.3); initials
  # always end with a dot (F.H.).
  defp join_tokens(tokens) do
    tokens
    |> Enum.chunk_every(2, 1)
    |> Enum.map_join(fn
      [{:number, n}, {:unit, _}] -> n
      [{:initial, i} | _] -> i <> "."
      [{kind, text}, _next] when kind in [:letter, :number, :unit] -> text <> "."
      [{_kind, text}] -> text
    end)
  end

  defp number?(word), do: word =~ ~r/^\d+(st|nd|rd|th)?$/i
end
