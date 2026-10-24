defmodule AppWeb.FhirSmartTest do
  @moduledoc "docs/design/fhir-api.md §Phase 2: external systems via SMART backend services."
  use AppWeb.ConnCase, async: false

  import App.Fixtures

  alias App.Api.Client
  alias App.Care.Provider
  alias App.Documents.Document

  setup do
    App.Access.put_admin_full_data_access_override(false)
    admin = user_fixture(:admin)
    unit = org_fixture("A Company")
    referred = person_fixture(%{given_name: "Olena"}) |> assign_fixture(unit)
    other = person_fixture(%{given_name: "Taras"}) |> assign_fixture(unit)
    clinician = unit_user_fixture(:viewer, [:clinician], unit)

    hospital =
      provider!(%{
        name: "Regional Hospital",
        agreement_ref: "DSA-1",
        agreement_until: Date.add(Date.utc_today(), 90)
      })

    for person <- [referred, other],
        do:
          record_fixture(
            person,
            :medical_condition,
            App.Demo.sample_record_data(:medical_condition)
          )

    national_id!(referred)
    refer!(referred, hospital, clinician)

    key = JOSE.JWK.generate_key({:ec, "P-384"})
    {_, public} = JOSE.JWK.to_public_map(key)

    client =
      Client
      |> Ash.Changeset.for_create(
        :create_external,
        %{
          name: "hospital-ehr",
          provider_id: hospital.id,
          jwks: %{"keys" => [Map.put(public, "kid", "k1")]},
          scopes: ["Patient", "Condition"]
        },
        actor: admin
      )
      |> Ash.create!(actor: admin)

    %{
      admin: admin,
      referred: referred,
      other: other,
      hospital: hospital,
      client: client,
      key: key
    }
  end

  defp national_id!(person) do
    App.People.PersonIdentifier
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, id_type: :rnokpp, country: "UA", value: "TEST-5555566666"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp provider!(attrs) do
    Provider
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp refer!(person, provider, clinician) do
    data = %{
      "provider" => provider.id,
      "service" => "consultation",
      "priority" => "routine",
      "reason" => "Review"
    }

    Document
    |> Ash.Changeset.for_create(
      :create,
      %{type: :care_referral, person_id: person.id, data: data},
      actor: clinician
    )
    |> Ash.create!(actor: clinician)
    |> Ash.Changeset.for_update(:submit, %{assignees: [[clinician.id]]}, actor: clinician)
    |> Ash.update!(actor: clinician)
    |> Ash.Changeset.for_update(:sign, %{}, actor: clinician)
    |> Ash.update!(actor: clinician)
  end

  defp assertion(ctx, overrides \\ %{}, key \\ nil) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => ctx.client.id,
          "sub" => ctx.client.id,
          "aud" => AppWeb.FhirController.token_url(),
          "exp" => now + 240,
          "jti" => Ecto.UUID.generate()
        },
        overrides
      )

    {_, jwt} =
      (key || ctx.key)
      |> JOSE.JWT.sign(%{"alg" => "ES384", "kid" => "k1"}, claims)
      |> JOSE.JWS.compact()

    jwt
  end

  defp token_request(assertion, scope \\ "system/*.rs") do
    build_conn()
    |> post("/fhir/auth/token", %{
      "grant_type" => "client_credentials",
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => assertion,
      "scope" => scope
    })
  end

  defp access_token(ctx) do
    conn = token_request(assertion(ctx))
    assert conn.status == 200, conn.resp_body
    Jason.decode!(conn.resp_body)
  end

  defp get_fhir(token, path) do
    build_conn()
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> get("/fhir/R5/" <> path)
  end

  defp error(conn), do: Jason.decode!(conn.resp_body)["error"]

  test "discovery names the token endpoint" do
    config = build_conn() |> get("/fhir/R5/.well-known/smart-configuration") |> json_response(200)
    assert config["token_endpoint"] == "https://hrda.test/fhir/auth/token"
    assert "private_key_jwt" in config["token_endpoint_auth_methods_supported"]
  end

  test "an external system reads only referred patients and the granted types", ctx do
    %{"access_token" => token, "expires_in" => 300, "scope" => scope} = access_token(ctx)
    assert scope == "system/Patient.rs system/Condition.rs"

    patient = get_fhir(token, "Patient/#{ctx.referred.id}") |> json_response(200)
    # No national IDs for external systems.
    assert [%{"system" => "urn:hrda:person-id"}] = patient["identifier"]

    assert get_fhir(token, "Patient/#{ctx.other.id}").status == 404

    assert %{"total" => 1} =
             get_fhir(token, "Condition?patient=#{ctx.referred.id}") |> json_response(200)

    assert %{"total" => 0} =
             get_fhir(token, "Condition?patient=#{ctx.other.id}") |> json_response(200)

    # Not granted to this client.
    assert get_fhir(token, "Observation?patient=#{ctx.referred.id}").status == 403
    assert get_fhir(token, "Practitioner/#{ctx.admin.id}").status == 403

    # Sensitive reads are logged under the system's name.
    assert Enum.any?(
             Ash.read!(App.Audit.AccessLog, authorize?: false),
             &(&1.actor_email == "api:hospital-ehr" and &1.person_id == ctx.referred.id)
           )
  end

  test "assertions are checked: replay, key, audience, expiry, lifetime, scope", ctx do
    jwt = assertion(ctx)
    assert token_request(jwt).status == 200
    assert error(token_request(jwt)) == "invalid_client"

    stranger = JOSE.JWK.generate_key({:ec, "P-384"})
    assert error(token_request(assertion(ctx, %{}, stranger))) == "invalid_client"

    assert error(token_request(assertion(ctx, %{"aud" => "https://evil.test/token"}))) ==
             "invalid_client"

    now = System.system_time(:second)
    assert error(token_request(assertion(ctx, %{"exp" => now - 120}))) == "invalid_client"
    assert error(token_request(assertion(ctx, %{"exp" => now + 3600}))) == "invalid_client"

    conn = token_request(assertion(ctx), "system/Observation.rs")
    assert conn.status == 400 and error(conn) == "invalid_scope"

    assert error(token_request(assertion(ctx), "")) == "invalid_scope"
  end

  test "RS384 keys work; unsigned and HMAC-with-public-key tokens don't", ctx do
    rsa = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = JOSE.JWK.to_public_map(rsa)

    client =
      Client
      |> Ash.Changeset.for_create(
        :create_external,
        %{
          name: "rsa-ehr",
          provider_id: ctx.hospital.id,
          jwks: %{"keys" => [public]},
          scopes: ["Patient"]
        },
        actor: ctx.admin
      )
      |> Ash.create!(actor: ctx.admin)

    now = System.system_time(:second)

    claims = %{
      "iss" => client.id,
      "sub" => client.id,
      "aud" => AppWeb.FhirController.token_url(),
      "exp" => now + 240,
      "jti" => Ecto.UUID.generate()
    }

    {_, jwt} = rsa |> JOSE.JWT.sign(%{"alg" => "RS384"}, claims) |> JOSE.JWS.compact()
    assert token_request(jwt, "system/Patient.rs").status == 200

    # alg "none": no signature at all.
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)

    body =
      claims
      |> Map.put("jti", Ecto.UUID.generate())
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    assert error(token_request(header <> "." <> body <> ".")) == "invalid_client"

    # HS384 keyed with the public key (algorithm confusion).
    hmac = JOSE.JWK.from_oct(Jason.encode!(public))

    {_, forged} =
      hmac
      |> JOSE.JWT.sign(%{"alg" => "HS384"}, Map.put(claims, "jti", Ecto.UUID.generate()))
      |> JOSE.JWS.compact()

    assert error(token_request(forged)) == "invalid_client"
  end

  test "a lapsed agreement stops the system", ctx do
    %{"access_token" => token} = access_token(ctx)

    ctx.hospital
    |> Ash.Changeset.for_update(:update, %{agreement_until: Date.add(Date.utc_today(), -1)},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)

    assert get_fhir(token, "Patient/#{ctx.referred.id}").status == 401
    assert error(token_request(assertion(ctx))) == "invalid_client"
  end

  test "registration: admins only, external providers with an agreement, public keys", ctx do
    {_, public} = ctx.key |> JOSE.JWK.to_public_map()
    {_, private} = ctx.key |> JOSE.JWK.to_map()

    create = fn actor, attrs ->
      Client
      |> Ash.Changeset.for_create(
        :create_external,
        Map.merge(
          %{name: "x", provider_id: ctx.hospital.id, jwks: %{"keys" => [public]}, scopes: ["*"]},
          attrs
        ),
        actor: actor
      )
      |> Ash.create(actor: actor)
    end

    assert {:ok, _} = create.(ctx.admin, %{name: "ok"})
    assert {:error, %Ash.Error.Forbidden{}} = create.(user_fixture(:hr), %{})
    assert {:error, e} = create.(ctx.admin, %{jwks: %{"keys" => [private]}})
    assert Exception.message(e) =~ "no private part"

    own = provider!(%{name: "Role 3", priority: true})
    assert {:error, e} = create.(ctx.admin, %{provider_id: own.id})
    assert Exception.message(e) =~ "service clients"

    no_agreement = provider!(%{name: "Clinic"})
    assert {:error, e} = create.(ctx.admin, %{provider_id: no_agreement.id})
    assert Exception.message(e) =~ "agreement"

    assert {:error, e} = create.(ctx.admin, %{scopes: ["Practitioner"]})
    assert Exception.message(e) =~ "unknown resource types"
  end
end
