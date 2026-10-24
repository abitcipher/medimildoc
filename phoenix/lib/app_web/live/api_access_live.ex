defmodule AppWeb.ApiAccessLive do
  @moduledoc """
  Access to the FHIR read API (docs/design/fhir-api.md): a person's own
  personal tokens (accounts linked to a person) and, for admins
  (`users.manage`), service clients with their global access profiles. A
  new token is shown once, right after it is created.
  """
  use AppWeb, :live_view

  alias App.Api.{Client, Smart}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    {:ok,
     socket
     |> assign(
       page_title: gettext("API access"),
       admin?: App.Access.can?(actor, "users.manage"),
       personal?: is_binary(actor.person_id),
       global_profiles:
         Enum.filter(App.Access.profiles(), &(App.Access.profile_scope(&1) == :global)),
       external_types: App.Fhir.external_types(),
       providers: external_providers(),
       new_token: nil,
       new_external: nil
     )
     |> load()}
  end

  defp load(socket) do
    clients =
      Client
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(actor: socket.assigns.current_user)

    assign(socket,
      personal:
        Enum.filter(
          clients,
          &(&1.kind == :personal and &1.user_id == socket.assigns.current_user.id)
        ),
      services: Enum.filter(clients, &(&1.kind == :service)),
      externals: Enum.filter(clients, &(&1.kind == :external))
    )
  end

  # External providers with a valid data-sharing agreement.
  defp external_providers do
    App.Care.Provider
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(not &1.priority and Smart.agreement_valid?(&1)))
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def handle_event("create", %{"kind" => kind} = params, socket) do
    actor = socket.assigns.current_user
    action = if kind == "service", do: :create_service, else: :create_personal

    attrs =
      %{name: String.trim(params["name"] || ""), expires_at: expires_at(params["days"])}
      |> then(fn attrs ->
        if action == :create_service,
          do:
            Map.put(
              attrs,
              :profiles,
              Enum.map(params["profiles"] || [], &String.to_existing_atom/1)
            ),
          else: attrs
      end)

    Client
    |> Ash.Changeset.for_create(action, attrs, actor: actor)
    |> Ash.create(actor: actor)
    |> case do
      {:ok, client} ->
        {:noreply,
         socket |> assign(new_token: {client.name, client.__metadata__.token}) |> load()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("create_external", params, socket) do
    actor = socket.assigns.current_user

    with {:ok, jwks} <- Jason.decode(params["jwks"] || ""),
         {:ok, client} <-
           Client
           |> Ash.Changeset.for_create(
             :create_external,
             %{
               name: String.trim(params["name"] || ""),
               provider_id: params["provider_id"],
               jwks: jwks,
               scopes: params["scopes"] || [],
               expires_at: expires_at(params["days"])
             },
             actor: actor
           )
           |> Ash.create(actor: actor) do
      {:noreply, socket |> assign(new_external: client) |> load()}
    else
      {:error, %Jason.DecodeError{}} ->
        {:noreply, put_flash(socket, :error, gettext("The keys are not valid JSON (a JWK Set)."))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    actor = socket.assigns.current_user

    Client
    |> Ash.get!(id, actor: actor)
    |> Ash.Changeset.for_update(:revoke, %{}, actor: actor)
    |> Ash.update!(actor: actor)

    {:noreply, socket |> put_flash(:info, gettext("Token revoked")) |> load()}
  end

  def handle_event("dismiss_token", _params, socket),
    do: {:noreply, assign(socket, new_token: nil, new_external: nil)}

  defp expires_at(days) do
    case Integer.parse(days || "") do
      {n, _} when n > 0 -> DateTime.add(DateTime.utc_now(), n * 86_400, :second)
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-3xl flex-col gap-6 p-4">
        <h1 class="flex items-center gap-2 text-xl font-semibold">
          {gettext("API access")}
          <.field_description description={
            gettext(
              "Tokens for the FHIR R5 read API at /fhir/R5 (Authorization: Bearer <token>). A personal token reads only your own record; a service client reads what its access profiles allow. Every read of sensitive data is recorded in the access log."
            )
          } />
        </h1>

        <div
          :if={@new_token}
          id="new-token"
          role="alert"
          class="alert alert-success alert-soft flex-col items-start text-sm"
        >
          <p class="font-medium">
            {gettext("Token for %{name} — copy it now, it is not shown again:",
              name: elem(@new_token, 0)
            )}
          </p>
          <code class="w-full break-all rounded bg-base-100 p-2 font-mono text-xs">{elem(
            @new_token,
            1
          )}</code>
          <button type="button" phx-click="dismiss_token" class="btn btn-xs">{gettext("Done")}</button>
        </div>

        <section :if={@personal?} id="personal-tokens" class="flex flex-col gap-2">
          <h2 class="font-semibold">{gettext("My tokens")}</h2>
          <.clients clients={@personal} />
          <.create_form kind="personal" profiles={[]} />
        </section>

        <p :if={!@personal? and !@admin?} class="text-sm opacity-70">
          {gettext("Personal tokens need an account linked to a person.")}
        </p>

        <section :if={@admin?} id="service-clients" class="flex flex-col gap-2">
          <h2 class="font-semibold">{gettext("Service clients")}</h2>
          <.clients clients={@services} />
          <.create_form kind="service" profiles={@global_profiles} />
        </section>

        <section :if={@admin?} id="external-systems" class="flex flex-col gap-2">
          <h2 class="flex items-center gap-2 font-semibold">
            {gettext("External systems")}
            <.field_description description={
              gettext(
                "Medical systems of external care providers (SMART on FHIR backend services). A system signs a JWT with its private key (RS384 or ES384) and exchanges it at the token endpoint for a five-minute access token. It reads only the resource types allowed here, about patients with a signed referral to its provider, while the provider's data-sharing agreement is valid."
              )
            } />
          </h2>
          <div
            :if={@new_external}
            id="new-external"
            role="status"
            class="alert alert-success alert-soft flex-col items-start text-sm"
          >
            <p class="font-medium">{gettext("Registered. Give the system:")}</p>
            <p>client_id: <code class="font-mono text-xs break-all">{@new_external.id}</code></p>
            <p>
              token endpoint:
              <code class="font-mono text-xs break-all">{AppWeb.FhirController.token_url()}</code>
            </p>
            <button type="button" phx-click="dismiss_token" class="btn btn-xs">{gettext("Done")}</button>
          </div>
          <.clients clients={@externals} />
          <p :if={@providers == []} class="text-sm opacity-70">
            {gettext("No external care provider has a valid data-sharing agreement in the register.")}
          </p>
          <form
            :if={@providers != []}
            id="create-external"
            phx-submit="create_external"
            class="flex flex-col gap-2 rounded-box border border-base-300 p-3"
          >
            <div class="flex flex-wrap items-end gap-2">
              <label class="flex min-w-0 grow flex-col gap-1 text-sm">
                {gettext("Name")}
                <input type="text" name="name" required maxlength="100" class="input input-sm w-full" />
              </label>
              <label class="flex min-w-0 grow flex-col gap-1 text-sm">
                {gettext("Care provider")}
                <select name="provider_id" class="select select-sm w-full">
                  <option :for={p <- @providers} value={p.id}>{p.name}</option>
                </select>
              </label>
              <label class="flex flex-col gap-1 text-sm">
                {gettext("Valid for, days")}
                <input
                  type="number"
                  name="days"
                  min="1"
                  placeholder="∞"
                  class="input input-sm w-28"
                />
              </label>
            </div>
            <fieldset class="flex flex-wrap gap-3 text-sm">
              <label :for={t <- ["*" | @external_types]} class="flex items-center gap-1">
                <input type="checkbox" name="scopes[]" value={t} class="checkbox checkbox-sm" />
                {if t == "*", do: gettext("All types"), else: t}
              </label>
            </fieldset>
            <label class="flex flex-col gap-1 text-sm">
              {gettext("Public keys (JWK Set, JSON)")}
              <textarea
                name="jwks"
                required
                rows="4"
                class="textarea textarea-sm w-full font-mono text-xs"
                placeholder='{"keys": [{"kty": "EC", "crv": "P-384", "x": "…", "y": "…", "kid": "…"}]}'
              ></textarea>
            </label>
            <button type="submit" class="btn btn-sm self-start">{gettext("Register system")}</button>
          </form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :clients, :list, required: true

  defp clients(assigns) do
    ~H"""
    <p :if={@clients == []} class="text-sm opacity-60">{gettext("None.")}</p>
    <ul :if={@clients != []} class="divide-y divide-base-200 rounded-box border border-base-300">
      <li
        :for={client <- @clients}
        id={"client-#{client.id}"}
        class="flex flex-wrap items-center gap-2 px-3 py-2"
      >
        <span class="min-w-0 grow">
          <span class="block truncate font-medium">{client.name}</span>
          <span class="block truncate font-mono text-xs opacity-70">
            <span :if={client.token_hint}>{client.token_hint}… · </span>
            <span :if={client.kind == :external}>client_id {client.id} · </span>
            {gettext("used")}: {used(client.last_used_at)}
            <span :if={client.expires_at}>
              · {gettext("until")} {AppWeb.DateFormat.display(DateTime.to_date(client.expires_at))}
            </span>
          </span>
          <span :if={client.profiles != []} class="flex flex-wrap gap-1 pt-1">
            <.text_badge
              :for={p <- client.profiles}
              text={profile_label(p)}
              class="badge-xs badge-outline"
            />
          </span>
          <span :if={client.scopes != []} class="flex flex-wrap gap-1 pt-1">
            <.text_badge :for={t <- client.scopes} text={t} class="badge-xs badge-outline" />
          </span>
        </span>
        <.text_badge :if={!client.active} text={gettext("revoked")} class="badge-sm badge-ghost" />
        <button
          :if={client.active}
          type="button"
          phx-click="revoke"
          phx-value-id={client.id}
          data-confirm={gettext("Revoke %{name}?", name: client.name)}
          class="btn btn-xs btn-error"
        >
          {gettext("Revoke")}
        </button>
      </li>
    </ul>
    """
  end

  attr :kind, :string, required: true
  attr :profiles, :list, required: true

  defp create_form(assigns) do
    ~H"""
    <form
      id={"create-#{@kind}"}
      phx-submit="create"
      class="flex flex-col gap-2 rounded-box border border-base-300 p-3"
    >
      <input type="hidden" name="kind" value={@kind} />
      <div class="flex flex-wrap items-end gap-2">
        <label class="flex min-w-0 grow flex-col gap-1 text-sm">
          {gettext("Name")}
          <input type="text" name="name" required maxlength="100" class="input input-sm w-full" />
        </label>
        <label class="flex flex-col gap-1 text-sm">
          {gettext("Valid for, days")}
          <input type="number" name="days" min="1" placeholder="∞" class="input input-sm w-28" />
        </label>
      </div>
      <fieldset :if={@profiles != []} class="flex flex-wrap gap-3 text-sm">
        <label :for={p <- @profiles} class="flex items-center gap-1">
          <input type="checkbox" name="profiles[]" value={p} class="checkbox checkbox-sm" />
          {profile_label(p)}
        </label>
      </fieldset>
      <button type="submit" class="btn btn-sm self-start">{gettext("Create token")}</button>
    </form>
    """
  end

  defp used(nil), do: gettext("never")
  defp used(at), do: AppWeb.DateFormat.display(DateTime.to_date(at))
end
