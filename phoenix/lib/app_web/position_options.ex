defmodule AppWeb.PositionOptions do
  @moduledoc """
  Options for choosing a post (the "Assign to a position" select), grouped
  by unit, each with its short label (`App.People.PositionLabel`) and who holds
  it: the holder's name for a single post, holders/strength for shared ones
  ("· 9/10"); posts with room first. Posts need `:organization` and
  current `assignments` with `:person` loaded.
  """
  use Gettext, backend: AppWeb.Gettext

  alias App.People.{Person, PositionLabel}

  @doc "`[{unit, [{label, position_id}]}]` for a grouped `<select>`."
  @spec grouped([map()]) :: [{String.t(), [{String.t(), Ash.UUID.t()}]}]
  def grouped(positions) do
    positions
    |> Enum.group_by(&((&1.organization && &1.organization.name) || gettext("No unit")))
    |> Enum.sort_by(fn {unit, _} -> unit end)
    |> Enum.map(fn {unit, posts} ->
      options =
        posts
        |> Enum.map(&option/1)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&elem(&1, 1))

      {unit, options}
    end)
  end

  defp option(post) do
    holders = Enum.filter(post.assignments, & &1.person)
    short = PositionLabel.short(AppWeb.PersonRows.position_summary(post))

    occupancy =
      case {post.strength, holders} do
        {1, [%{person: person}]} -> Person.full_name(person)
        {1, []} -> gettext("vacant")
        {strength, holders} -> "#{length(holders)}/#{strength}"
      end

    {{length(holders) >= post.strength, post.title, short}, {"#{short} · #{occupancy}", post.id}}
  end
end
