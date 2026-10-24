defmodule App.Documents.InboxTest do
  @moduledoc "docs/design/inbox-first.md: deadlines and order of what waits for the viewer."
  use ExUnit.Case, async: true

  alias App.Documents.Inbox

  @today ~D[2026-11-10]

  defp doc(id, opts \\ []) do
    %{
      id: id,
      due_on: opts[:due_on],
      due: opts[:due],
      returned?: opts[:returned?] || false,
      updated_at: opts[:updated_at] || ~U[2026-11-01 08:00:00.000000Z]
    }
  end

  test "urgency of a due date" do
    assert Inbox.urgency(nil, @today) == nil
    assert Inbox.urgency(~D[2026-11-09], @today) == :overdue
    assert Inbox.urgency(@today, @today) == :today
    assert Inbox.urgency(~D[2026-11-13], @today) == :soon
    assert Inbox.urgency(~D[2026-11-14], @today) == :later
  end

  test "a step is due some days after it became pending; the earlier date wins" do
    assert Inbox.step_due(~U[2026-11-01 23:00:00Z], 3) == ~D[2026-11-04]
    assert Inbox.earliest(nil, ~D[2026-11-04]) == ~D[2026-11-04]
    assert Inbox.earliest(~D[2026-11-02], ~D[2026-11-04]) == ~D[2026-11-02]
    assert Inbox.earliest(nil, nil) == nil
  end

  test "one list: overdue first, then by due date, undated last and older first" do
    inbox = %{
      to_decide: [doc("sign-late", due: ~D[2026-11-08]), doc("sign-later", due: ~D[2026-11-20])],
      my_drafts: [
        doc("returned", returned?: true, updated_at: ~U[2026-10-01 08:00:00.000000Z]),
        doc("plain draft")
      ],
      team: [doc("team-today", due_on: @today)]
    }

    acknowledge = [doc("ack")]
    items = Inbox.items(inbox, acknowledge, @today)

    assert Enum.map(items, & &1.document.id) ==
             ["sign-late", "team-today", "sign-later", "returned", "ack"]

    assert Enum.map(items, & &1.reason) == [
             :to_decide,
             :team,
             :to_decide,
             :returned,
             :to_acknowledge
           ]

    assert Inbox.overdue(items) == 1
  end
end
