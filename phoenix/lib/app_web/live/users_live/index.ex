defmodule AppWeb.UsersLive.Index do
  @moduledoc """
  Users and their access (docs/design/ui-plan.md item 7). The table shows
  each user's role and access profiles as chips; "Edit access" opens a
  panel where the role and profiles are chosen together, each option
  described by what it lets the user see and change (from
  `priv/access_profiles.json`).

  Route-gated by `users.manage` in the router; the real enforcement is
  `App.Accounts.User`'s `:update_access` policy. Your own access is
  read-only here — changing it through the page you'd then lose access to
  is a footgun; use the remote console.
  """
  use AppWeb, :live_view

  alias App.Access
  alias App.Accounts.{AccessRequest, User}
  alias App.People.Person

  require Ash.Query

  @table_id "users-table"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Users"))
     |> assign(:table_id, @table_id)
     |> assign(:editing, nil)
     |> load_requests()}
  end

  @impl true
  def handle_event("edit_access", %{"id" => id}, socket) do
    %{current_user: actor} = socket.assigns

    if id == actor.id do
      {:noreply, socket}
    else
      user = Ash.get!(User, id, actor: actor)
      people = people_for_linking(actor)

      {:noreply,
       socket
       |> assign(:editing, user)
       |> assign(:people, people)
       |> assign(:suggested_person, suggest_person(user, people))}
    end
  end

  def handle_event("cancel_access", _params, socket),
    do: {:noreply, assign(socket, :editing, nil)}

  def handle_event("save_access", params, socket) do
    %{editing: user, current_user: actor} = socket.assigns

    role = Enum.find(Access.roles(), user.role, &(Atom.to_string(&1) == params["role"]))

    profiles =
      params
      |> Map.get("profiles", [])
      |> Enum.flat_map(fn value ->
        Enum.filter(Access.profiles(), &(Atom.to_string(&1) == value))
      end)

    person_id = if params["person_id"] in [nil, ""], do: nil, else: params["person_id"]

    # docs/design/access-control-phase2.md: with second approval on, the
    # sensitive part (admin role, sensitive profiles) becomes a request and
    # everything else is saved now.
    pending =
      if Access.second_approval_required?(),
        do: Access.needs_approval(user, role, profiles),
        else: %{role: nil, profiles: []}

    changes = %{
      role: if(pending.role, do: user.role, else: role),
      profiles: profiles -- pending.profiles,
      person_id: person_id
    }

    with {:ok, updated} <- Ash.update(user, changes, action: :update_access, actor: actor),
         :ok <- request_approval(updated, pending, actor) do
      {:noreply,
       socket
       |> assign(:editing, nil)
       |> put_flash(:info, save_message(updated, pending))
       |> load_requests()
       |> Cinder.refresh_table(@table_id)}
    else
      {:error, error} -> {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("decide_request", %{"id" => id, "decision" => decision}, socket)
      when decision in ["approve", "reject"] do
    actor = socket.assigns.current_user
    action = String.to_existing_atom(decision)

    AccessRequest
    |> Ash.get!(id, actor: actor)
    |> Ash.Changeset.for_update(action, %{}, actor: actor)
    |> Ash.update()
    |> case do
      {:ok, _} ->
        message =
          if action == :approve,
            do: gettext("Approved and applied."),
            else: gettext("Request rejected.")

        {:noreply,
         socket |> put_flash(:info, message) |> load_requests() |> Cinder.refresh_table(@table_id)}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  defp request_approval(_user, %{role: nil, profiles: []}, _actor), do: :ok

  defp request_approval(user, pending, actor) do
    AccessRequest
    |> Ash.Changeset.for_create(
      :request,
      %{user_id: user.id, role: pending.role, profiles: pending.profiles},
      actor: actor
    )
    |> Ash.create()
    |> case do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp save_message(user, %{role: nil, profiles: []}),
    do: gettext("Updated access for %{email}.", email: user.email)

  defp save_message(user, pending) do
    names =
      Enum.map(pending.profiles, &profile_label/1) ++
        if(pending.role, do: [role_label(pending.role)], else: [])

    gettext("Saved for %{email}. Waiting for a second approver: %{access}.",
      email: user.email,
      access: Enum.join(names, ", ")
    )
  end

  defp load_requests(socket) do
    requests = AccessRequest.pending(socket.assigns.current_user)

    users =
      case Enum.map(requests, & &1.user_id) do
        [] ->
          %{}

        ids ->
          User
          |> Ash.Query.filter(id in ^ids)
          |> Ash.read!(authorize?: false)
          |> Map.new(&{&1.id, &1})
      end

    socket
    |> assign(:requests, requests)
    |> assign(:request_users, users)
  end

  # docs/design/events-and-person-login.md: the users, or the roles
  # and access profiles with who holds them.
  @impl true
  def handle_params(params, _uri, socket) do
    view = if params["view"] == "roles", do: :roles, else: :users

    socket =
      if view == :roles,
        do: assign(socket, :holders, holders(socket.assigns.current_user)),
        else: socket

    {:noreply, assign(socket, :view, view)}
  end

  defp holders(actor) do
    users = Ash.read!(User, actor: actor)

    %{
      roles: Enum.frequencies_by(users, & &1.role),
      profiles: users |> Enum.flat_map(& &1.profiles) |> Enum.frequencies()
    }
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4">
        <div>
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Users")}
            <.field_description description={
              gettext(
                "A user's access is their role plus any access profiles. Choose Edit access to change it."
              )
            } />
          </h1>
        </div>

        <section :if={@requests != []} id="access-requests" class="flex flex-col gap-2">
          <h2 class="flex items-center gap-2 font-semibold">
            <.icon name="hero-shield-exclamation" class="size-5 text-warning" />
            {gettext("Waiting for approval")}
            <span class="badge badge-warning badge-sm">{length(@requests)}</span>
          </h2>
          <ul class="flex flex-col gap-2">
            <li
              :for={request <- @requests}
              id={"request-#{request.id}"}
              class="flex flex-wrap items-center gap-3 rounded-box border border-warning/50 bg-warning/5 p-3 text-sm"
            >
              <div class="min-w-0 grow">
                <p class="font-medium">
                  {case @request_users[request.user_id] do
                    nil -> request.user_id
                    user -> user.email
                  end}
                </p>
                <p class="flex flex-wrap gap-1">
                  <.text_badge
                    :if={request.role}
                    text={role_label(request.role)}
                    class="badge-sm badge-neutral"
                  />
                  <.text_badge
                    :for={profile <- request.profiles}
                    text={profile_label(profile)}
                    class="badge-sm badge-outline"
                  />
                </p>
                <p class="text-xs opacity-70">
                  {gettext("Requested by %{email}", email: request.requested_by_email)}
                </p>
              </div>
              <%= if request.requested_by_id == @current_user.id do %>
                <span
                  class="tooltip tooltip-left text-xs opacity-70"
                  data-tip={gettext("Another administrator has to approve your request")}
                >
                  <.icon name="hero-clock" class="size-4" /> {gettext("Awaiting another approver")}
                </span>
              <% else %>
                <div class="flex gap-2">
                  <button
                    type="button"
                    phx-click="decide_request"
                    phx-value-id={request.id}
                    phx-value-decision="approve"
                    class="btn btn-success btn-sm"
                  >
                    <.icon name="hero-check" class="size-4" />{gettext("Approve")}
                  </button>
                  <button
                    type="button"
                    phx-click="decide_request"
                    phx-value-id={request.id}
                    phx-value-decision="reject"
                    class="btn btn-ghost btn-sm text-error"
                  >
                    <.icon name="hero-x-mark" class="size-4" />{gettext("Reject")}
                  </button>
                </div>
              <% end %>
            </li>
          </ul>
        </section>

        <.access_panel
          :if={@editing}
          user={@editing}
          people={@people}
          suggested_person={@suggested_person}
        />

        <div role="tablist" class="tabs tabs-border">
          <.link
            role="tab"
            id="tab-users"
            patch={~p"/users"}
            class={["tab", @view == :users && "tab-active"]}
          >
            {gettext("Users")}
          </.link>
          <.link
            role="tab"
            id="tab-roles"
            patch={~p"/users?view=roles"}
            class={["tab", @view == :roles && "tab-active"]}
          >
            {gettext("Roles and profiles")}
          </.link>
        </div>

        <.roles :if={@view == :roles} holders={@holders} />

        <.top_pager :if={@view == :users} id={@table_id}>
          <Cinder.collection
            id={@table_id}
            query={Ash.Query.load(User, [:person, :password_set?, :google?])}
            actor={@current_user}
          >
            <:col :let={user} field="email" filter sort label={gettext("User")}>
              <div class="flex items-center gap-3">
                <span class={[
                  "inline-flex size-8 shrink-0 items-center justify-center rounded-full text-sm font-medium text-white",
                  AppWeb.HeaderControls.avatar_color(user)
                ]}>
                  {AppWeb.HeaderControls.initials(user)}
                </span>
                <div class="min-w-0">
                  <div :if={user.name} class="truncate font-medium">{user.name}</div>
                  <div class="truncate text-xs opacity-70">{user.email}</div>
                </div>
              </div>
            </:col>
            <:col :let={user} field="role" filter={:select} sort label={gettext("Role")}>
              <.text_badge text={role_label(user.role)} class="badge-sm badge-neutral" />
            </:col>
            <:col :let={user} label={gettext("Person")}>
              <.link
                :if={user.person}
                navigate={~p"/people/#{user.person.id}"}
                class="link link-hover flex items-center gap-1"
              >
                <.icon name="hero-link" class="size-3.5" />
                {Person.full_name(user.person)}
              </.link>
              <span
                :if={!user.person}
                class="tooltip tooltip-right opacity-50"
                data-tip={gettext("Not linked to a person")}
              >
                —
              </span>
            </:col>
            <:col :let={user} label={gettext("Sign-in")}>
              <div class="flex flex-wrap gap-1">
                <span :if={user.google?} class="badge badge-sm badge-ghost">Google</span>
                <span :if={user.login_id && user.password_set?} class="badge badge-sm badge-ghost">
                  PersonID
                </span>
                <span
                  :if={user.login_id && !user.password_set?}
                  class="badge badge-sm badge-ghost opacity-60"
                  data-float-tip={gettext("Asked for a link, no password set yet")}
                >
                  PersonID…
                </span>
              </div>
              <div :if={user.last_sign_in_at} class="mt-0.5 whitespace-nowrap text-xs opacity-60">
                {AppWeb.DateFormat.display(DateTime.to_date(user.last_sign_in_at))}
              </div>
            </:col>
            <:col :let={user} label={gettext("Access profiles")}>
              <div class="flex min-w-0 max-w-48 flex-wrap gap-1">
                <.text_badge
                  :for={profile <- user.profiles}
                  text={profile_label(profile)}
                  class="badge-sm badge-outline"
                />
                <span :if={user.profiles == []} class="opacity-50">—</span>
              </div>
            </:col>
            <:col :let={user} label="">
              <button
                :if={user.id != @current_user.id}
                type="button"
                phx-click="edit_access"
                phx-value-id={user.id}
                class="tooltip tooltip-left btn btn-ghost btn-sm btn-square"
                data-tip={gettext("Edit access")}
                aria-label={gettext("Edit access for %{email}", email: to_string(user.email))}
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
              <span
                :if={user.id == @current_user.id}
                class="tooltip tooltip-left inline-flex p-2 opacity-50"
                data-tip={gettext("You can't change your own access here")}
                aria-label={gettext("You can't change your own access here")}
              >
                <.icon name="hero-lock-closed" class="size-4" />
              </span>
            </:col>
          </Cinder.collection>
        </.top_pager>

        <.live_component
          module={AppWeb.DeputiesAdminComponent}
          id="deputies-admin"
          actor={@current_user}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :holders, :map, required: true

  # Each base role and access profile: what it allows, who holds it.
  defp roles(assigns) do
    assigns =
      assign(assigns,
        roles: Access.roles(),
        profiles: Access.profiles()
      )

    ~H"""
    <section id="roles-view" class="flex flex-col gap-4">
      <div>
        <h2 class="mb-2 font-semibold">{gettext("Roles")}</h2>
        <ul class="flex flex-col divide-y divide-base-300">
          <li :for={role <- @roles} id={"role-#{role}"} class="flex items-start gap-3 py-2">
            <span class="badge badge-neutral badge-sm mt-0.5 shrink-0">{role_label(role)}</span>
            <span class="grow text-sm">
              <span :if={role == :person} class="block text-xs opacity-80">
                {gettext(
                  "Made for a PersonID sign-in: only the person's own data. Give Viewer or higher to see others."
                )}
              </span>
              <.grants permissions={Access.role_permissions(role)} />
            </span>
            <span class="shrink-0 text-sm tabular-nums" data-float-tip={gettext("Users")}>
              {Map.get(@holders.roles, role, 0)}
            </span>
          </li>
        </ul>
      </div>
      <div>
        <h2 class="mb-2 font-semibold">{gettext("Access profiles")}</h2>
        <ul class="flex flex-col divide-y divide-base-300">
          <li
            :for={profile <- @profiles}
            id={"profile-#{profile}"}
            class="flex items-start gap-3 py-2"
          >
            <span class="badge badge-outline badge-sm mt-0.5 shrink-0">
              {profile_label(profile)}
            </span>
            <span class="grow text-sm">
              <span
                :if={Access.profile_scope(profile) == :unit}
                class="flex items-center gap-1 text-xs text-info"
              >
                <.icon name="hero-building-office-2" class="size-3.5" />
                {gettext("Only for people in their unit and the units below it")}
              </span>
              <.grants permissions={Access.profile_permissions(profile)} />
            </span>
            <span class="shrink-0 text-sm tabular-nums" data-float-tip={gettext("Users")}>
              {Map.get(@holders.profiles, profile, 0)}
            </span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :user, :map, required: true
  attr :people, :list, required: true
  attr :suggested_person, :map, default: nil

  defp access_panel(assigns) do
    ~H"""
    <section
      id="access-panel"
      class="rounded-box border border-primary/40 bg-base-200/40 p-4"
      aria-labelledby="access-panel-title"
    >
      <h2 id="access-panel-title" class="mb-3 font-semibold">
        {gettext("Access for %{email}", email: to_string(@user.email))}
      </h2>
      <p class="mb-3 flex flex-wrap gap-x-4 gap-y-1 text-xs opacity-70">
        <span class="flex items-center gap-1">
          <.icon name="hero-eye" class="size-3.5" />{gettext("can see")}
        </span>
        <span class="flex items-center gap-1">
          <.icon name="hero-pencil" class="size-3.5" />{gettext("can change")}
        </span>
      </p>
      <form id="access-form" phx-submit="save_access" class="flex flex-col gap-4">
        <fieldset>
          <legend class="mb-2 text-sm font-medium">{gettext("Linked person")}</legend>
          <p class="mb-2 text-xs opacity-70">
            {gettext(
              "The person this account belongs to. Their unit and clearance limit what unit-scoped profiles can see."
            )}
          </p>
          <select id="access-person" name="person_id" class="select select-sm w-full max-w-md">
            <option value="">{gettext("— not linked —")}</option>
            <option
              :for={person <- @people}
              value={person.id}
              selected={person.id == @user.person_id}
            >
              {Person.full_name(person)}{if person.email, do: " · #{person.email}"}
            </option>
          </select>
          <button
            :if={@suggested_person && @user.person_id != @suggested_person.id}
            type="button"
            phx-click={
              Phoenix.LiveView.JS.set_attribute({"value", @suggested_person.id}, to: "#access-person")
              |> Phoenix.LiveView.JS.dispatch("change", to: "#access-person")
            }
            class="btn btn-ghost btn-xs mt-1"
          >
            <.icon name="hero-sparkles" class="size-3.5" />
            {gettext("Same email: %{name}", name: Person.full_name(@suggested_person))}
          </button>
        </fieldset>

        <fieldset>
          <legend class="mb-2 text-sm font-medium">{gettext("Role")}</legend>
          <div class="grid grid-cols-1 gap-2 md:grid-cols-3">
            <label
              :for={role <- Access.roles()}
              class="flex cursor-pointer gap-3 rounded-box border border-base-300 bg-base-100 p-3 has-[:checked]:border-primary"
            >
              <input
                type="radio"
                name="role"
                value={role}
                checked={@user.role == role}
                class="radio radio-sm radio-primary mt-0.5"
              />
              <span class="text-sm">
                <span class="block font-medium">{role_label(role)}</span>
                <.grants permissions={Access.role_permissions(role)} />
                <span
                  :if={role == :admin and Access.admin_full_data_access?()}
                  class="mt-1 block text-xs text-warning"
                >
                  {gettext("Development setting: currently sees all data.")}
                </span>
              </span>
            </label>
          </div>
        </fieldset>

        <fieldset>
          <legend class="mb-2 text-sm font-medium">{gettext("Access profiles")}</legend>
          <input type="hidden" name="profiles[]" value="" />
          <div class="grid grid-cols-1 gap-2 md:grid-cols-2 lg:grid-cols-3">
            <label
              :for={profile <- Access.profiles()}
              class="flex cursor-pointer gap-3 rounded-box border border-base-300 bg-base-100 p-3 has-[:checked]:border-primary"
            >
              <input
                type="checkbox"
                name="profiles[]"
                value={profile}
                checked={profile in @user.profiles}
                class="checkbox checkbox-sm checkbox-primary mt-0.5"
              />
              <span class="text-sm">
                <span class="block font-medium">{profile_label(profile)}</span>
                <span
                  :if={Access.second_approval_required?() and profile in Access.sensitive_profiles()}
                  class="mt-0.5 flex items-center gap-1 text-xs text-warning"
                >
                  <.icon name="hero-shield-exclamation" class="size-3.5" />
                  {gettext("Granting it needs a second approver")}
                </span>
                <span
                  :if={Access.profile_scope(profile) == :unit}
                  class="mt-0.5 flex items-center gap-1 text-xs text-info"
                >
                  <.icon name="hero-building-office-2" class="size-3.5" />
                  {gettext("Only for people in their unit and the units below it")}
                </span>
                <%!-- Only what the profile adds: every user already holds the
                viewer role's permissions. --%>
                <.grants permissions={
                  MapSet.difference(
                    Access.profile_permissions(profile),
                    Access.role_permissions(:viewer)
                  )
                } />
              </span>
            </label>
          </div>
        </fieldset>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm">
            <.icon name="hero-check" class="size-4" />
            {gettext("Save")}
          </button>
          <button type="button" phx-click="cancel_access" class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </button>
        </div>
      </form>
    </section>
    """
  end

  # "Can see / Can change" summary of a permission set.
  attr :permissions, :any, required: true

  defp grants(assigns) do
    {see, change} =
      Enum.split_with(
        assigns.permissions,
        &(String.ends_with?(&1, ".read") or &1 == "audit.read")
      )

    assigns =
      assign(assigns,
        see: describe(see),
        change: describe(change)
      )

    ~H"""
    <span :if={@see != []} class="mt-1 flex gap-1 text-xs opacity-80">
      <.icon name="hero-eye" class="mt-0.5 size-3.5 shrink-0" />
      <span><span class="sr-only">{gettext("Can see:")}</span>{Enum.join(@see, " · ")}</span>
    </span>
    <span :if={@change != []} class="mt-1 flex gap-1 text-xs opacity-80">
      <.icon name="hero-pencil" class="mt-0.5 size-3.5 shrink-0" />
      <span><span class="sr-only">{gettext("Can change:")}</span>{Enum.join(@change, " · ")}</span>
    </span>
    """
  end

  defp describe(permissions) do
    permissions
    |> Enum.sort()
    |> Enum.map(&Gettext.gettext(AppWeb.Gettext, Access.permission_description(&1)))
    |> Enum.uniq()
  end

  defp people_for_linking(actor) do
    Person
    |> Ash.Query.sort(family_name: :asc, given_name: :asc)
    |> Ash.read!(actor: actor)
  end

  # A person with the same email as the account, offered as a suggestion
  # only — linking is always an explicit choice.
  defp suggest_person(user, people) do
    email = user.email |> to_string() |> String.downcase()
    Enum.find(people, &(is_binary(&1.email) and String.downcase(&1.email) == email))
  end
end
