defmodule AppWeb.EmergencyAccessUI do
  @moduledoc """
  Break the Glass on the person page (docs/design/access-control-phase2.md
  whether it applies, the request form, the active-access banner, and
  creating the grant. Kept out of `PeopleLive.Show` so that page doesn't
  depend on the access internals directly.
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  import AppWeb.CoreComponents, only: [icon: 1]

  alias App.Access.{RecordAccess, Unit}
  alias App.Audit.EmergencyAccess

  @doc """
  `{active_grant_or_nil, available?}` for `actor` on `person`: available when
  they hold btg.invoke, their clinical access is unit-scoped, the person is
  outside their unit, and no grant is active yet.
  """
  @spec state(map(), map()) :: {struct() | nil, boolean()}
  def state(person, actor) do
    active = EmergencyAccess.active_for(actor, person.id)

    available? =
      is_nil(active) and App.Access.can?(actor, "btg.invoke") and
        RecordAccess.kind_scope(actor, :allergy_intolerance, :read) == :unit and
        not Unit.person_in_unit?(person.id, Unit.org_ids(actor))

    {active, available?}
  end

  @doc "Creates the emergency access for `actor` on `person`."
  @spec invoke(map(), map(), String.t()) :: {:ok, struct()} | {:error, term()}
  def invoke(person, actor, reason) do
    EmergencyAccess
    |> Ash.Changeset.for_create(:invoke, %{person_id: person.id, reason: String.trim(reason)},
      actor: actor
    )
    |> Ash.create()
  end

  attr :emergency, :map, required: true

  def banner(assigns) do
    ~H"""
    <div role="alert" class="alert alert-warning">
      <.icon name="hero-bolt" class="size-5" />
      <div>
        <p class="font-medium">
          {gettext("Emergency access until %{time} UTC",
            time: Calendar.strftime(@emergency.expires_at, "%H:%M")
          )}
        </p>
        <p class="text-sm">{@emergency.reason}</p>
        <p class="text-xs opacity-80">
          {gettext("You can see this person's allergies. Every view is logged and reviewed.")}
        </p>
      </div>
    </div>
    """
  end

  attr :open, :boolean, required: true

  def request_form(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <button
        :if={!@open}
        type="button"
        phx-click="toggle_btg_form"
        class="btn btn-outline btn-error btn-sm self-start"
      >
        <.icon name="hero-bolt" class="size-4" />
        {gettext("Emergency access")}
      </button>
      <form
        :if={@open}
        id="btg-form"
        phx-submit="invoke_btg"
        class="flex flex-col gap-2 rounded-box border border-error/50 bg-error/5 p-3"
      >
        <p class="flex items-center gap-2 font-medium">
          <.icon name="hero-bolt" class="size-5 text-error" />
          {gettext("Emergency access to allergies")}
        </p>
        <p class="text-sm opacity-80">
          {gettext(
            "This person is outside your unit. In an emergency you can see their allergies for %{minutes} minutes. Your reason and every view are logged and reviewed by the security officer.",
            minutes: EmergencyAccess.duration_minutes()
          )}
        </p>
        <label class="text-sm font-medium" for="btg-reason">{gettext("Reason *")}</label>
        <textarea
          id="btg-reason"
          name="reason"
          required
          minlength="10"
          maxlength="500"
          rows="2"
          class="textarea w-full"
          placeholder={gettext("e.g. casualty treated at Role 2, needs allergy check")}
        ></textarea>
        <div class="flex gap-2">
          <button type="submit" class="btn btn-error btn-sm">
            <.icon name="hero-bolt" class="size-4" />
            {gettext("Grant emergency access")}
          </button>
          <button type="button" phx-click="toggle_btg_form" class="btn btn-ghost btn-sm">
            {gettext("Cancel")}
          </button>
        </div>
      </form>
    </div>
    """
  end
end
