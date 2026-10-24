defmodule App.EventLogTest do
  @moduledoc "docs/design/events-and-person-login.md: the general event log."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.EventLog
  alias App.Events.{Catalog, Envelope, Event, Publisher}

  defp events(type), do: Event |> Ash.Query.filter(type == ^type) |> Ash.read!(authorize?: false)

  test "every declared type is hrda.<domain>.<subject>.<action>" do
    for type <- Catalog.types(), do: assert(type =~ ~r/^hrda(\.[a-z][a-z0-9_]*){3}$/)
    assert Catalog.domain("hrda.auth.session.started") == "auth"
  end

  test "an event is written with its declared severity and becomes a CloudEvents packet" do
    user = user_fixture(:hr)

    EventLog.emit("hrda.auth.session.started", %{method: "google", ip: "203.0.113.5"},
      actor: user,
      subject: "user/#{user.id}"
    )

    assert [event] = events("hrda.auth.session.started")
    assert %{severity: "notice", actor_id: actor, publish: false} = event
    assert actor == user.id

    packet = Envelope.build(event)
    assert packet["specversion"] == "1.0"
    assert packet["type"] == "hrda.auth.session.started"
    assert packet["source"] == "/hrda/local/auth"
    assert packet["subject"] == "user/#{user.id}"
    assert packet["data"] == %{"method" => "google", "ip" => "203.0.113.5"}
    assert packet["actorid"] == user.id
    assert {:ok, _} = Jason.encode(packet)
  end

  test "undeclared types and fields raise" do
    assert_raise ArgumentError, fn -> EventLog.emit("hrda.auth.login.error") end

    assert_raise ArgumentError, fn ->
      EventLog.emit("hrda.auth.session.started", %{name: "Someone"})
    end
  end

  test "with the log off nothing is written but the switch itself, with who did it" do
    admin = user_fixture(:admin)
    assert :ok = EventLog.set_logging(false, admin)
    refute EventLog.logging?()

    EventLog.emit("hrda.auth.session.ended", %{ip: "203.0.113.5"})
    assert events("hrda.auth.session.ended") == []
    assert [%{actor_id: id, severity: "critical"}] = events("hrda.events.logging.disabled")
    assert id == admin.id

    assert :ok = EventLog.set_logging(true, admin)
    assert [_] = events("hrda.events.logging.enabled")
  end

  test "only an administrator with settings.manage may switch" do
    assert {:error, :forbidden} = EventLog.set_logging(false, user_fixture(:hr))
    assert EventLog.logging?()
  end

  test "published only when declared so and publishing is on; switching off is published last" do
    admin = user_fixture(:admin)
    EventLog.emit("hrda.auth.sign_in.failed", %{method: "person_id", reason: "bad_credentials"})
    assert [%{publish: false}] = events("hrda.auth.sign_in.failed")

    :ok = EventLog.set_publishing(true, admin)
    EventLog.emit("hrda.auth.sign_in.failed", %{method: "person_id", reason: "locked"})
    EventLog.emit("hrda.auth.session.ended", %{})

    assert [true] =
             "hrda.auth.sign_in.failed"
             |> events()
             |> Enum.filter(& &1.publish)
             |> Enum.map(& &1.publish)

    assert [%{publish: false}] = events("hrda.auth.session.ended")

    :ok = EventLog.set_publishing(false, admin)
    assert [%{publish: true}] = events("hrda.events.publishing.disabled")
  end

  test "the publisher sends waiting packets in order, keyed by type, and marks them" do
    :ok = EventLog.set_publishing(true, user_fixture(:admin))
    EventLog.emit("hrda.auth.sign_in.failed", %{method: "google", reason: "provider_error"})
    EventLog.emit("hrda.auth.session.ended", %{})

    me = self()
    publish = fn key, body, id -> send(me, {:sent, key, Jason.decode!(body), id}) && :ok end

    # publishing.enabled, then sign_in.failed; session.ended is not published.
    assert Publisher.publish_due(publish) == 2
    assert_received {:sent, "hrda.events.publishing.enabled", _, _}
    assert_received {:sent, "hrda.auth.sign_in.failed", %{"id" => id} = packet, id}
    assert packet["data"]["reason"] == "provider_error"
    assert Publisher.publish_due(publish) == 0

    # A failure stops the batch; the event waits for the next tick.
    EventLog.emit("hrda.auth.sign_in.failed", %{method: "google", reason: "provider_error"})
    assert Publisher.publish_due(fn _, _, _ -> {:error, :closed} end) == 0
    assert Publisher.publish_due(publish) == 1
  end
end
