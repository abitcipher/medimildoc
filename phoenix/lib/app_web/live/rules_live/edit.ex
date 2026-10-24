defmodule AppWeb.RulesLive.Edit do
  @moduledoc """
  One rule set in the visual editor (docs/design/data-consistency.md;
  `rules.manage`): GoRules' JDM Editor (assets/rules_editor, loaded only
  here by the `RulesEditor` hook), Save (a new version; the old graph is
  kept), and a test run: a context in JSON evaluated by the server's own
  engine with a trace, which the editor shows node by node.
  """
  use AppWeb, :live_view

  alias App.Rules.{Engine, RuleSet, RuleSetVersion}

  require Ash.Query

  @sample %{
    "point" => "record.save",
    "subject" => "record:encounter",
    "event" => %{"at" => "2026-09-02T09:00:00Z"},
    "person" => %{"id" => nil, "identityVerifiedAt" => "2026-09-01T10:00:00Z"},
    "data" => %{}
  }

  @impl true
  def mount(%{"key" => key}, _session, socket) do
    rule = Ash.get!(RuleSet, key, actor: socket.assigns.current_user)

    {:ok,
     socket
     |> assign(
       page_title: AppWeb.SchemaText.translate(rule.label),
       context: Jason.encode!(@sample, pretty: true),
       outcome: nil
     )
     |> assign_rule(rule)}
  end

  defp assign_rule(socket, rule) do
    versions =
      RuleSetVersion
      |> Ash.Query.filter(key == ^rule.key)
      |> Ash.Query.sort(version: :desc)
      |> Ash.read!(actor: socket.assigns.current_user)

    assign(socket, rule: rule, versions: versions)
  end

  @impl true
  def handle_event("save_graph", %{"graph" => graph}, socket) do
    actor = socket.assigns.current_user

    socket.assigns.rule
    |> Ash.Changeset.for_update(:update_graph, %{graph: graph}, actor: actor)
    |> Ash.update(actor: actor)
    |> case do
      {:ok, rule} ->
        {:noreply,
         socket
         |> assign_rule(rule)
         |> put_flash(:info, gettext("Saved as version %{version}", version: rule.version))}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, App.AshErrors.summarize(error))}
    end
  end

  def handle_event("simulate", %{"context" => text, "graph" => graph}, socket) do
    socket = assign(socket, context: text)

    with {:ok, context} <- Jason.decode(text),
         {:ok, response} <- Engine.simulate(graph, context) do
      simulation = %{
        "result" => %{
          "performance" => response["performance"],
          "result" => response["result"],
          "snapshot" => graph,
          "trace" => response["trace"] || %{}
        }
      }

      {:noreply,
       socket
       |> assign(outcome: {:ok, response["result"]})
       |> push_event("rules:simulation", simulation)}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:noreply, assign(socket, outcome: {:error, Exception.message(error)})}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(outcome: {:error, inspect(reason)})
         |> push_event("rules:simulation", %{
           "error" => %{"message" => inspect(reason), "data" => %{}}
         })}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <div class="flex flex-col gap-3 p-4">
        <div class="flex flex-wrap items-center gap-2">
          <.link
            navigate={~p"/rules"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label={gettext("Rules")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 class="grow text-xl font-semibold">
            {AppWeb.SchemaText.translate(@rule.label)}
            <span class="badge badge-sm badge-ghost font-mono align-middle">v{@rule.version}</span>
          </h1>
          <button
            type="button"
            phx-click={JS.dispatch("rules:save", to: "#rules-editor")}
            class="btn btn-sm btn-primary"
          >
            <.icon name="hero-check" class="size-4" /> {gettext("Save as new version")}
          </button>
        </div>

        <div
          id="rules-editor"
          phx-hook="RulesEditor"
          phx-update="ignore"
          data-module={~p"/assets/rules_editor/rules_editor.js"}
          data-css={~p"/assets/rules_editor/rules_editor.css"}
          data-graph={Jason.encode!(@rule.graph)}
          class="h-[65vh] min-h-96 overflow-hidden rounded-box border border-base-300 bg-base-100"
        >
          <p class="p-4 text-sm opacity-60">{gettext("Loading the editor…")}</p>
        </div>

        <form
          id="simulate-form"
          phx-submit={JS.dispatch("rules:simulate", to: "#rules-editor")}
          class="grid gap-3 md:grid-cols-2"
        >
          <div>
            <label for="simulate-context" class="mb-1 flex items-center gap-2 text-sm font-medium">
              {gettext("Test context (JSON)")}
              <.field_description description={
                gettext(
                  "What the rule is given at a check point: event, person facts and the record's fields. Run it to see the result and the path through the graph."
                )
              } />
            </label>
            <textarea
              id="simulate-context"
              name="context"
              rows="10"
              class="textarea textarea-sm w-full font-mono"
            >{@context}</textarea>
            <button type="submit" class="btn btn-sm mt-2">
              <.icon name="hero-play" class="size-4" /> {gettext("Run")}
            </button>
          </div>
          <div>
            <p class="mb-1 text-sm font-medium">{gettext("Result")}</p>
            <pre
              :if={@outcome}
              class={[
                "overflow-x-auto rounded-box p-3 text-xs",
                if(elem(@outcome, 0) == :ok, do: "bg-base-200", else: "bg-error/10 text-error")
              ]}
            >{if elem(@outcome, 0) == :ok, do: Jason.encode!(elem(@outcome, 1), pretty: true), else: elem(@outcome, 1)}</pre>
            <p class="mt-3 mb-1 text-sm font-medium">{gettext("Earlier versions")}</p>
            <p :if={@versions == []} class="text-xs opacity-60">{gettext("None yet.")}</p>
            <ul class="text-xs">
              <li :for={v <- @versions}>
                v{v.version} · {AppWeb.DateFormat.display_datetime(v.inserted_at)} · {v.replaced_by_email}
              </li>
            </ul>
          </div>
        </form>
      </div>
    </Layouts.app>
    """
  end
end
