defmodule AppWeb.SheetPerson do
  @moduledoc """
  SHEETS-UI.16 (docs/design/sheets-ui.md): who the selected row is about,
  in the sidebar — photo, name, PersonID, current post and the documents
  about them still open (drafts and in approval), with links into the
  app. Read as the viewer, through the policies; the documents' contents
  are not read (no access-log entries for a glance).
  """
  use AppWeb, :html

  require Ash.Query

  alias App.People.{Person, PersonId}
  alias AppWeb.{PersonBadges, PersonRows}

  @doc "What the summary shows about `person`, read as `actor`."
  @spec load(Person.t(), map()) :: map()
  def load(person, actor) do
    post =
      App.People.Assignment
      |> Ash.Query.filter(person_id == ^person.id and is_nil(ends_on))
      |> Ash.Query.load(position: :organization)
      |> Ash.read!(actor: actor)
      |> Enum.find_value(&(&1.position && PersonRows.position_summary(&1.position)))

    open =
      App.Documents.Document
      |> Ash.Query.filter(person_id == ^person.id and state in [:draft, :in_review])
      |> Ash.count!(actor: actor)

    %{person: person, photo_url: PersonRows.photo_url(person, actor), post: post, open: open}
  end

  attr :summary, :map, required: true
  attr :id, :string, required: true
  attr :target, :any, default: nil, doc: "where the Record card button sends `card` (SHEETS-UI.3)"

  def summary(assigns) do
    ~H"""
    <div id={@id} class="flex items-start gap-2 text-sm">
      <PersonBadges.avatar
        name={Person.full_name(@summary.person)}
        key={@summary.person.id}
        photo_url={@summary.photo_url}
      />
      <div class="flex min-w-0 grow flex-col gap-0.5">
        <div class="flex items-center justify-between gap-1">
          <span class="truncate font-medium">{Person.full_name(@summary.person)}</span>
          <button
            :if={@target}
            type="button"
            id={"#{@id}-card"}
            phx-click="card"
            phx-value-id={@summary.person.id}
            phx-target={@target}
            class="btn btn-ghost btn-xs btn-square ml-auto shrink-0"
            aria-label={gettext("Record card in the sheet")}
            data-float-tip={gettext("Record card in the sheet")}
          >
            <.icon name="hero-document-text" class="size-4" />
          </button>
          <.link
            href={~p"/people/#{@summary.person.id}"}
            target="_blank"
            rel="noopener"
            class="btn btn-ghost btn-xs btn-square shrink-0"
            aria-label={gettext("Open in the app")}
            data-float-tip={gettext("Open in the app")}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
        <span class="text-xs tabular-nums opacity-70">
          {PersonId.format(@summary.person.person_id)}
        </span>
        <PersonBadges.position :if={@summary.post} position={@summary.post} />
        <.link
          :if={@summary.open > 0}
          href={~p"/people/#{@summary.person.id}"}
          target="_blank"
          rel="noopener"
          class="link text-xs"
        >
          {ngettext(
            "%{count} document open (draft or in approval)",
            "%{count} documents open (draft or in approval)",
            @summary.open
          )}
        </.link>
      </div>
    </div>
    """
  end
end
