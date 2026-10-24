defmodule AppWeb.FhirApiTest do
  @moduledoc "docs/design/fhir-api.md: the FHIR R5 read API."
  use AppWeb.ConnCase, async: false

  import App.Fixtures

  require Ash.Query

  alias App.Api.Client

  setup do
    App.Access.put_admin_full_data_access_override(false)
    admin = user_fixture(:admin)
    unit = org_fixture("A Company")

    person =
      person_fixture(%{given_name: "Olena", family_name: "Kovalenko"}) |> assign_fixture(unit)

    other = person_fixture(%{given_name: "Taras"}) |> assign_fixture(unit)

    condition =
      record_fixture(person, :medical_condition, App.Demo.sample_record_data(:medical_condition))

    record_fixture(other, :medical_condition, App.Demo.sample_record_data(:medical_condition))

    %{admin: admin, person: person, other: other, condition: condition}
  end

  defp service_token(admin, profiles, attrs \\ %{}) do
    params = Map.merge(%{name: "export", profiles: profiles}, attrs)

    Client
    |> Ash.Changeset.for_create(:create_service, params, actor: admin)
    |> Ash.create!(actor: admin)
    |> then(&{&1, &1.__metadata__.token})
  end

  defp get_fhir(conn, token, path) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> get("/fhir/R5/" <> path)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "metadata is public; everything else needs a valid token", %{conn: conn} do
    assert %{"resourceType" => "CapabilityStatement", "fhirVersion" => "5.0.0"} =
             conn |> get("/fhir/R5/metadata") |> body()

    conn = get(build_conn(), "/fhir/R5/Patient")
    assert conn.status == 401
    assert %{"resourceType" => "OperationOutcome"} = body(conn)
    assert get_fhir(build_conn(), "hrda_unknown", "Patient").status == 401
  end

  test "a service client reads what its profiles allow, and the reads are logged", ctx do
    {client, token} = service_token(ctx.admin, [:health_data_reader])

    patient = get_fhir(build_conn(), token, "Patient/#{ctx.person.id}") |> body()
    assert patient["resourceType"] == "Patient"
    assert [%{"family" => "Kovalenko"}] = patient["name"]

    bundle = get_fhir(build_conn(), token, "Condition?patient=#{ctx.person.id}") |> body()
    assert %{"resourceType" => "Bundle", "type" => "searchset", "total" => 1} = bundle
    assert [%{"resource" => %{"id" => id, "resourceType" => "Condition"}}] = bundle["entry"]
    assert id == ctx.condition.id

    assert %{"resourceType" => "Condition"} =
             get_fhir(build_conn(), token, "Condition/#{ctx.condition.id}") |> body()

    logged =
      App.Audit.AccessLog
      |> Ash.Query.filter(actor_id == ^client.id)
      |> Ash.read!(authorize?: false)

    assert logged != []
    assert Enum.all?(logged, &(&1.actor_email == "api:export"))

    # A search needs a patient.
    assert get_fhir(build_conn(), token, "Condition").status == 400
  end

  test "without a clinical profile, clinical data is simply not there", ctx do
    {_client, token} = service_token(ctx.admin, [])
    assert get_fhir(build_conn(), token, "Patient/#{ctx.person.id}").status == 200

    assert %{"total" => 0} =
             get_fhir(build_conn(), token, "Condition?patient=#{ctx.person.id}") |> body()

    assert get_fhir(build_conn(), token, "Condition/#{ctx.condition.id}").status == 404
  end

  test "a personal token reads the owner's record, and nobody else's", ctx do
    owner =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "olena@example.test",
        role: :viewer,
        person_id: ctx.person.id
      })

    client =
      Client
      |> Ash.Changeset.for_create(:create_personal, %{name: "my phone"}, actor: owner)
      |> Ash.create!(actor: owner)

    token = client.__metadata__.token

    assert get_fhir(build_conn(), token, "Patient/#{ctx.person.id}").status == 200
    assert get_fhir(build_conn(), token, "Patient/#{ctx.other.id}").status == 404

    # Medical records of their own, though a viewer can't read them in the app.
    assert %{"total" => 1} = get_fhir(build_conn(), token, "Condition") |> body()

    assert %{"total" => 0} =
             get_fhir(build_conn(), token, "Condition?patient=#{ctx.other.id}") |> body()

    assert get_fhir(build_conn(), token, "Practitioner/#{owner.id}").status == 403

    # Revoked: refused.
    client |> Ash.Changeset.for_update(:revoke, %{}, actor: owner) |> Ash.update!(actor: owner)
    assert get_fhir(build_conn(), token, "Patient/#{ctx.person.id}").status == 401
  end

  test "expired tokens and unit profiles are refused", ctx do
    {_client, token} =
      service_token(ctx.admin, [], %{expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})

    assert get_fhir(build_conn(), token, "Patient").status == 401

    assert {:error, error} =
             Client
             |> Ash.Changeset.for_create(:create_service, %{name: "x", profiles: [:clinician]},
               actor: ctx.admin
             )
             |> Ash.create(actor: ctx.admin)

    assert Exception.message(error) =~ "not global access profiles"

    viewer = user_fixture(:viewer)

    assert {:error, %Ash.Error.Forbidden{}} =
             Client
             |> Ash.Changeset.for_create(:create_service, %{name: "y"}, actor: viewer)
             |> Ash.create(actor: viewer)
  end
end
