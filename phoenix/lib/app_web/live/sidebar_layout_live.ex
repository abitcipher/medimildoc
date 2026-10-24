defmodule AppWeb.SidebarLayoutLive do
  @moduledoc """
  The Google Sheets sidebar's layout per role and access profile
  (docs/design/sheets-ui.md §Sidebar layout, SHEETS-UI.19,
  `settings.manage`): which tabs, tool icons and sections each sees
  (`AppWeb.SidebarLayout`). A user doesn't see an item unticked for their
  role or for any of their profiles. Saved on every change. An item that
  needs a permission is shown only to users who hold it, whatever is
  ticked here.
  """
  use AppWeb, :live_view

  alias AppWeb.SidebarLayout

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext("Sidebar layout"),
       hidden: SidebarLayout.hidden()
     )}
  end

  @impl true
  def handle_event("change", params, socket) do
    ids = Enum.map(SidebarLayout.items(), & &1.id)

    hidden =
      Map.new(SidebarLayout.audiences(), fn {key, _kind, _name} ->
        {key, ids -- (get_in(params, ["shown", key]) || [])}
      end)

    case SidebarLayout.put_hidden(hidden, socket.assigns.current_user) do
      :ok ->
        {:noreply,
         socket
         |> assign(hidden: SidebarLayout.hidden())
         |> put_flash(:info, gettext("Sidebar layout saved. Reopen the sidebar to see it."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  defp shown?(hidden, key, id), do: id not in Map.get(hidden, key, [])

  defp audience_label({_key, :role, role}), do: role_label(role)
  defp audience_label({_key, :profile, profile}), do: profile_label(profile)

  defp kind_label(:tab), do: gettext("Tab")
  defp kind_label(:tool), do: gettext("Tool icon")
  defp kind_label(:section), do: gettext("Section")

  @impl true
  def render(assigns) do
    assigns = assign(assigns, items: SidebarLayout.items(), audiences: SidebarLayout.audiences())

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-4xl flex-col gap-4 p-4">
        <h1 class="flex items-center gap-2 text-xl font-semibold">
          {gettext("Sidebar layout")}
          <.field_description description={
            gettext(
              "What the Google Sheets sidebar shows to each role and access profile: tabs, the tool icons in its top row (for the open tab) and sections. A user doesn't see an item unticked for their role or for any of their profiles. Hiding a tab hides its tools and sections. An item that needs a permission is shown only to users who hold it. Users see a change when they reopen the sidebar."
            )
          } />
        </h1>
        <section>
          <form id="sidebar-layout" phx-change="change" class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th rowspan="2">{gettext("Item")}</th>
                  <th rowspan="2">{gettext("Needs")}</th>
                  <th colspan="3" class="text-center">{gettext("Roles")}</th>
                  <%!-- Left-aligned: the table scrolls sideways, a centred
                  title over a dozen profile columns sat out of view. --%>
                  <th colspan={length(@audiences) - 3} class="border-l border-base-300 text-left">
                    {gettext("Access profiles")}
                  </th>
                </tr>
                <tr>
                  <th
                    :for={{audience, i} <- Enum.with_index(@audiences)}
                    class={["text-center text-xs font-normal", i == 3 && "border-l border-base-300"]}
                  >
                    {audience_label(audience)}
                  </th>
                </tr>
              </thead>
              <tbody>
                <tr :for={item <- @items} id={"layout-#{String.replace(item.id, ".", "-")}"}>
                  <td class={[item.kind != :tab && "pl-8"]}>
                    <div class="flex items-center gap-2">
                      <.icon name={item.icon} class="size-4 shrink-0 opacity-70" />
                      <span class={[item.kind == :tab && "font-medium"]}>{item.label}</span>
                      <span class="badge badge-ghost badge-sm shrink-0 whitespace-nowrap">
                        {kind_label(item.kind)}
                      </span>
                    </div>
                  </td>
                  <td class="text-xs opacity-70">{item.permission}</td>
                  <td
                    :for={{{key, _, _} = audience, i} <- Enum.with_index(@audiences)}
                    class={["text-center", i == 3 && "border-l border-base-300"]}
                  >
                    <input
                      type="checkbox"
                      name={"shown[#{key}][]"}
                      value={item.id}
                      checked={shown?(@hidden, key, item.id)}
                      class="checkbox checkbox-sm"
                      aria-label={"#{item.label} · #{audience_label(audience)}"}
                    />
                  </td>
                </tr>
              </tbody>
            </table>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
