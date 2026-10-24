defmodule App.NotifyTest do
  @moduledoc "docs/design/search-timeline-notifications.md §Notifications."
  use App.DataCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Documents.Document
  alias App.Notify.{Channel, Delivery, Emitter, Notification, Subscription}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    %{hr: user_fixture(:hr), hr_head: user_fixture(:hr), person: person_fixture()}
  end

  defp subscribe(user, event, channel) do
    Subscription
    |> Ash.Changeset.for_create(:create, %{user_id: user.id, event: event, channel: channel},
      actor: user
    )
    |> Ash.create!(actor: user)
  end

  defp notifications(user) do
    Notification
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  test "a document waiting for someone notifies them on the channels they subscribed to", ctx do
    subscribe(ctx.hr_head, :document_waiting, :in_app)
    subscribe(ctx.hr_head, :document_waiting, :telegram)

    {:ok, document} =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{type: :medical_board_referral, person_id: ctx.person.id, data: %{"reason" => "entry"}},
        actor: ctx.hr
      )
      |> Ash.create(actor: ctx.hr)

    document
    |> Ash.Changeset.for_update(:submit, %{assignees: [[ctx.hr_head.id]]}, actor: ctx.hr)
    |> Ash.update!(actor: ctx.hr)

    assert [in_app, telegram] = notifications(ctx.hr_head)
    assert {in_app.channel, in_app.status} == {:in_app, :sent}
    assert {telegram.channel, telegram.status} == {:telegram, :pending}
    assert in_app.title == "A document waits for your decision"
    assert in_app.path == "/documents/#{document.id}"
    # Nobody else subscribed, and the message names no person.
    assert notifications(ctx.hr) == []
    refute in_app.body =~ ctx.person.family_name
  end

  test "delivery through Apprise: the recipient's address, success and retry", ctx do
    Channel
    |> Ash.Changeset.for_create(:create, %{user_id: ctx.hr.id, kind: :telegram, address: "4242"},
      actor: ctx.hr
    )
    |> Ash.create!(actor: ctx.hr)

    subscribe(ctx.hr, :document_signed, :telegram)

    Emitter.emit(:document_signed, [ctx.hr.id], %{
      type: "Leave request",
      number: "7-рап",
      path: "/documents/x"
    })

    [notification] = notifications(ctx.hr)

    Req.Test.stub(App.Notify.Apprise, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:apprise, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)

    assert Delivery.deliver(notification.id) == :sent
    assert_received {:apprise, %{"urls" => "tgram://123456:TESTTOKEN/4242", "body" => body}}
    assert body =~ "Leave request 7-рап"
    assert body =~ "https://hrda.test/documents/x"
    assert Ash.get!(Notification, notification.id, authorize?: false).status == :sent

    # A failure is kept with the next attempt scheduled.
    Emitter.emit(:document_signed, [ctx.hr.id], %{type: "Order", number: "1-ос"})
    [_, second] = notifications(ctx.hr)
    Req.Test.stub(App.Notify.Apprise, &Plug.Conn.send_resp(&1, 500, "smtp down"))
    assert Delivery.deliver(second.id) == :failed
    failed = Ash.get!(Notification, second.id, authorize?: false)
    assert failed.attempts == 1 and failed.last_error =~ "500"
    assert DateTime.compare(failed.next_attempt_at, DateTime.utc_now()) == :gt
  end

  test "e-mail goes to the sign-in address when no other is set; unconfigured channels fail",
       ctx do
    Emitter.emit(:registration, [ctx.hr.id])
    assert [%{channel: :in_app}, %{channel: :email} = email] = notifications(ctx.hr)

    Req.Test.stub(App.Notify.Apprise, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), {:apprise, Jason.decode!(body)})
      Req.Test.json(conn, %{})
    end)

    assert Delivery.deliver(email.id) == :sent
    assert_received {:apprise, %{"urls" => url}}
    assert url =~ "&to=" <> URI.encode_www_form(to_string(ctx.hr.email))

    subscribe(ctx.hr, :document_signed, :matrix)
    Emitter.emit(:document_signed, [ctx.hr.id], %{type: "Order"})
    matrix = ctx.hr |> notifications() |> List.last()
    assert Delivery.deliver(matrix.id) == :failed
  end

  test "a new account gets the registration confirmation once, not on later sign-ins" do
    register = fn ->
      App.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_google,
        %{
          user_info: %{"email" => "newcomer@example.test", "name" => "Newcomer", "sub" => "g-1"},
          oauth_tokens: %{"access_token" => "token", "expires_in" => 3600}
        },
        authorize?: false,
        context: %{strategy: AshAuthentication.Info.strategy!(App.Accounts.User, :google)}
      )
      |> Ash.create!(authorize?: false)
    end

    user = register.()
    assert [%{event: :registration, channel: :in_app}, %{channel: :email}] = notifications(user)

    register.()
    assert length(notifications(user)) == 2
  end

  test "users manage only their own channels and subscriptions", ctx do
    assert {:error, %Ash.Error.Forbidden{}} =
             Subscription
             |> Ash.Changeset.for_create(
               :create,
               %{user_id: ctx.hr_head.id, event: :incident, channel: :in_app},
               actor: ctx.hr
             )
             |> Ash.create(actor: ctx.hr)

    subscribe(ctx.hr_head, :incident, :in_app)
    assert Ash.read!(Subscription, actor: ctx.hr) == []
  end
end
