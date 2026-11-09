defmodule App.Demo do
  @moduledoc """
  Synthetic data for automated and manual testing
  (docs/design/access-control-phase1.md). There is no real personal
  data in this project; everything a tester sees comes from here.

  - `seed/1` replaces all synthetic data with a fresh, repeatable set: a
    demo brigade (staff, three battalions of three companies, a
    Role 2 medical company and a Role 3 field hospital), positions with a
    command chain, people with assignments, national IDs, documents and
    records of every kind (edge cases included: expired clearances,
    downgraded fitness, high-criticality allergies), and one demo user per
    base role and access profile.
  - `purge/0` removes it again.

  Everything generated is marked so it can't be mistaken for, or collide
  with, real data: Person and Organization rows carry `synthetic: true`
  (shown as a badge, used by `purge/0`), national ID values start with
  `TEST-`, and emails use the reserved `.test` domain (RFC 6761). Demo
  users are recognised by that domain, `#{"@demo.test"}`.

  Names, structure and record values depend only on the `:seed` option;
  ids and dates relative to today differ between runs. Records go through
  the real Ash create actions (with `authorize?: false`), so every one is
  validated against its kind's JSON Schema.
  """

  require Ash.Query

  alias App.Accounts.User
  alias App.Demo.{Correspondence, Duty, Names}

  alias App.People.{
    Assignment,
    IdentityDocument,
    Organization,
    Person,
    PersonIdentifier,
    PersonRecord,
    Position
  }

  alias App.Documents.{Acknowledgement, Counter, Document}
  alias App.Repo

  @email_domain "demo.test"
  @default_people 150

  @doc "The email domain of generated people and demo users."
  @spec email_domain() :: String.t()
  def email_domain, do: @email_domain

  @doc """
  Replaces all synthetic data. Options: `:people` (default
  #{@default_people}) and `:seed` (default 1). Runs in one transaction.
  Returns counts of what was created.
  """
  @spec seed(keyword()) :: {:ok, map()} | {:error, term()}
  def seed(opts \\ []) do
    people = Keyword.get(opts, :people, @default_people)
    seed = Keyword.get(opts, :seed, 1)
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})

    App.Settings.without_fsdc(fn -> seed_all(people, seed) end)
  end

  defp seed_all(people, seed) do
    Repo.transaction(
      fn ->
        purge_rows()
        organizations = build_organizations()
        positions = build_positions(organizations, people)
        persons = Enum.map(1..people//1, &build_person/1)
        assignments = assign(persons, positions)

        built =
          persons
          |> Enum.zip(assignments)
          |> Enum.with_index(1)
          |> Enum.map(fn {pair, index} -> build_person_data(pair, {seed, index}) end)

        users = build_users(Enum.zip(persons, assignments))
        orders = build_orders(persons, users) + build_pending_orders(persons, users)
        Correspondence.build(users)
        Duty.build(users)
        providers = build_providers(organizations)
        planted = Enum.concat(built)

        %{
          organizations: count_organizations(organizations),
          positions: positions |> Enum.uniq_by(& &1.id) |> length(),
          people: length(persons),
          # Counted in the database (demo users get a clearance record too):
          # person records and assignments, what the rules check.
          items: count_items(),
          users: length(users),
          orders: orders,
          providers: length(providers),
          invalid: length(planted),
          planted: planted
        }
      end,
      timeout: :infinity
    )
  end

  @doc """
  Removes all synthetic data and the demo users. Audit trails (change
  conflicts, access log) are kept on purpose. Returns deleted row counts
  per table.
  """
  @spec purge() :: {:ok, map()} | {:error, term()}
  def purge, do: Repo.transaction(&purge_rows/0, timeout: :infinity)

  @doc """
  One valid `data` map for `kind` — the smallest realistic record. Shared
  with tests so fixtures and seeds agree on what a valid record looks like.
  """
  @spec sample_record_data(atom()) :: map()
  def sample_record_data(:medical_condition),
    do: %{"code" => %{"text" => "Asthma"}, "clinicalStatus" => "active"}

  def sample_record_data(:allergy_intolerance),
    do: %{"code" => %{"text" => "Penicillin"}, "clinicalStatus" => "active"}

  def sample_record_data(:encounter),
    do: %{"status" => "completed", "class" => "FLD", "start" => "2026-09-01T10:30"}

  def sample_record_data(:vital_signs),
    do: %{
      "measuredAt" => "2026-09-01T10:35",
      "systolic" => 124,
      "diastolic" => 78,
      "heartRate" => 72,
      "respiratoryRate" => 16,
      "spo2" => 98,
      "onOxygen" => false,
      "temperature" => 36.8,
      "consciousness" => "alert"
    }

  def sample_record_data(:medication_administration),
    do: %{
      "occurrence" => "2026-09-01T10:40",
      "status" => "completed",
      "medication" => %{"text" => "Tranexamic acid"},
      "dose" => %{"value" => 2, "unit" => "g"},
      "route" => "iv"
    }

  def sample_record_data(:procedure),
    do: %{
      "performed" => "2026-09-01T10:32",
      "status" => "completed",
      "code" => "tourniquet_limb",
      "bodySite" => "Thigh",
      "side" => "left",
      "outcome" => "successful"
    }

  def sample_record_data(:leave),
    do: %{
      "leaveType" => "annual",
      "startDate" => "2026-07-01",
      "endDate" => "2026-07-15",
      "days" => 15,
      "basis" => "12-ос"
    }

  def sample_record_data(:business_trip),
    do: %{
      "destination" => "Lviv, training centre",
      "purpose" => "Instructor course",
      "startDate" => "2026-07-01",
      "endDate" => "2026-07-05",
      "days" => 5,
      "basis" => "13-ос"
    }

  def sample_record_data(:medication_statement),
    do: %{
      "medication" => %{"text" => "Apixaban"},
      "adherence" => "taking",
      "dose" => %{"value" => 5, "unit" => "mg"},
      "route" => "po",
      "frequency" => "twice_daily",
      "effectiveStart" => "2025-03-01"
    }

  def sample_record_data(:lab_result),
    do: %{"test" => "hemoglobin", "value" => 138, "collectedAt" => "2026-09-20T08:30"}

  def sample_record_data(:status_change),
    do: %{"changeType" => "other", "description" => "Transfer"}

  def sample_record_data(:rank_history), do: %{"grade" => "OR-4", "effectiveDate" => "2026-01-01"}
  def sample_record_data(:contact_info), do: %{"contactType" => "email", "value" => "a@demo.test"}

  def sample_record_data(:language_proficiency),
    do: %{"language" => "en", "listening" => 3, "speaking" => 3, "reading" => 3, "writing" => 2}

  def sample_record_data(:family_status), do: %{"maritalStatus" => "married"}
  def sample_record_data(:dependent), do: %{"name" => "Kid", "relationship" => "child"}

  def sample_record_data(:compensation) do
    %{
      "amount" => 1000,
      "currency" => "EUR",
      "effectiveDate" => "2026-01-01",
      "reason" => "base_pay"
    }
  end

  def sample_record_data(:security_clearance),
    do: %{"clearanceLevel" => "NATO_SECRET", "status" => "granted"}

  def sample_record_data(:fitness_for_duty), do: %{"status" => "fit_for_duty"}
  def sample_record_data(:vetting_record), do: %{"investigationType" => "initial"}

  # --- purge -----------------------------------------------------------

  @synthetic_people "SELECT id FROM people WHERE synthetic"
  @synthetic_orgs "SELECT id FROM organizations WHERE synthetic"
  @synthetic_positions "SELECT id FROM positions WHERE organization_id IN (#{@synthetic_orgs})"

  # Order matters: children before parents, and the two self-references
  # (positions.reports_to_id, organizations.parent_id) are cleared before
  # their rows are deleted. Counts are reported for the deletes.
  defp count_items do
    for table <- ~w(person_records assignments), reduce: 0 do
      sum ->
        %{rows: [[count]]} =
          Repo.query!("SELECT count(*) FROM #{table} WHERE person_id IN (#{@synthetic_people})")

        sum + count
    end
  end

  defp purge_rows do
    demo_users = "SELECT id FROM users WHERE email LIKE '%@#{@email_domain}'"

    steps = [
      # Demo letters are about no person: removed by their test register.
      {:letters, "DELETE FROM documents WHERE person_id IS NULL AND register LIKE 'TEST-%'"},
      # Numbering of the demo's own test registers: a fresh seed starts at 1
      # again. Real registers have no TEST- prefix and are left alone.
      {:document_counters, "DELETE FROM document_counters WHERE register LIKE 'TEST-%'"},
      {:person_records, "DELETE FROM person_records WHERE person_id IN (#{@synthetic_people})"},
      {:person_identifiers,
       "DELETE FROM person_identifiers WHERE person_id IN (#{@synthetic_people})"},
      {:identity_documents,
       "DELETE FROM identity_documents WHERE person_id IN (#{@synthetic_people})"},
      {:biometric_records,
       "DELETE FROM biometric_records WHERE person_id IN (#{@synthetic_people})"},
      {:assignments,
       "DELETE FROM assignments WHERE person_id IN (#{@synthetic_people}) " <>
         "OR position_id IN (#{@synthetic_positions})"},
      {:people, "DELETE FROM people WHERE synthetic"},
      {:care_providers, "DELETE FROM care_providers WHERE synthetic"},
      {nil,
       "UPDATE positions SET reports_to_id = NULL WHERE organization_id IN (#{@synthetic_orgs})"},
      {:positions, "DELETE FROM positions WHERE organization_id IN (#{@synthetic_orgs})"},
      {nil, "UPDATE organizations SET parent_id = NULL WHERE synthetic"},
      {:organizations, "DELETE FROM organizations WHERE synthetic"},
      {:user_identities, "DELETE FROM user_identities WHERE user_id IN (#{demo_users})"},
      {:users, "DELETE FROM users WHERE email LIKE '%@#{@email_domain}'"}
    ]

    for {table, sql} <- steps, result = Repo.query!(sql), table, into: %{} do
      {table, result.num_rows}
    end
  end

  # --- organizations and positions --------------------------------------

  # Where the units are (ORG-GRAPH.1): fixed, no randomness (the
  # reference dataset doesn't move). Companies are where their battalion is.
  @battalion_places %{1 => "Demo City", 2 => "Demo Village", 3 => "Demo Town"}

  defp build_organizations do
    brigade = org("1st Demo Mechanized Brigade", :brigade, nil, "Demo City")

    battalions =
      for {ordinal, n} <- [{"1st", 1}, {"2nd", 2}, {"3rd", 3}] do
        battalion = org("#{ordinal} Battalion", :battalion, brigade, @battalion_places[n])

        companies =
          for letter <- ~w(A B C), do: org("#{letter} Company, #{n} Bn", :company, battalion)

        {battalion, companies}
      end

    role2 = org("Role 2 Medical Company", :company, brigade, "Demo Town")
    role3 = org("Role 3 Field Hospital", :unit, brigade, "Demo City")

    %{brigade: brigade, battalions: battalions, role2: role2, role3: role3}
  end

  # Care providers (docs/design/referral-discharge.md): our Role 2 and
  # Role 3 as priority units, and external ones with an agreement. No
  # randomness: the reference dataset doesn't move.
  @external_providers [
    {"Demo Regional Clinical Hospital", :hospital, "Demo City", "TEST-HOSP-001"},
    {"Demo City Polyclinic No. 2", :clinic, "Demo City", "TEST-CLIN-002"},
    {"Demo Diagnostic Imaging Centre", :diagnostic_center, "Demo City", "TEST-DIAG-003"},
    {"Demo Rehabilitation Centre", :rehabilitation, "Demo Village", "TEST-REHAB-004"},
    {"Demo Central Laboratory", :laboratory, "Demo City", "TEST-LAB-005"}
  ]

  defp build_providers(%{role2: role2, role3: role3}) do
    own =
      for {unit, type} <- [{role3, :hospital}, {role2, :medical_unit}] do
        provider(%{
          name: unit.name,
          provider_type: type,
          priority: true,
          organization_id: unit.id,
          country: "UA",
          locality: unit.locality
        })
      end

    external =
      for {name, type, locality, code} <- @external_providers do
        provider(%{
          name: name,
          provider_type: type,
          registry_code: code,
          country: "UA",
          locality: locality,
          agreement_ref: "TEST-AGR-#{code}",
          agreement_until: Date.add(today(), 365)
        })
      end

    own ++ external
  end

  defp provider(attrs) do
    App.Care.Provider
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.Changeset.force_change_attribute(:synthetic, true)
    |> Ash.create!(authorize?: false)
  end

  defp org(name, kind, parent, locality \\ nil) do
    Organization
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        kind: kind,
        parent_id: parent && parent.id,
        country: locality && "UA",
        locality: locality
      },
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:synthetic, true)
    |> Ash.create!(authorize?: false)
  end

  # Billets in priority order: the command chain and specialist posts
  # first, so even a small seed has a brigade commander, a surgeon, HR and
  # a security officer. Riflemen are added only for people beyond that.
  #
  # Returns slots: each post once per person it is for (its strength), so
  # posts shared by several people (Rifleman ×10) are one post.
  defp build_positions(orgs, people) do
    # Brigade staff posts sit on the brigade itself, so a staff member's
    # unit (e.g. the command surgeon's) is the whole brigade
    # (docs/design/access-control-phase2.md).
    hq = orgs.brigade
    commander = position("Brigade Commander", "OF-5", hq, nil)

    staff = [
      commander,
      position("Command Surgeon", "OF-4", hq, commander),
      position("S1 Personnel Officer", "OF-3", hq, commander),
      position("Patient Administration Officer", "OF-2", hq, commander),
      position("Security Officer", "OF-3", hq, commander),
      position("Information Security Officer", "OF-3", hq, commander)
    ]

    units =
      Enum.flat_map(orgs.battalions, fn {battalion, companies} ->
        bn_commander = position("Battalion Commander", "OF-4", battalion, commander)
        bn_medic = position("Battalion Medical Officer", "OF-3", battalion, bn_commander)

        [bn_commander, bn_medic] ++
          Enum.flat_map(companies, &company_billets(&1, bn_commander))
      end)

    medical = medical_billets(orgs.role2, orgs.role3, commander)
    fixed = staff ++ units ++ medical

    riflemen =
      case people - length(fixed) do
        extra when extra > 0 -> rifleman_billets(orgs.battalions, extra)
        _ -> []
      end

    fixed ++ riflemen
  end

  # A post for `strength` people, as that many slots.
  defp slots(post), do: List.duplicate(post, post.strength)

  defp company_billets(company, bn_commander) do
    commander = position("Company Commander", "OF-2", company, bn_commander)

    [
      commander,
      position("Platoon Leader", "OF-1", company, commander),
      position("Squad Leader", "OR-6", company, commander),
      position("Combat Medic", "OR-4", company, commander)
    ]
  end

  defp medical_billets(role2, role3, brigade_commander) do
    r2 = position("Medical Company Commander", "OF-3", role2, brigade_commander)
    r3 = position("Field Hospital Commander", "OF-4", role3, brigade_commander)

    [r2, r3] ++
      slots(position("Surgeon", "OF-3", role2, r2, 2)) ++
      slots(position("Nurse", "OR-6", role2, r2, 3)) ++
      slots(position("Physician", "OF-3", role3, r3, 3)) ++
      slots(position("Nurse", "OR-6", role3, r3, 3))
  end

  defp rifleman_billets(battalions, count) do
    companies = Enum.flat_map(battalions, fn {_battalion, companies} -> companies end)

    # One Rifleman post per company, its strength the riflemen there.
    per_company =
      companies
      |> Stream.cycle()
      |> Enum.take(count)
      |> Enum.frequencies_by(& &1.id)

    for company <- companies,
        n = per_company[company.id],
        post <- slots(position("Rifleman", "OR-3", company, nil, n)),
        do: post
  end

  defp position(title, grade, organization, reports_to, strength \\ 1) do
    Position
    |> Ash.Changeset.for_create(
      :create,
      %{
        title: title,
        authorised_grade: grade,
        organization_id: organization.id,
        reports_to_id: reports_to && reports_to.id,
        strength: strength
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp count_organizations(%{battalions: battalions}) do
    companies =
      Enum.sum(Enum.map(battalions, fn {_battalion, companies} -> length(companies) end))

    # brigade, Role 2, Role 3, battalions, companies
    3 + length(battalions) + companies
  end

  # --- people -------------------------------------------------------------

  defp build_person(index) do
    origin = weighted([{:uk, 6}, {:en, 2}, {:fr, 2}])
    sex = Enum.random([:male, :female])
    name = Names.pick(origin, sex)
    email_local = "#{name.given_name}.#{name.family_name}.#{index}" |> String.downcase()

    Person
    |> Ash.Changeset.for_create(
      :create,
      %{
        given_name: name.given_name,
        family_name: name.family_name,
        patronymic: name.patronymic,
        email: "#{email_local}@#{@email_domain}",
        date_of_birth: Date.add(today(), -Enum.random((19 * 365)..(55 * 365))),
        birth_country: name.country
      },
      authorize?: false
    )
    |> Ash.Changeset.force_change_attribute(:synthetic, true)
    |> Ash.create!(authorize?: false)
  end

  defp assign(persons, positions) do
    persons
    |> Enum.zip(Stream.concat(positions, Stream.repeatedly(fn -> nil end)))
    |> Enum.map(fn
      {_person, nil} ->
        nil

      {person, position} ->
        starts_on = Date.add(today(), -Enum.random(30..(5 * 365)))
        maybe_prior_assignment(person, positions, starts_on)
        create_assignment(person, position, starts_on, nil)
        position
    end)
  end

  defp maybe_prior_assignment(person, positions, current_start) do
    if chance(0.25) do
      prior = Enum.random(positions)
      starts_on = Date.add(current_start, -Enum.random(365..(3 * 365)))
      create_assignment(person, prior, starts_on, Date.add(current_start, -1))
    end
  end

  defp create_assignment(person, position, starts_on, ends_on) do
    Assignment
    |> Ash.Changeset.for_create(
      :create,
      %{person_id: person.id, position_id: position.id, starts_on: starts_on, ends_on: ends_on},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # Identifiers, documents and records for one person. Returns how many
  # records were created.
  defp build_person_data({person, position}, key) do
    records =
      [
        rank_history(position),
        {:contact_info, %{"contactType" => "email", "value" => person.email, "use" => "work"}},
        language(),
        fitness(),
        family(),
        compensation(position)
      ] ++
        clearance_and_vetting(position) ++
        medical() ++ allergies() ++ dependents()

    created =
      records
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {kind, data} -> create_person_record(person, kind, data, key) end)

    unbacked = Enum.flat_map(created, &elem(&1, 0))
    conclusions = created |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    care_episode(person)
    current_leave(person)
    lab_results(person, key)
    identity = identity(person, key)

    unbacked ++
      identity ++
      conclusion_identity(person, identity, conclusions) ++
      leave_history(person, key) ++ fitness_leak(person, key) ++ duplicate_assignment(person, key)
  end

  # The reference dataset (docs/design/data-consistency.md): identity is
  # entered in the system (its `inserted_at`) before anything recorded
  # about the person, except for a small planted share of people with
  # examinations: their identity is entered only now, after the
  # examinations, or not at all. Which people depends only on the seed and
  # their place in the list (not on `:rand`), and each planted violation
  # is returned with the rule and code it must raise.
  @examinations [:encounter, :vital_signs, :medical_condition]
  @planted_per_mille 120

  # Other planted violations, per mille of people (docs/design/data-consistency.md).
  @planted_leave 40
  @planted_fitness 20
  # Of people with a downgraded or non-effective status: no signed board
  # conclusion behind it (rule fitness_from_signed_conclusion).
  @planted_fitness_basis 150
  @planted_assignment 15

  defp planted?({seed, index}, what, per_mille),
    do: :erlang.phash2({seed, index, what}, 1000) < per_mille

  defp label(person, subject, rule, code),
    do: %{person: person.email, subject: subject, rule: rule, code: code}

  defp identity(person, {seed, index}) do
    examinations = examinations(person)
    planted? = examinations != [] and :erlang.phash2({seed, index}, 1000) < @planted_per_mille
    missing? = planted? and rem(index, 2) == 0

    cond do
      missing? -> nil
      planted? -> build_identity(person, nil)
      true -> build_identity(person, DateTime.new!(Date.add(today(), -3100), ~T[09:00:00]))
    end

    code = if missing?, do: "identity_missing", else: "identity_after_examination"

    for kind <- examinations, planted? do
      %{
        person: person.email,
        subject: "record:#{kind}",
        rule: "identity_before_examination",
        code: code
      }
    end
  end

  # Leave taken last year (docs/design/leave.md): one or two annual
  # leaves within the entitlement, apart. Planted: two leaves that overlap,
  # or two that together exceed the entitlement (each then exceeds what
  # the other leaves).
  defp leave_history(person, key) do
    year = today().year - 1
    first = Date.new!(year, Enum.random(1..9), Enum.random(1..28))

    {periods, labels} =
      cond do
        not planted?(key, :leave, @planted_leave) ->
          second =
            if chance(0.5), do: [{Date.add(first, Enum.random(40..90)), Enum.random(5..10)}]

          {[{first, Enum.random(10..15)} | second || []], []}

        rem(elem(key, 1), 2) == 0 ->
          {[{first, 10}, {Date.add(first, 5), 5}],
           List.duplicate(label(person, "record:leave", "leave_no_overlap", "leave_overlap"), 2)}

        true ->
          {[{first, 20}, {Date.add(first, 60), 15}],
           List.duplicate(
             label(person, "record:leave", "leave_within_balance", "leave_over_balance"),
             2
           )}
      end

    for {start, days} <- periods do
      create_record(person, :leave, %{
        "leaveType" => "annual",
        "startDate" => Date.to_iso8601(start),
        "endDate" => Date.to_iso8601(Date.add(start, days - 1)),
        "days" => days,
        "basis" => "TEST-#{Enum.random(1..400)}-ос"
      })
    end

    labels
  end

  # Leave around now, for the leave calendar (docs/design/leave-calendar.md):
  # about a quarter of people take annual leave of 5–14 days starting
  # within three weeks before to six weeks after today, a few are on sick
  # leave or a business trip. One period each, inside this year's
  # entitlement, so no rule is broken.
  defp current_leave(person) do
    cond do
      chance(0.25) ->
        demo_leave(person, "annual", Enum.random(-20..40), Enum.random(5..14))

      chance(0.08) ->
        demo_leave(person, "sick", Enum.random(-10..20), Enum.random(3..10))

      chance(0.07) ->
        demo_trip(person, Enum.random(-10..30), Enum.random(2..7))

      true ->
        :ok
    end
  end

  # A business trip (docs/design/business-trips.md), as a signed order records it.
  defp demo_trip(person, offset, days) do
    start = Date.add(today(), offset)

    create_record(person, :business_trip, %{
      "destination" =>
        Enum.random(["Lviv, training centre", "Kyiv, headquarters", "Rivne, depot"]),
      "purpose" => Enum.random(["Instructor course", "Staff meeting", "Equipment acceptance"]),
      "startDate" => Date.to_iso8601(start),
      "endDate" => Date.to_iso8601(Date.add(start, days - 1)),
      "days" => days,
      "transport" => Enum.random(["official_vehicle", "public_transport"]),
      "basis" => "TEST-#{Enum.random(1..400)}-ос"
    })
  end

  defp demo_leave(person, type, offset, days) do
    start = Date.add(today(), offset)

    create_record(person, :leave, %{
      "leaveType" => type,
      "startDate" => Date.to_iso8601(start),
      "endDate" => Date.to_iso8601(Date.add(start, days - 1)),
      "days" => days,
      "basis" => "TEST-#{Enum.random(1..400)}-ос"
    })
  end

  # A downgraded or non-effective status comes from a signed medical board
  # conclusion (its number in "basis"), except for a planted few
  # (docs/design/data-consistency.md, rule fitness_from_signed_conclusion).
  defp create_person_record(person, :fitness_for_duty, %{"status" => status} = data, key)
       when status != "fit_for_duty" do
    if planted?(key, :fitness_basis, @planted_fitness_basis) do
      create_record(person, :fitness_for_duty, data)
      {[unbacked_fitness(person)], 0}
    else
      create_record(person, :fitness_for_duty, Map.put(data, "basis", demo_conclusion(person)))
      {[], 1}
    end
  end

  defp create_person_record(person, kind, data, _key) do
    create_record(person, kind, data)
    {[], 0}
  end

  defp unbacked_fitness(person),
    do:
      label(
        person,
        "record:fitness_for_duty",
        "fitness_from_signed_conclusion",
        "fitness_without_conclusion"
      )

  # A board conclusion is an examination too: for a person whose identity
  # is planted as missing or late, each conclusion breaks that rule as well.
  defp conclusion_identity(_person, [], _conclusions), do: []

  defp conclusion_identity(person, [%{code: code} | _], conclusions) do
    List.duplicate(
      label(person, "document:medical_board_conclusion", "identity_before_examination", code),
      conclusions
    )
  end

  # A signed board conclusion in a test register (like the demo orders: no
  # PDF, no effects); its number.
  defp demo_conclusion(person) do
    document =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :medical_board_conclusion,
          person_id: person.id,
          data: %{"conclusion" => "fit_with_restrictions"}
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    year = today().year
    register = "TEST-влк"
    seq = Counter.next(register, year)
    number = "TEST-#{seq}-влк"
    signed_on = Date.add(today(), -30)

    Ash.Seed.update!(document, %{
      state: :signed,
      register: register,
      register_year: year,
      register_seq: seq,
      number: number,
      registered_on: signed_on,
      signed_at: DateTime.new!(signed_on, ~T[10:00:00])
    })

    number
  end

  # Lab results (docs/design/lab-results.md) for about a quarter of people:
  # two haemoglobin results a month apart (so "previous" shows) and, for
  # some, a potassium result now and then high. Values from the key, no
  # random calls, so the rest of the data stays as the seed made it.
  defp lab_results(person, {_seed, _index} = key) do
    if planted?(key, :labs, 250) do
      spread = :erlang.phash2({key, :labs_values}, 30)
      earlier = Date.add(today(), -40) |> Date.to_iso8601()
      later = Date.add(today(), -10) |> Date.to_iso8601()

      create_record(person, :lab_result, %{
        "test" => "hemoglobin",
        "value" => 125 + spread,
        "collectedAt" => earlier <> "T08:30"
      })

      create_record(person, :lab_result, %{
        "test" => "hemoglobin",
        "value" => 118 + spread,
        "collectedAt" => later <> "T08:15"
      })

      if rem(spread, 3) == 0 do
        create_record(person, :lab_result, %{
          "test" => "potassium",
          "value" => 4.1 + spread / 20,
          "collectedAt" => later <> "T08:15"
        })
      end
    end
  end

  # Planted: a fitness restriction that names a diagnosis code, with no
  # board conclusion behind it either (two rules).
  defp fitness_leak(person, key) do
    if planted?(key, :fitness, @planted_fitness) do
      create_record(person, :fitness_for_duty, %{
        "status" => "downgraded",
        "restrictions" => "No field duty (S83.2)",
        "reviewDate" => future_date(90),
        "assessedBy" => "Battalion Medical Officer"
      })

      [
        label(
          person,
          "record:fitness_for_duty",
          "no_diagnosis_in_restrictions",
          "diagnosis_in_restrictions"
        ),
        unbacked_fitness(person)
      ]
    else
      []
    end
  end

  # Planted: the current assignment entered twice (a later start, still
  # open), so the two overlap.
  defp duplicate_assignment(person, key) do
    current =
      Assignment
      |> Ash.Query.filter(person_id == ^person.id and is_nil(ends_on))
      |> Ash.read!(authorize?: false)

    case current do
      [%{starts_on: starts_on} = assignment] ->
        if planted?(key, :assignment, @planted_assignment) do
          create_assignment(person, %{id: assignment.position_id}, Date.add(starts_on, 7), nil)

          List.duplicate(
            label(person, "assignment", "assignments_no_overlap", "assignment_overlap"),
            2
          )
        else
          []
        end

      _ ->
        []
    end
  end

  defp examinations(person) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person.id and kind in @examinations)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.kind)
  end

  # `entered_at` nil = entered now.
  defp build_identity(person, entered_at) do
    create!(
      PersonIdentifier,
      %{
        person_id: person.id,
        id_type: :rnokpp,
        country: person.birth_country,
        value: "TEST-" <> digits(10),
        is_current: true
      },
      entered_at
    )

    issued_on = Date.add(today(), -Enum.random(100..3000))

    create!(
      IdentityDocument,
      %{
        person_id: person.id,
        document_type: :military_id,
        series: "TS",
        number: "TEST-" <> digits(6),
        issuing_authority: "Demo Ministry of Defence",
        issuing_country: person.birth_country,
        issued_on: issued_on,
        expires_on: Date.add(issued_on, 10 * 365)
      },
      entered_at
    )
  end

  defp rank_history(nil), do: nil

  defp rank_history(position) do
    {:rank_history, %{"grade" => position.authorised_grade, "effectiveDate" => past_date(2000)}}
  end

  defp language do
    level = fn -> Enum.random(1..4) end

    {:language_proficiency,
     %{
       "language" => Enum.random(~w(en fr de pl)),
       "listening" => level.(),
       "speaking" => level.(),
       "reading" => level.(),
       "writing" => level.()
     }}
  end

  defp fitness do
    case weighted([{:fit_for_duty, 85}, {:downgraded, 11}, {:non_effective, 4}]) do
      :fit_for_duty ->
        {:fitness_for_duty, %{"status" => "fit_for_duty", "reviewDate" => future_date(365)}}

      status ->
        {:fitness_for_duty,
         %{
           "status" => Atom.to_string(status),
           "restrictions" => Enum.random(["No heavy lifting", "No field duty", "Desk duty only"]),
           "reviewDate" => future_date(90),
           "assessedBy" => "Battalion Medical Officer"
         }}
    end
  end

  defp family do
    status = weighted([{"married", 5}, {"single", 4}, {"divorced", 1}])
    {:family_status, %{"maritalStatus" => status, "dependentsCount" => Enum.random(0..3)}}
  end

  defp compensation(nil), do: nil

  defp compensation(position) do
    base = if String.starts_with?(position.authorised_grade, "OF"), do: 3200, else: 1900

    {:compensation,
     %{
       "amount" => base + Enum.random(0..800),
       "currency" => "EUR",
       "effectiveDate" => past_date(365),
       "reason" => "base_pay"
     }}
  end

  # Officers and specialist posts get clearances; a few are expired or
  # pending so the edge cases exist. Each granted clearance gets the
  # vetting record behind it.
  defp clearance_and_vetting(nil), do: []

  defp clearance_and_vetting(position) do
    officer? = String.starts_with?(position.authorised_grade, "OF")

    if officer? or chance(0.3) do
      level = if officer?, do: "NATO_SECRET", else: "NATO_CONFIDENTIAL"
      status = weighted([{"granted", 8}, {"expired", 1}, {"pending", 1}])
      granted = past_date(2500)

      clearance =
        if status == "pending",
          do: %{"clearanceLevel" => level, "status" => status},
          else: %{
            "clearanceLevel" => level,
            "status" => status,
            "grantedDate" => granted,
            "expiryDate" => expiry_for(status)
          }

      vetting = %{
        "investigationType" => if(status == "pending", do: "initial", else: "periodic_review"),
        "investigatingAuthority" => "Demo Defence Vetting Agency",
        "openedOn" => past_date(3000),
        "outcome" => if(status == "pending", do: "in_progress", else: "favourable")
      }

      [{:security_clearance, clearance}, {:vetting_record, vetting}]
    else
      []
    end
  end

  defp expiry_for("expired"), do: past_date(200)
  defp expiry_for(_status), do: future_date(1800)

  @conditions [
    {"Hypertension", "Cardiovascular"},
    {"Asthma", "Respiratory"},
    {"Lumbar strain", "Lower back"},
    {"Tinnitus", "Ear"},
    {"Knee ligament injury", "Knee"},
    {"Type 2 diabetes", nil},
    {"Atrial fibrillation", "Heart"}
  ]

  # Long-term medicines for the conditions above (docs/design/
  # clinical-medications.md): {drug, dose, unit, route, frequency}.
  @condition_medicines %{
    "Hypertension" => [
      [{"Amlodipine", 5, "mg", "po", "once_daily"}],
      [
        {"Ramipril", 5, "mg", "po", "once_daily"},
        {"Hydrochlorothiazide", 12.5, "mg", "po", "once_daily"}
      ]
    ],
    "Asthma" => [
      [
        {"Salbutamol", 2, "puff", "inh", "as_needed"},
        {"Fluticasone", 250, "mcg", "inh", "twice_daily"}
      ]
    ],
    "Type 2 diabetes" => [
      [
        {"Metformin", 1000, "mg", "po", "twice_daily"},
        {"Atorvastatin", 20, "mg", "po", "once_daily"}
      ]
    ],
    "Atrial fibrillation" => [
      [{"Apixaban", 5, "mg", "po", "twice_daily"}, {"Bisoprolol", 5, "mg", "po", "once_daily"}]
    ]
  }

  defp medical do
    if chance(0.3) do
      {text, site} = Enum.random(@conditions)
      status = Enum.random(["active", "remission", "resolved"])
      onset = past_date(2000)

      [
        {:medical_condition,
         Map.reject(
           %{
             "code" => %{"text" => text},
             "clinicalStatus" => status,
             "verificationStatus" => "confirmed",
             "bodySite" => site,
             "onsetDate" => onset
           },
           fn {_key, value} -> is_nil(value) end
         )}
      ] ++ if(status == "active", do: medicines(text, onset), else: [])
    else
      []
    end
  end

  defp medicines(condition, since) do
    case @condition_medicines[condition] do
      nil ->
        []

      regimens ->
        for {drug, value, unit, route, frequency} <- Enum.random(regimens) do
          {:medication_statement,
           %{
             "medication" => %{"text" => drug},
             "adherence" => weighted([{"taking", 8}, {"on-hold", 1}]),
             "dose" => %{"value" => value, "unit" => unit},
             "route" => route,
             "frequency" => frequency,
             "effectiveStart" => since,
             "reason" => condition,
             "informationSource" => weighted([{"prescription", 2}, {"patient", 1}])
           }}
        end
    end
  end

  @allergens [
    {"Penicillin", "medication"},
    {"Peanut", "food"},
    {"Bee venom", "environment"},
    {"Latex", "environment"}
  ]

  defp allergies do
    if chance(0.15) do
      {text, category} = Enum.random(@allergens)
      criticality = weighted([{"low", 2}, {"high", 1}])

      [
        {:allergy_intolerance,
         %{
           "code" => %{"text" => text},
           "clinicalStatus" => "active",
           "verificationStatus" => "confirmed",
           "type" => "allergy",
           "category" => [category],
           "criticality" => criticality,
           "reactionManifestation" => if(criticality == "high", do: "Anaphylaxis", else: "Rash"),
           "reactionSeverity" => if(criticality == "high", do: "severe", else: "mild")
         }}
      ]
    else
      []
    end
  end

  # Point of care (docs/design/clinical-module.md): some people have an
  # encounter with a few vital-sign sets taken during it, getting better or
  # worse, so flags and NEWS2 have something to show. Returns the count.
  defp care_episode(person) do
    if chance(0.12) do
      start =
        NaiveDateTime.new!(
          Date.add(today(), -Enum.random(1..30)),
          Time.new!(Enum.random(6..20), 0, 0)
        )

      data = encounter_data(start)
      encounter = create_record(person, :encounter, data)
      1 + vital_series(person, encounter, start) + treatment(person, encounter, start, data)
    else
      0
    end
  end

  # 2–4 hourly sets during the encounter, getting better or worse.
  defp vital_series(person, encounter, start) do
    sets = Enum.random(2..4)
    worsening? = chance(0.4)

    for i <- 0..(sets - 1) do
      # 0.0 = stable, 1.0 = most deranged, moving over the sets.
      severity = if worsening?, do: i / sets, else: (sets - 1 - i) / sets * 0.6

      create!(PersonRecord, %{
        person_id: person.id,
        kind: :vital_signs,
        data: vitals_data(NaiveDateTime.add(start, i * 3600), severity),
        part_of_id: encounter.id
      })
    end

    sets
  end

  # Care given during the encounter (docs/design/clinical-medications.md):
  # typical TCCC interventions and drugs for an injury, symptom relief for
  # an illness. Returns the count.
  defp treatment(person, encounter, start, %{"mechanismOfInjury" => mechanism}) do
    at = fn minutes -> local(NaiveDateTime.add(start, minutes * 60)) end

    items =
      if mechanism == "illness",
        do: [
          {:medication_administration, medication("Paracetamol", 1000, "mg", "po", at.(10))},
          {:medication_administration, medication("Ondansetron", 4, "mg", "iv", at.(15))}
        ],
        else: injury_treatment(mechanism, at)

    for {kind, data} <- items do
      create!(PersonRecord, %{
        person_id: person.id,
        kind: kind,
        data: data,
        part_of_id: encounter.id
      })
    end

    length(items)
  end

  defp injury_treatment(mechanism, at) do
    bleeding? = mechanism in ~w(blast gunshot fragment) and chance(0.6)

    tourniquet =
      if bleeding?,
        do: [
          {:procedure,
           %{
             "performed" => at.(2),
             "endedAt" => at.(95),
             "status" => "completed",
             "code" => "tourniquet_limb",
             "bodySite" => Enum.random(["Thigh", "Upper arm", "Lower leg"]),
             "side" => Enum.random(["left", "right"]),
             "outcome" => "successful",
             "detail" => "Converted to a pressure dressing"
           }},
          {:medication_administration, medication("Tranexamic acid", 2, "g", "iv", at.(20))}
        ],
        else: []

    pain =
      if chance(0.5),
        do: medication("Ketamine", 50, "mg", "im", at.(12)),
        else: medication("Fentanyl", 800, "mcg", "buccal", at.(12))

    tourniquet ++
      [
        {:procedure,
         %{
           "performed" => at.(8),
           "status" => "completed",
           "code" => "iv_access",
           "outcome" => "successful"
         }},
        {:medication_administration, pain},
        {:medication_administration, medication("Moxifloxacin", 400, "mg", "po", at.(25))}
      ]
  end

  defp medication(name, value, unit, route, occurrence) do
    %{
      "occurrence" => occurrence,
      "status" => "completed",
      "medication" => %{"text" => name},
      "dose" => %{"value" => value, "unit" => unit},
      "route" => route
    }
  end

  defp encounter_data(start) do
    triage = weighted([{"T3", 5}, {"T2", 3}, {"T1", 1}])

    %{
      "status" => "completed",
      "class" => weighted([{"FLD", 3}, {"EMER", 2}, {"AMB", 2}]),
      "start" => local(start),
      "end" => local(NaiveDateTime.add(start, 4 * 3600)),
      "triage" => triage,
      "evacuationPriority" => evacuation(triage),
      "mechanismOfInjury" => Enum.random(~w(blast gunshot fragment fall vehicle illness)),
      "reason" => "Demo encounter",
      "disposition" => weighted([{"returned_to_duty", 3}, {"evacuated", 2}, {"admitted", 1}])
    }
  end

  defp vitals_data(measured_at, severity) do
    %{
      "measuredAt" => local(measured_at),
      "systolic" => round(125 - 35 * severity),
      "diastolic" => round(80 - 20 * severity),
      "heartRate" => round(75 + 45 * severity),
      "respiratoryRate" => round(15 + 10 * severity),
      "spo2" => round(98 - 6 * severity),
      "onOxygen" => severity > 0.6,
      "temperature" => Float.round(36.7 + 1.5 * severity, 1),
      "consciousness" => if(severity > 0.8, do: "voice", else: "alert"),
      "pain" => min(10, round(2 + 7 * severity))
    }
  end

  defp evacuation("T1"), do: "urgent"
  defp evacuation("T2"), do: "priority"
  defp evacuation(_triage), do: "routine"

  # Local date and time as stored: 2026-09-27T14:05
  defp local(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  defp dependents do
    for _ <- 1..Enum.random(0..2)//1 do
      {:dependent,
       %{
         "name" => Enum.random(~w(Anna Ivan Marie Lucas Sofiia Emily)),
         "relationship" => "child",
         "dateOfBirth" => past_date(15 * 365)
       }}
    end
  end

  defp create_record(person, kind, data) do
    create!(PersonRecord, %{person_id: person.id, kind: kind, data: data})
  end

  defp create!(resource, params, entered_at \\ nil) do
    resource
    |> Ash.Changeset.for_create(:create, params, authorize?: false)
    |> then(
      &if entered_at,
        do: Ash.Changeset.force_change_attribute(&1, :inserted_at, entered_at),
        else: &1
    )
    |> Ash.create!(authorize?: false)
  end

  # --- demo users -------------------------------------------------------

  # Which demo person each demo account belongs to: the first person
  # holding a post with this title (positions are filled in order, so e.g.
  # the line commander and clinician both belong to the 1st Battalion).
  @demo_posts %{
    admin: ["Brigade Commander"],
    hr: ["S1 Personnel Officer"],
    viewer: ["Rifleman", "Squad Leader"],
    person: ["Rifleman"],
    registrar: ["Patient Administration Officer"],
    line_commander: ["Battalion Commander"],
    commander: ["Battalion Commander"],
    clinician: ["Battalion Medical Officer"],
    command_surgeon: ["Command Surgeon"],
    head_of_department: ["Field Hospital Commander"],
    nurse: ["Nurse"],
    combat_medic: ["Combat Medic"],
    security_officer: ["Security Officer"],
    ciso: ["Information Security Officer"]
  }

  defp build_users(people_with_posts) do
    base = for role <- App.Access.roles(), do: {role, role, []}
    profiles = for profile <- App.Access.profiles(), do: {profile, :viewer, [profile]}

    # An account is linked to one person and a person to one account: two
    # accounts for the same post title get different people.
    {users, _used} =
      Enum.map_reduce(base ++ profiles, MapSet.new(), fn {key, role, profile_list}, used ->
        person = demo_person(people_with_posts, Map.get(@demo_posts, key, []), used)
        if person, do: give_valid_clearance(person, key)

        user =
          Ash.Seed.seed!(User, %{
            email: "#{key}@#{@email_domain}",
            name: "Demo #{key}",
            role: role,
            profiles: profile_list,
            person_id: person && person.id
          })

        {user, if(person, do: MapSet.put(used, person.id), else: used)}
      end)

    users
  end

  defp demo_person(people_with_posts, titles, used) do
    Enum.find_value(titles, &first_free(people_with_posts, &1, used))
  end

  defp first_free(people_with_posts, title, used) do
    Enum.find_value(people_with_posts, fn
      {person, %{title: ^title}} -> if(person.id in used, do: nil, else: person)
      _ -> nil
    end)
  end

  # A current, granted clearance as the person's latest record, so demo
  # accounts behave predictably under the clearance check.
  defp give_valid_clearance(person, key) do
    level = if key == :viewer, do: "NATO_RESTRICTED", else: "NATO_SECRET"

    create_record(person, :security_clearance, %{
      "clearanceLevel" => level,
      "status" => "granted",
      "grantedDate" => past_date(365),
      "expiryDate" => Date.to_iso8601(Date.add(today(), 5 * 365))
    })
  end

  # --- orders to acknowledge ---------------------------------------------

  # Signed grade orders awaiting acknowledgement (docs/design/acknowledgements.md),
  # so every demo account with a person has one in Tasks and the
  # Acknowledgements page has a batch to record; every third of the others
  # is already acknowledged. Marked signed directly — no PDF, no effects —
  # and numbered in their own register (TEST-n-ос), so the real register of
  # orders is untouched. Removed with their people.
  @demo_orders 20
  @demo_register "TEST-ос"

  defp build_orders(persons, users) do
    linked = users |> Enum.map(& &1.person_id) |> Enum.reject(&is_nil/1)

    others =
      persons |> Enum.map(& &1.id) |> Enum.reject(&(&1 in linked)) |> Enum.take(@demo_orders)

    (linked ++ others)
    |> Enum.with_index(1)
    |> Enum.map(fn {person_id, index} ->
      order = signed_demo_order(person_id, index)
      if person_id not in linked and rem(index, 3) == 0, do: acknowledge_demo_order(order)
      order
    end)
    |> length()
  end

  defp signed_demo_order(person_id, index) do
    document =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :personnel_order_grade,
          person_id: person_id,
          data: %{"grade" => "OR-#{3 + rem(index, 3)}", "effectiveDate" => past_date(60)}
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    year = today().year
    seq = Counter.next(@demo_register, year)
    signed_at = DateTime.add(DateTime.utc_now(), -Enum.random(1..30) * 86_400, :second)

    Ash.Seed.update!(document, %{
      state: :signed,
      register: @demo_register,
      register_year: year,
      register_seq: seq,
      number: "TEST-#{seq}-ос",
      registered_on: DateTime.to_date(signed_at),
      signed_at: signed_at
    })
  end

  defp acknowledge_demo_order(order) do
    Acknowledgement
    |> Ash.Changeset.for_create(
      :record,
      %{document_id: order.id, method: :in_person, note: "Demo"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # --- orders in approval ---------------------------------------------------

  # Grade orders on their way (docs/design/inbox-first.md), so the HR and
  # commander demo accounts start from something to approve or sign: for
  # each, one step waiting since today and one overdue (pending longer
  # than `documents.step_days`). People in the commander's unit, so the
  # commander may sign. No random calls: the rest of the data stays as the
  # seed made it.
  @pending_orders [
    {:approve, 0},
    {:approve, 6},
    {:sign, 0},
    {:sign, 5}
  ]

  defp build_pending_orders(persons, users) do
    by_email = Map.new(users, &{to_string(&1.email), &1})
    hr = by_email["hr@#{@email_domain}"]
    commander = by_email["commander@#{@email_domain}"]

    if hr && commander && commander.person_id do
      persons
      |> Enum.filter(fn person ->
        person.id != commander.person_id and
          App.Documents.Access.holds?(commander, "orders.sign", %{person_id: person.id})
      end)
      |> Enum.reverse()
      |> Enum.zip(@pending_orders)
      |> Enum.map(fn {person, {step, days_ago}} ->
        pending_order(person.id, step, days_ago, hr, commander)
      end)
      |> length()
    else
      0
    end
  end

  defp pending_order(person_id, step, days_ago, hr, commander) do
    document =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :personnel_order_grade,
          person_id: person_id,
          data: %{"grade" => "OR-5", "effectiveDate" => Date.to_iso8601(Date.add(today(), 14))}
        },
        actor: hr
      )
      |> Ash.create!(actor: hr)
      |> Ash.Changeset.for_update(:submit, %{assignees: [[hr.id], [commander.id]]}, actor: hr)
      |> Ash.update!(actor: hr)

    if step == :sign,
      do: document |> Ash.Changeset.for_update(:approve, %{}, actor: hr) |> Ash.update!(actor: hr)

    since = DateTime.add(DateTime.utc_now(), -days_ago, :day)

    Repo.query!(
      "UPDATE document_steps SET pending_since = $2 WHERE document_id = $1 AND status = 'pending'",
      [Ecto.UUID.dump!(document.id), since]
    )

    document
  end

  # --- helpers ------------------------------------------------------------

  defp today, do: Date.utc_today()
  defp past_date(max_days), do: Date.to_iso8601(Date.add(today(), -Enum.random(1..max_days)))
  defp future_date(max_days), do: Date.to_iso8601(Date.add(today(), Enum.random(30..max_days)))
  defp chance(probability), do: :rand.uniform() < probability
  defp digits(n), do: Enum.map_join(1..n, fn _ -> Enum.random(0..9) end)

  defp weighted(options) do
    total = options |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    pick = Enum.random(1..total)

    Enum.reduce_while(options, pick, fn {value, weight}, remaining ->
      if remaining <= weight, do: {:halt, value}, else: {:cont, remaining - weight}
    end)
  end
end
