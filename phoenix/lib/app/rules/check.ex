defmodule App.Rules.Check do
  @moduledoc """
  Runs the rules for one check point and subject
  (docs/design/data-consistency.md) and records violations as incidents.

  - Nothing happens while FSDC is off (`App.Settings.fsdc?/0`).
  - `run/3` evaluates every enabled rule set whose `points` include the
    point and whose `subjects` include the subject; a rule that returns
    `valid: false` is a violation. A rule that fails to evaluate is a
    violation too (code `rule_error`): a broken rule must not silently
    let data through.
  - `record/4` writes the incidents (outside the action's transaction, so
    a refused action keeps its incident).
  """

  require Ash.Query

  alias App.Audit.Incident
  alias App.Notify.Emitter
  alias App.Rules.{Engine, Facts, RuleSet}

  @type violation :: %{
          rule: map(),
          code: String.t() | nil,
          message: String.t() | nil,
          context: map()
        }

  @spec run(String.t(), String.t(), map()) :: [violation()]
  def run(point, subject, context) do
    if App.Settings.fsdc?() do
      point
      |> rule_sets(subject)
      |> evaluate(context)
    else
      []
    end
  end

  defp rule_sets(point, subject) do
    RuleSet
    |> Ash.Query.filter(enabled == true)
    |> Ash.read!(authorize?: false)
    |> Enum.filter(&(point in &1.points and subject in &1.subjects))
  end

  @doc """
  Evaluates the given rule sets against a context, whatever the settings
  (the reference check, `App.Rules.Reference`).
  """
  @spec evaluate([map()], map()) :: [violation()]
  def evaluate(rules, context), do: Enum.flat_map(rules, &evaluate_rule(&1, context))

  defp evaluate_rule(rule, context) do
    case Engine.evaluate(rule.graph, context) do
      {:ok, %{"valid" => true}} ->
        []

      {:ok, result} ->
        [%{rule: rule, code: result["code"], message: result["message"], context: context}]

      {:error, reason} ->
        [%{rule: rule, code: "rule_error", message: inspect(reason), context: context}]
    end
  end

  @doc """
  The messages of open incidents about `subject_id` (a flagged document or
  record), for anyone who may see the subject: what is wrong, not who
  found it or the facts (those are for audit).
  """
  @spec open_flags(String.t()) :: [String.t()]
  def open_flags(subject_id) do
    Incident
    |> Ash.Query.filter(subject_id == ^subject_id and status == :open)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&(&1.message || &1.code))
    |> Enum.uniq()
  end

  @doc "Whether any violation blocks the action."
  @spec blocking?([violation()]) :: boolean()
  def blocking?(violations), do: Enum.any?(violations, &(&1.rule.severity == :block))

  @doc """
  Writes one incident per violation; `outcome` is `:refused`, `:saved` or
  `:found` (a sweep).
  """
  @spec record([violation()], atom(), map(), map() | nil) :: :ok
  def record(violations, outcome, subject_ref, actor) do
    for violation <- violations do
      Incident
      |> Ash.Changeset.for_create(
        :create,
        %{
          rule_key: violation.rule.key,
          rule_version: violation.rule.version,
          severity: violation.rule.severity,
          outcome: outcome,
          point: violation.context["point"],
          subject: violation.context["subject"],
          subject_id: subject_ref[:id],
          person_id: subject_ref[:person_id],
          actor_id: actor && actor.id,
          actor_email: actor && to_string(actor.email),
          code: violation.code,
          message: violation.message,
          facts: Facts.facts_for_incident(violation.context)
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end

    notify(violations)
  end

  # Holders of audit.read who subscribed hear of new incidents (App.Notify).
  defp notify([]), do: :ok

  defp notify(violations) do
    reviewers =
      App.Accounts.User
      |> Ash.read!(authorize?: false)
      |> Enum.filter(&App.Access.can?(&1, "audit.read"))
      |> Enum.map(& &1.id)

    for rule <- violations |> Enum.map(& &1.rule.label) |> Enum.uniq() do
      Emitter.emit(:incident, reviewers, %{rule: rule, path: "/incidents"})
    end

    :ok
  end
end
