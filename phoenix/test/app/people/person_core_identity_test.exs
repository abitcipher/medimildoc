defmodule App.People.PersonCoreIdentityTest do
  @moduledoc """
  DB-backed coverage for (core Person attributes +
  PersonIdentifier/IdentityDocument/BiometricRecord) — the first People
  resource tests to run against a real Postgres via `App.DataCase` rather
  than only live-verified in Docker (earlier resources in this domain
  predate having a local Postgres available to this sandbox — see
  for why those settled for Docker-only verification).
  """
  use App.DataCase, async: true

  alias App.People.{BiometricRecord, IdentityDocument, Person, PersonId, PersonIdentifier}

  setup do
    admin =
      Ash.Seed.seed!(App.Accounts.User, %{
        email: "admin-#{Ash.UUIDv7.generate()}@example.com",
        role: :admin
      })

    person =
      Person
      |> Ash.Changeset.for_create(
        :create,
        %{
          given_name: "Ada",
          family_name: "Lovelace",
          patronymic: "Byron",
          birth_country: "GB",
          birth_region: "London",
          birth_locality: "Marylebone"
        },
        actor: admin
      )
      |> Ash.create!()

    %{admin: admin, person: person}
  end

  describe "Person — patronymic + place of birth" do
    test "creates and persists all three place-of-birth fields plus patronymic", %{
      person: person
    } do
      assert person.patronymic == "Byron"
      assert person.birth_country == "GB"
      assert person.birth_region == "London"
      assert person.birth_locality == "Marylebone"
    end

    test "all four fields stay optional", %{admin: admin} do
      assert {:ok, person} =
               Person
               |> Ash.Changeset.for_create(:create, %{given_name: "No", family_name: "Details"},
                 actor: admin
               )
               |> Ash.create()

      assert person.patronymic == nil
      assert person.birth_country == nil
    end
  end

  describe "Person — person_id" do
    test "is generated automatically and has the expected shape", %{person: person} do
      assert person.person_id != nil
      assert PersonId.valid?(person.person_id)
    end

    test "two different people get different person_ids", %{admin: admin, person: person} do
      {:ok, other} =
        Person
        |> Ash.Changeset.for_create(:create, %{given_name: "Grace", family_name: "Hopper"},
          actor: admin
        )
        |> Ash.create()

      assert other.person_id != person.person_id
    end

    test "cannot be supplied directly by a caller — not in :create's accept list", %{
      admin: admin
    } do
      assert {:error, %Ash.Error.Invalid{}} =
               Person
               |> Ash.Changeset.for_create(
                 :create,
                 %{given_name: "Spoofed", family_name: "Id", person_id: "AAAABBBBCCCC"},
                 actor: admin
               )
               |> Ash.create()
    end

    test "is not in :update's accept list — stays the same across an update", %{
      admin: admin,
      person: person
    } do
      {:ok, updated} =
        person
        |> Ash.Changeset.for_update(:update, %{given_name: "Augusta"}, actor: admin)
        |> Ash.update()

      assert updated.person_id == person.person_id
    end
  end

  describe "PersonIdentifier — AtMostOneCurrentIdentifier" do
    test "accepts the first current identifier of a given type+country", %{
      admin: admin,
      person: person
    } do
      assert {:ok, identifier} =
               PersonIdentifier
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, id_type: :ssn, country: "US", value: "123-45-6789"},
                 actor: admin
               )
               |> Ash.create()

      assert identifier.is_current == true
    end

    test "rejects a second simultaneously-current identifier of the same type+country", %{
      admin: admin,
      person: person
    } do
      {:ok, _first} =
        PersonIdentifier
        |> Ash.Changeset.for_create(
          :create,
          %{person_id: person.id, id_type: :passport, country: "GB", value: "AAA111111"},
          actor: admin
        )
        |> Ash.create()

      assert {:error, error} =
               PersonIdentifier
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, id_type: :passport, country: "GB", value: "BBB222222"},
                 actor: admin
               )
               |> Ash.create()

      assert %Ash.Error.Invalid{} = error
    end

    test "allows a superseding identifier once the old one is flipped to not-current", %{
      admin: admin,
      person: person
    } do
      {:ok, old} =
        PersonIdentifier
        |> Ash.Changeset.for_create(
          :create,
          %{person_id: person.id, id_type: :passport, country: "GB", value: "AAA111111"},
          actor: admin
        )
        |> Ash.create()

      {:ok, _old} =
        old
        |> Ash.Changeset.for_update(:update, %{is_current: false}, actor: admin)
        |> Ash.update()

      assert {:ok, new} =
               PersonIdentifier
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, id_type: :passport, country: "GB", value: "BBB222222"},
                 actor: admin
               )
               |> Ash.create()

      assert new.is_current == true
    end

    test "matches nil country against nil country, not against a set one", %{
      admin: admin,
      person: person
    } do
      {:ok, _first} =
        PersonIdentifier
        |> Ash.Changeset.for_create(
          :create,
          %{person_id: person.id, id_type: :nif, value: "111111111"},
          actor: admin
        )
        |> Ash.create()

      # Same type, no country on either side -> should conflict.
      assert {:error, %Ash.Error.Invalid{}} =
               PersonIdentifier
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, id_type: :nif, value: "222222222"},
                 actor: admin
               )
               |> Ash.create()

      # Same type, but a *different* (non-nil) country -> no conflict.
      assert {:ok, _} =
               PersonIdentifier
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, id_type: :nif, country: "PT", value: "333333333"},
                 actor: admin
               )
               |> Ash.create()
    end

    test "a :viewer cannot create an identifier", %{person: person} do
      viewer =
        Ash.Seed.seed!(App.Accounts.User, %{
          email: "viewer-#{Ash.UUIDv7.generate()}@example.com",
          role: :viewer
        })

      assert {:error, %Ash.Error.Forbidden{}} =
               PersonIdentifier
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, id_type: :ssn, value: "000-00-0000"},
                 actor: viewer
               )
               |> Ash.create()
    end
  end

  describe "IdentityDocument" do
    test "creates a document and rejects expires_on before issued_on", %{
      admin: admin,
      person: person
    } do
      assert {:ok, doc} =
               IdentityDocument
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   person_id: person.id,
                   document_type: :passport,
                   number: "123456789",
                   issued_on: ~D[2020-01-01],
                   expires_on: ~D[2030-01-01]
                 },
                 actor: admin
               )
               |> Ash.create()

      # Encrypted: decrypted only on request.
      assert Ash.load!(doc, :number, authorize?: false).number == "123456789"

      assert {:error, %Ash.Error.Invalid{}} =
               IdentityDocument
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   person_id: person.id,
                   document_type: :passport,
                   number: "BADDATES",
                   issued_on: ~D[2030-01-01],
                   expires_on: ~D[2020-01-01]
                 },
                 actor: admin
               )
               |> Ash.create()
    end
  end

  describe "BiometricRecord" do
    test "fingerprint requires a finger", %{admin: admin, person: person} do
      assert {:error, %Ash.Error.Invalid{}} =
               BiometricRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, modality: :fingerprint},
                 actor: admin
               )
               |> Ash.create()

      assert {:ok, record} =
               BiometricRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, modality: :fingerprint, finger: :right_thumb},
                 actor: admin
               )
               |> Ash.create()

      assert record.finger == :right_thumb
    end

    test "photo/signature must NOT have a finger set", %{admin: admin, person: person} do
      assert {:error, %Ash.Error.Invalid{}} =
               BiometricRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, modality: :photo, finger: :right_thumb},
                 actor: admin
               )
               |> Ash.create()

      assert {:ok, record} =
               BiometricRecord
               |> Ash.Changeset.for_create(
                 :create,
                 %{person_id: person.id, modality: :photo},
                 actor: admin
               )
               |> Ash.create()

      assert record.finger == nil
      # storage_key deliberately unset here — no upload wiring exists yet
      # (moduledoc); this row is what the future upload feature would
      # eventually fill in.
      assert record.storage_key == nil
    end
  end
end
