defmodule AppWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use AppWeb, :html

  embed_templates "page_html/*"

  @doc """
  Start page cards: every navigation entry the user may open, sub-items
  included, in sidebar order (from `priv/nav_schema.json`).
  """
  def start_items(user) do
    user
    |> AppWeb.NavSchema.visible_items()
    |> Enum.flat_map(fn item -> [item | item["children"] || []] end)
    |> Enum.filter(& &1["path"])
  end

  alias App.People.Person
  alias AppWeb.DocumentUI

  attr :inbox, :map, required: true

  @doc "What waits for the user, most urgent first (docs/design/inbox-first.md)."
  def inbox(assigns) do
    ~H"""
    <section id="inbox" class="flex flex-col gap-2" aria-labelledby="inbox-title">
      <div class="flex items-center justify-between gap-2">
        <h2 id="inbox-title" class="flex min-w-0 items-center gap-2 text-lg font-semibold">
          <.icon name="hero-inbox" class="size-5 shrink-0" />
          <span class="truncate">{gettext("Waiting for you")}</span>
          <span class="badge badge-sm">{@inbox.count}</span>
          <span :if={@inbox.overdue > 0} class="badge badge-sm badge-error shrink-0">
            <span class="max-sm:hidden">
              {ngettext("%{count} overdue", "%{count} overdue", @inbox.overdue)}
            </span>
            <span class="sm:hidden">
              <.icon name="hero-clock" class="size-3" /> {@inbox.overdue}
              <span class="sr-only">{gettext("overdue")}</span>
            </span>
          </span>
        </h2>
        <.link navigate={~p"/tasks"} class="btn btn-ghost btn-sm shrink-0">
          <span class="max-sm:sr-only">{gettext("All tasks")}</span>
          <.icon name="hero-arrow-right" class="size-4" />
        </.link>
      </div>
      <p :if={@inbox.items == []} class="text-sm opacity-60">{gettext("Nothing waits for you.")}</p>
      <ul :if={@inbox.items != []} class="divide-y divide-base-200">
        <li :for={item <- @inbox.items}>
          <DocumentUI.row document={item.document} tag={reason_label(item)} />
        </li>
      </ul>
      <.link
        :if={@inbox.count > length(@inbox.items)}
        navigate={~p"/tasks"}
        class="link link-hover text-sm"
      >
        {ngettext("%{count} more", "%{count} more", @inbox.count - length(@inbox.items))}
      </.link>
    </section>
    """
  end

  defp reason_label(%{reason: :to_acknowledge}), do: gettext("to acknowledge")

  defp reason_label(%{reason: :to_decide, document: document}) do
    action =
      if document.step_action == :sign, do: gettext("to sign"), else: gettext("to approve")

    case Map.get(document, :on_behalf_of) do
      nil -> action
      user -> gettext("%{action} for %{name}", action: action, name: user.name || user.email)
    end
  end

  defp reason_label(%{reason: :instruction}), do: gettext("to carry out")
  defp reason_label(%{reason: :returned}), do: gettext("returned")
  defp reason_label(%{reason: :team}), do: gettext("for your team")

  # Start page widgets (docs/design/ui-plan.md item 8), data from
  # AppWeb.StartPage.
  attr :name, :atom, required: true
  attr :data, :map, required: true
  attr :conn, :any, default: nil

  # Readiness is a small LiveView (search, sort, scrolling list); the
  # signed LiveView session carries the viewer.
  def widget(%{name: :readiness} = assigns) do
    ~H"""
    {live_render(@conn, AppWeb.ReadinessLive,
      id: "readiness-live",
      session: %{"user_id" => @data.user_id, "locale" => Gettext.get_locale(AppWeb.Gettext)}
    )}
    """
  end

  def widget(%{name: :clearances} = assigns) do
    assigns = assign(assigns, :today, Date.to_iso8601(Date.utc_today()))

    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100 p-4" aria-labelledby="w-clearances">
      <h3 id="w-clearances" class="mb-3 flex items-center gap-2 font-semibold">
        <.icon name="hero-shield-check" class="size-5" /> {gettext("Clearances expiring")}
        <span class="badge badge-sm">{@data.count}</span>
      </h3>
      <p :if={@data.items == []} class="text-sm opacity-60">
        {gettext("Nothing due in the next 90 days.")}
      </p>
      <ul class="flex flex-col gap-1 text-sm">
        <li :for={record <- @data.items} class="flex items-center justify-between gap-2">
          <.link navigate={~p"/people/#{record.person_id}"} class="link link-hover truncate">
            {Person.full_name(record.person)}
          </.link>
          <span class={[
            "shrink-0 text-xs",
            if(record.data["expiryDate"] < @today, do: "text-error font-semibold", else: "opacity-70")
          ]}>
            {AppWeb.DateFormat.display(record.data["expiryDate"])}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  def widget(%{name: :documents} = assigns) do
    assigns = assign(assigns, :today, Date.utc_today())

    ~H"""
    <section class="rounded-box border border-base-300 bg-base-100 p-4" aria-labelledby="w-documents">
      <h3 id="w-documents" class="mb-3 flex items-center gap-2 font-semibold">
        <.icon name="hero-identification" class="size-5" /> {gettext("Documents expiring")}
        <span class="badge badge-sm">{@data.count}</span>
      </h3>
      <p :if={@data.items == []} class="text-sm opacity-60">
        {gettext("Nothing due in the next 90 days.")}
      </p>
      <ul class="flex flex-col gap-1 text-sm">
        <li :for={document <- @data.items} class="flex items-center justify-between gap-2">
          <.link navigate={~p"/people/#{document.person_id}"} class="link link-hover truncate">
            {Person.full_name(document.person)}
          </.link>
          <span class={[
            "shrink-0 text-xs",
            if(Date.compare(document.expires_on, @today) == :lt,
              do: "text-error font-semibold",
              else: "opacity-70"
            )
          ]}>
            {AppWeb.DateFormat.display(document.expires_on)}
          </span>
        </li>
      </ul>
    </section>
    """
  end

  def widget(%{name: :emergencies} = assigns) do
    ~H"""
    <.link
      navigate={~p"/access-log"}
      class={[
        "flex items-center gap-3 rounded-box border p-4",
        if(@data.count > 0, do: "border-error/50 bg-error/5", else: "border-base-300 bg-base-100")
      ]}
    >
      <.icon name="hero-bolt" class={["size-6", @data.count > 0 && "text-error"]} />
      <span class="grow">
        <span class="block font-semibold">{gettext("Emergency accesses to review")}</span>
        <span class="text-sm opacity-70">{gettext("Break the Glass requests since the last review")}</span>
      </span>
      <span class="text-3xl font-semibold">{@data.count}</span>
    </.link>
    """
  end

  def widget(%{name: :requests} = assigns) do
    ~H"""
    <.link
      navigate={~p"/users"}
      class={[
        "flex items-center gap-3 rounded-box border p-4",
        if(@data.count > 0, do: "border-warning/50 bg-warning/5", else: "border-base-300 bg-base-100")
      ]}
    >
      <.icon name="hero-shield-exclamation" class={["size-6", @data.count > 0 && "text-warning"]} />
      <span class="grow">
        <span class="block font-semibold">{gettext("Access requests")}</span>
        <span class="text-sm opacity-70">{gettext("Sensitive access waiting for a second approver")}</span>
      </span>
      <span class="text-3xl font-semibold">{@data.count}</span>
    </.link>
    """
  end
end
