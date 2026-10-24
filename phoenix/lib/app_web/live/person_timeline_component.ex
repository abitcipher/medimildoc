defmodule AppWeb.PersonTimelineComponent do
  @moduledoc """
  The person's timeline tab (docs/design/search-timeline-notifications.md
  §Timeline): `App.Timeline.for_person/2` as the viewer, newest first,
  grouped by year. Records show their kind and date only (their content
  stays in the Records tab); documents link to their page.
  """
  use AppWeb, :live_component

  alias App.Documents.Types
  alias App.People.{PersonRecordSchema, PositionLabel}
  alias AppWeb.{DateFormat, DocumentUI, RecordComponents}

  @impl true
  def update(assigns, socket) do
    entries = App.Timeline.for_person(assigns.person.id, assigns.actor)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(years: Enum.chunk_by(entries, & &1.date.year))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id={@id} class="flex flex-col gap-4">
      <p :if={@years == []} class="text-sm opacity-60">{gettext("Nothing recorded yet.")}</p>
      <div :for={entries <- @years} class="flex flex-col gap-1">
        <h3 class="text-sm font-semibold opacity-70">{hd(entries).date.year}</h3>
        <ol class="relative ml-2 border-l border-base-300">
          <li :for={entry <- entries} class="relative flex min-w-0 items-start gap-3 py-1.5 pl-5">
            <span class="absolute -left-[0.8rem] top-1.5 flex size-6 items-center justify-center rounded-full border border-base-300 bg-base-100">
              <.icon name={entry_icon(entry)} class="size-3.5 opacity-70" />
            </span>
            <span class="w-20 shrink-0 text-xs tabular-nums opacity-60 pt-0.5">
              {DateFormat.display(entry.date)}
            </span>
            <span class="min-w-0 grow">
              <span class="block truncate text-sm">{title(entry)}</span>
              <span :if={detail(entry)} class="block truncate text-xs opacity-70">
                {detail(entry)}
              </span>
            </span>
            <.link
              :if={entry.document}
              navigate={~p"/documents/#{entry.document.id}"}
              class="link link-hover shrink-0 text-xs"
            >
              {entry.document.number || gettext("Document")}
            </.link>
          </li>
        </ol>
      </div>
    </section>
    """
  end

  defp entry_icon(%{kind: :record, subject: record}), do: PersonRecordSchema.icon(record.kind)
  defp entry_icon(%{kind: :document, subject: document}), do: Types.icon(document.type)
  defp entry_icon(%{kind: :acknowledgement}), do: "hero-check-circle"
  defp entry_icon(%{kind: :assignment_start}), do: "hero-briefcase"
  defp entry_icon(%{kind: :assignment_end}), do: "hero-arrow-right-start-on-rectangle"

  defp title(%{kind: :record, subject: record}), do: RecordComponents.kind_label(record.kind)
  defp title(%{kind: :document, subject: document}), do: DocumentUI.type_label(document.type)

  defp title(%{kind: :acknowledgement, document: document}),
    do: gettext("Acknowledged: %{order}", order: DocumentUI.type_label(document.type))

  defp title(%{kind: :assignment_start}), do: gettext("Appointed to a post")
  defp title(%{kind: :assignment_end}), do: gettext("Left a post")

  defp detail(%{kind: kind, subject: assignment})
       when kind in [:assignment_start, :assignment_end],
       do: assignment.position && PositionLabel.for_position(assignment.position)

  defp detail(%{kind: :acknowledgement, subject: acknowledgement}),
    do: DocumentUI.acknowledgement_method(acknowledgement.method)

  defp detail(_entry), do: nil
end
