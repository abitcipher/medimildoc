defmodule AppWeb.RulesLive.Index do
  @moduledoc """
  The data consistency rules (docs/design/data-consistency.md;
  `rules.manage`): each rule set with its severity, check points,
  subjects and version; switch on or off, change severity, open the
  visual editor, and check existing data (`App.Rules.Sweep`).
  """
  use AppWeb, :live_view

  alias App.Rules.{Reference, RuleSet, Sweep}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(page_title: gettext("Rules"), result: nil) |> load()}
  end

  defp load(socket) do
    assign(socket,
      fsdc: App.Settings.fsdc?(),
      rules: RuleSet |> Ash.read!(actor: socket.assigns.current_user) |> Enum.sort_by(& &1.label)
    )
  end

  @impl true
  def handle_event("configure", %{"key" => key} = params, socket) do
    actor = socket.assigns.current_user
    rule = Enum.find(socket.assigns.rules, &(&1.key == key))

    attrs =
      case params do
        %{"severity" => severity} -> %{severity: String.to_existing_atom(severity)}
        _ -> %{enabled: not rule.enabled}
      end

    rule
    |> Ash.Changeset.for_update(:configure, attrs, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, _} -> {:noreply, load(socket)}
      {:error, error} -> {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("sweep", _params, socket) do
    %{checked: checked, found: found} = Sweep.run(socket.assigns.current_user)

    {:noreply,
     put_flash(
       socket,
       :info,
       gettext("Checked %{checked} items; %{found} new incidents.",
         checked: checked,
         found: found
       )
     )}
  end

  def handle_event("verify", _params, socket) do
    {kind, message} =
      case Reference.verify() do
        {:ok, %{missing: [], unexpected: []} = result} ->
          {:info,
           gettext(
             "Reference check passed: %{checked} items, %{expected} planted violations found.",
             checked: result.checked,
             expected: result.expected
           )}

        {:ok, result} ->
          {:error,
           gettext(
             "Reference check failed: %{missing} planted violations not found, %{unexpected} unexpected.",
             missing: length(result.missing),
             unexpected: length(result.unexpected)
           )}

        {:error, :not_seeded} ->
          {:error, gettext("The synthetic data is not the reference set.")}
      end

    {:noreply, put_flash(socket, kind, message)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="flex items-center gap-2 text-xl font-semibold">
            {gettext("Rules")}
            <.field_description description={
              gettext(
                "Rules are decision graphs (GoRules JDM). Block refuses the action, flag saves it and marks it, observe only records; every violation is an incident."
              )
            } />
          </h1>
          <div class="flex flex-wrap gap-2">
            <span class="flex items-center gap-1">
              <button type="button" phx-click="verify" class="btn btn-sm">
                <.icon name="hero-beaker" class="size-4" /> {gettext("Reference check")}
              </button>
              <.field_description description={
                gettext(
                  "Runs every rule over the synthetic reference data, whose deliberately invalid records are known, and compares the results. Records nothing."
                )
              } />
            </span>
            <button type="button" phx-click="sweep" class="btn btn-sm" disabled={!@fsdc}>
              <.icon name="hero-magnifying-glass" class="size-4" /> {gettext("Check existing data")}
            </button>
          </div>
        </div>
        <div :if={!@fsdc} role="status" class="alert alert-warning alert-soft text-sm">
          <.icon name="hero-pause-circle" class="size-5" />
          {gettext("Data consistency checks are off (Settings). Rules are kept but not evaluated.")}
        </div>

        <ul class="divide-y divide-base-200 rounded-box border border-base-300">
          <li
            :for={rule <- @rules}
            id={"rule-#{rule.key}"}
            class="flex flex-col gap-2 p-3 sm:flex-row sm:items-center"
          >
            <div class="min-w-0 grow">
              <p class="flex flex-wrap items-center gap-2 font-medium">
                {AppWeb.SchemaText.translate(rule.label)}
                <span class="badge badge-sm badge-ghost font-mono">v{rule.version}</span>
              </p>
              <p class="truncate text-xs opacity-70">
                {Enum.join(rule.points, ", ")} · {Enum.join(rule.subjects, ", ")}
              </p>
            </div>
            <form id={"severity-#{rule.key}"} phx-change="configure" class="shrink-0">
              <input type="hidden" name="key" value={rule.key} />
              <select name="severity" class="select select-sm" aria-label={gettext("Severity")}>
                <option :for={s <- [:block, :flag, :observe]} value={s} selected={rule.severity == s}>
                  {severity_label(s)}
                </option>
              </select>
            </form>
            <input
              type="checkbox"
              class="toggle toggle-sm toggle-primary shrink-0"
              checked={rule.enabled}
              phx-click="configure"
              phx-value-key={rule.key}
              aria-label={gettext("Enabled")}
            />
            <.link navigate={~p"/rules/#{rule.key}"} class="btn btn-sm shrink-0">
              <.icon name="hero-pencil-square" class="size-4" /> {gettext("Edit")}
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  @doc false
  def severity_label(:block), do: gettext("Block")
  def severity_label(:flag), do: gettext("Flag")
  def severity_label(:observe), do: gettext("Observe")
end
