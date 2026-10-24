defmodule App.Accounts.PersonLogin do
  @moduledoc """
  Asking to sign in with a PersonID (docs/design/events-and-person-login.md
  run as the system: for a person with an e-mail in a contact
  record (or in the person's own e-mail field), their account — created with the minimal role `person` if they have
  none — gets a single-use link to set the password
  (`App.Accounts.SetPasswordSender`, through the password strategy's
  reset request).

  The answer to the caller is always the same, whatever happened, so a
  PersonID can't be probed; what happened is the event
  `hrda.auth.first_sign_in.requested` (outcome sent, unknown, no_contact,
  conflict, disabled or locked). At most 3 requests per PersonID in 15
  minutes and 10 per address in an hour.
  """
  require Ash.Query

  alias App.Accounts.{Throttle, User}
  alias App.People.{Person, PersonId, PersonRecord}
  alias App.Search.Digest

  @doc "Handles a request for `input` (a PersonID as typed) from `ip`. Always `:ok`."
  @spec request(String.t(), String.t()) :: :ok
  def request(input, ip) do
    login = normalize(input)
    digest = Digest.digest(login)
    {outcome, user} = outcome(login, digest, ip)

    App.EventLog.emit(
      "hrda.auth.first_sign_in.requested",
      %{outcome: outcome, ip: ip, login_digest: digest},
      subject: user && "user/#{user.id}"
    )

    :ok
  end

  @doc "A PersonID as stored, however it was typed (`AAAA-BBBB-CCCC`, lower case, spaces)."
  @spec normalize(String.t() | nil) :: String.t()
  def normalize(input), do: PersonId.unformat(input || "")

  defp outcome(login, digest, ip) do
    cond do
      App.Settings.get("auth.person_login") != true ->
        {"disabled", nil}

      throttled?({:request_ip, ip}, 10, 3600) or throttled?({:request_login, digest}, 3, 900) ->
        {"locked", nil}

      true ->
        send_link(login)
    end
  end

  defp throttled?(key, limit, window),
    do: Throttle.locked_until(key) != nil or Throttle.fail(key, limit + 1, window) != :ok

  defp send_link(login) do
    with {:person, %Person{} = person} <- {:person, person(login)},
         {:email, email} when is_binary(email) <- {:email, contact_email(person)},
         {:ok, user} <- account(person, email) do
      User
      |> Ash.Query.for_read(:request_password_reset_token, %{login_id: person.person_id})
      |> Ash.read!(authorize?: false)

      {"sent", user}
    else
      {:person, nil} -> {"unknown", nil}
      {:email, nil} -> {"no_contact", nil}
      {:conflict, user} -> {"conflict", user}
    end
  end

  defp person(""), do: nil

  defp person(login) do
    Person
    |> Ash.Query.filter(person_id == ^login)
    |> Ash.read_one!(authorize?: false)
  end

  # The newest e-mail in the person's contact records, else the person's
  # own e-mail field (decrypted as the system: nobody is shown it, so
  # nothing goes to the access log).
  defp contact_email(person) do
    from_records(person.id) || valid_email(person.email)
  end

  defp valid_email(value) when is_binary(value), do: if(value =~ "@", do: String.trim(value))
  defp valid_email(_value), do: nil

  defp from_records(person_id) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and kind == :contact_info)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
    |> Enum.find_value(fn record ->
      data = record.data || %{}
      value = data["value"]
      if data["contactType"] == "email" and is_binary(value) and value =~ "@", do: value
    end)
  end

  # The person's account (its PersonID set), or a new one with the
  # minimal role. Another account already using the address is a
  # conflict: an administrator links them.
  defp account(person, email) do
    case User |> Ash.Query.filter(person_id == ^person.id) |> Ash.read_one!(authorize?: false) do
      %User{login_id: nil} = user ->
        user
        |> Ash.Changeset.for_update(:set_login_id, %{login_id: person.person_id})
        |> Ash.update(authorize?: false)

      %User{} = user ->
        {:ok, user}

      nil ->
        create(person, email)
    end
  end

  defp create(person, email) do
    case User |> Ash.Query.filter(email == ^email) |> Ash.read_one!(authorize?: false) do
      %User{} = other ->
        {:conflict, other}

      nil ->
        with {:ok, user} <-
               User
               |> Ash.Changeset.for_create(:create_for_person, %{
                 email: email,
                 login_id: person.person_id,
                 person_id: person.id
               })
               |> Ash.create(authorize?: false) do
          App.EventLog.emit(
            "hrda.accounts.user.created",
            %{method: "person_id", role: user.role},
            subject: "user/#{user.id}"
          )

          {:ok, user}
        end
    end
  end
end
