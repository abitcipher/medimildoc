defmodule AppWeb.DocumentUI do
  @moduledoc """
  Small shared pieces of the document screens (docs/design/documents-core.md):
  the state badge, a document's title line and its list row.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1, text_badge: 1]

  alias App.Documents.{Inbox, Types}

  @doc "A document type's name in the viewer's language."
  @spec type_label(atom()) :: String.t()
  def type_label(type), do: AppWeb.SchemaText.translate(Types.label(type))

  @spec state_label(atom()) :: String.t()
  def state_label(:draft), do: gettext("Draft")
  def state_label(:in_review), do: gettext("In approval")
  def state_label(:signed), do: gettext("Signed")
  def state_label(:registered), do: gettext("Registered")
  def state_label(:cancelled), do: gettext("Cancelled")

  @doc "How an order was acknowledged (docs/design/acknowledgements.md)."
  @spec acknowledgement_method(atom()) :: String.t()
  def acknowledgement_method(:self), do: gettext("by the person, in the app")
  def acknowledgement_method(:in_person), do: gettext("read out to the person")
  def acknowledgement_method(:paper), do: gettext("signed on paper")

  attr :state, :atom, required: true
  attr :type, :atom, default: nil, doc: "the document type: an incoming letter shows Registered"

  def state_badge(assigns) do
    assigns =
      if (assigns.state == :signed and assigns.type) && Types.registration_only?(assigns.type),
        do: assign(assigns, state: :registered),
        else: assigns

    ~H"""
    <.text_badge
      text={state_label(@state)}
      class={[
        "badge-sm",
        case @state do
          :draft -> "badge-ghost"
          :in_review -> "badge-info"
          :signed -> "badge-success"
          :registered -> "badge-success"
          :cancelled -> "badge-neutral"
        end
      ]}
    />
    """
  end

  attr :document, :map, required: true
  attr :person?, :boolean, default: true
  attr :note, :string, default: nil
  attr :tag, :string, default: nil, doc: "why it is listed (start page), instead of the state"

  @doc "One document in a list: icon, type, number or state, person, due date."
  def row(assigns) do
    due = Map.get(assigns.document, :due) || assigns.document.due_on

    # Deadlines count while a document is on its way, and for an open
    # instruction on a registered letter (docs/design/correspondence.md).
    urgency =
      if assigns.document.state in [:draft, :in_review] or
           Map.has_key?(assigns.document, :instruction),
         do: Inbox.urgency(due, Date.utc_today())

    assigns = assign(assigns, due: due, urgency: urgency)

    ~H"""
    <.link
      navigate={"/documents/#{@document.id}"}
      class="flex min-w-0 items-center gap-3 rounded-box px-3 py-2 hover:bg-base-200"
    >
      <.icon name={Types.icon(@document.type)} class="size-5 shrink-0 opacity-70" />
      <span class="min-w-0 grow">
        <span :if={@tag} class="block truncate text-xs font-medium sm:hidden">
          <span class="opacity-70">{@tag}</span>
          <span :if={@due} class={due_class(@urgency)}>
            · {gettext("due %{date}", date: AppWeb.DateFormat.display(@due))}
          </span>
        </span>
        <span class="block truncate font-medium">{type_label(@document.type)}</span>
        <span class="block truncate text-xs opacity-70">
          <span :if={@person? and @document.person}>
            {App.People.Person.full_name(@document.person)} ·
          </span>
          {@document.number || AppWeb.DateFormat.display(DateTime.to_date(@document.inserted_at))}
          <span :if={@due} class={[due_class(@urgency), @tag && "max-sm:hidden"]}>
            · {gettext("due %{date}", date: AppWeb.DateFormat.display(@due))}
          </span>
        </span>
      </span>
      <.text_badge
        :if={@urgency == :overdue}
        text={gettext("overdue")}
        class="badge-sm badge-error max-sm:hidden"
      />
      <.text_badge :if={@note} text={@note} class="badge-sm badge-warning" />
      <.text_badge :if={@tag} text={@tag} class="badge-sm badge-ghost max-sm:hidden" />
      <.state_badge :if={!@tag} state={@document.state} type={@document.type} />
    </.link>
    """
  end

  defp due_class(:overdue), do: "font-semibold text-error"
  defp due_class(urgency) when urgency in [:today, :soon], do: "font-semibold text-warning"
  defp due_class(_urgency), do: nil
end
