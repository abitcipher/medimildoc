defmodule App.OrgGraph.Relations do
  @moduledoc """
  ORG-GRAPH.4 (docs/design/org-graph.md): relations between the people on
  the org graph beyond the structure, each loaded only when its layer is
  shown, read as the viewer:

  - `duty` — on duty together (same day, same unit's roster) this month;
  - `approvals` — who approved or signed whose documents (last 90 days);
  - `acknowledgements` — who acknowledged orders signed by whom (90 days);
  - `referrals` — a person referred to a care provider (sensitive: only
    referrals the viewer may read, each written to the access log);
  - `family` — a person's dependants (personnel-private records, read
    through their policy; decrypting them is logged like everywhere).

  Pairs are counted: `{from, to, count}`. Only people on the graph
  (`people`, ids) take part. Document fields are never read.
  """
  require Ash.Query

  alias App.Accounts.User
  alias App.Audit.AccessLogger
  alias App.Documents.{Acknowledgement, Document, Step}
  alias App.Duty.Shift
  alias App.People.PersonRecord

  @days 90

  @type t :: %{
          optional(:duty) => [{String.t(), String.t(), pos_integer()}],
          optional(:approvals) => [{String.t(), String.t(), pos_integer()}],
          optional(:acknowledgements) => [{String.t(), String.t(), pos_integer()}],
          optional(:referrals) => [{String.t(), String.t()}],
          optional(:family) => [map()]
        }

  @layers ~w(duty approvals acknowledgements referrals family)

  @doc "The relation layers (each needs its own data)."
  @spec layers() :: [String.t()]
  def layers, do: @layers

  @doc "The relations for `layers` among `person_ids`, read as `actor`."
  @spec load(Enumerable.t(), [String.t()], map(), Date.t()) :: t()
  def load(layers, person_ids, actor, today \\ Date.utc_today()) do
    ids = MapSet.new(person_ids)

    for layer <- @layers, layer in layers, MapSet.size(ids) > 0, into: %{} do
      {String.to_existing_atom(layer), load_layer(layer, ids, actor, today)}
    end
  end

  defp load_layer("duty", ids, actor, today) do
    first = Date.beginning_of_month(today)

    Shift
    |> Ash.Query.filter(
      person_id in ^MapSet.to_list(ids) and date >= ^first and date <= ^Date.end_of_month(today)
    )
    |> Ash.Query.select([:person_id, :organization_id, :date])
    |> Ash.read(actor: actor)
    |> case do
      {:ok, shifts} ->
        shifts
        |> Enum.group_by(&{&1.date, &1.organization_id}, & &1.person_id)
        |> Enum.flat_map(fn {_day, people} -> pairs(Enum.uniq(people)) end)
        |> count()

      _ ->
        []
    end
  end

  defp load_layer("approvals", ids, actor, today) do
    documents = recent_documents(actor, today)
    steps = decided_steps(documents, [:approved, :signed])

    person_of =
      person_of_users(Enum.map(documents, & &1.author_id) ++ Enum.map(steps, & &1.decided_by_id))

    author = Map.new(documents, &{&1.id, person_of[&1.author_id]})

    steps
    |> Enum.map(&{person_of[&1.decided_by_id], author[&1.document_id]})
    |> Enum.filter(fn {from, to} -> from != to and in?(ids, from) and in?(ids, to) end)
    |> count()
  end

  defp load_layer("acknowledgements", ids, actor, today) do
    steps = actor |> recent_documents(today) |> decided_steps([:signed])
    person_of = person_of_users(Enum.map(steps, & &1.decided_by_id))
    signer = Map.new(steps, &{&1.document_id, person_of[&1.decided_by_id]})

    Acknowledgement
    |> Ash.Query.filter(document_id in ^Map.keys(signer))
    |> Ash.Query.select([:document_id, :person_id])
    |> Ash.read!(authorize?: false)
    |> Enum.map(&{signer[&1.document_id], &1.person_id})
    |> Enum.filter(fn {from, to} -> from != to and in?(ids, from) and in?(ids, to) end)
    |> count()
  end

  defp load_layer("referrals", ids, actor, _today) do
    referrals =
      Document
      |> Ash.Query.filter(
        type == :care_referral and person_id in ^MapSet.to_list(ids) and
          not is_nil(recipient_provider_id)
      )
      |> Ash.Query.select([:id, :type, :person_id, :recipient_provider_id])
      |> Ash.read!(actor: actor)

    # Fail closed: not logged, not shown.
    case AccessLogger.log_graph_relations(actor, referrals) do
      :ok -> referrals |> Enum.map(&{&1.person_id, &1.recipient_provider_id}) |> Enum.uniq()
      _ -> []
    end
  end

  defp load_layer("family", ids, actor, _today) do
    PersonRecord
    |> Ash.Query.filter(kind == :dependent and person_id in ^MapSet.to_list(ids))
    |> Ash.read!(actor: actor)
    |> Enum.map(fn record ->
      %{
        id: record.id,
        person_id: record.person_id,
        name: (record.data || %{})["name"],
        relationship: (record.data || %{})["relationship"]
      }
    end)
  end

  # Documents the viewer may read, changed in the last @days (no fields).
  defp recent_documents(actor, today) do
    since = DateTime.new!(Date.add(today, -@days), ~T[00:00:00], "Etc/UTC")

    Document
    |> Ash.Query.filter(updated_at >= ^since)
    |> Ash.Query.select([:id, :author_id, :person_id])
    |> Ash.read!(actor: actor)
  end

  # The decided steps of documents the viewer may read.
  defp decided_steps([], _statuses), do: []

  defp decided_steps(documents, statuses) do
    Step
    |> Ash.Query.filter(
      document_id in ^Enum.map(documents, & &1.id) and status in ^statuses and
        not is_nil(decided_by_id)
    )
    |> Ash.Query.select([:document_id, :decided_by_id])
    |> Ash.read!(authorize?: false)
  end

  # Which person each account belongs to (only the link, never the user).
  defp person_of_users(user_ids) do
    user_ids = user_ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    User
    |> Ash.Query.filter(id in ^user_ids and not is_nil(person_id))
    |> Ash.Query.select([:id, :person_id])
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1.person_id})
  end

  defp in?(_ids, nil), do: false
  defp in?(ids, id), do: MapSet.member?(ids, id)

  defp pairs([]), do: []
  defp pairs([a | rest]), do: Enum.map(rest, &Enum.min_max([a, &1])) ++ pairs(rest)

  defp count(pairs) do
    pairs
    |> Enum.map(fn
      {a, b} -> {a, b}
      [a, b] -> {a, b}
    end)
    |> Enum.frequencies()
    |> Enum.map(fn {{a, b}, n} -> {a, b, n} end)
  end
end
