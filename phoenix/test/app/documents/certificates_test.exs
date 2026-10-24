defmodule App.Documents.CertificatesTest do
  @moduledoc "docs/design/certificates.md: certificates requested, signed with frozen facts."
  use App.DataCase, async: false

  import App.Fixtures

  alias App.Documents.Certificates.Pay
  alias App.Documents.{Changes.Sign, Document, Print}

  setup do
    App.Access.put_admin_full_data_access_override(false)
    brigade = org_fixture("10th Brigade")
    battalion = org_fixture("1st Battalion", brigade)
    company = org_fixture("A Company", battalion)
    requester = unit_user_fixture(:viewer, [], company, nil)

    %{
      requester: requester,
      person_id: requester.person_id,
      bystander: unit_user_fixture(:viewer, [], company, nil),
      hr: user_fixture(:hr)
    }
  end

  defp request(ctx, actor, type, data, person_id \\ nil) do
    Document
    |> Ash.Changeset.for_create(
      :create,
      %{type: type, person_id: person_id || ctx.person_id, data: data},
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp run(document, action, actor, args \\ %{}) do
    document
    |> Ash.Changeset.for_update(action, args, actor: actor)
    |> Ash.update(actor: actor)
  end

  defp sign(ctx, document) do
    {:ok, document} = run(document, :submit, ctx.requester, %{assignees: [[ctx.hr.id]]})
    run(document, :sign, ctx.hr)
  end

  defp stored(document), do: Ash.load!(document, :data, authorize?: false)

  describe "pay by month" do
    test "a mid-month raise is prorated by days; one-off payments are added in their month" do
      records = [
        %{
          "amount" => 31_000,
          "currency" => "UAH",
          "effectiveDate" => "2025-01-01",
          "reason" => "base_pay"
        },
        %{
          "amount" => 62_000,
          "currency" => "UAH",
          "effectiveDate" => "2026-01-21",
          "reason" => "promotion"
        },
        %{
          "amount" => 1500.5,
          "currency" => "UAH",
          "effectiveDate" => "2026-02-10",
          "reason" => "bonus"
        },
        # Outside the period: not counted.
        %{
          "amount" => 999,
          "currency" => "UAH",
          "effectiveDate" => "2026-04-01",
          "reason" => "bonus"
        }
      ]

      facts = Pay.compute(records, ~D[2026-01-01], ~D[2026-02-28])

      # January: 20 days at 31 000 / 31 + 11 days at 62 000 / 31.
      assert [jan, feb] = facts["months"]

      assert jan == %{
               "month" => "2026-01",
               "atRate" => %{"UAH" => "42000.00"},
               "oneOff" => %{},
               "total" => %{"UAH" => "42000.00"}
             }

      assert feb["atRate"] == %{"UAH" => "62000.00"}
      assert feb["oneOff"] == %{"UAH" => "1500.50"}
      assert feb["total"] == %{"UAH" => "63500.50"}
      assert facts["totals"] == %{"UAH" => "105500.50"}

      # The rate in force at the start, then the change inside the period.
      assert Enum.map(facts["rates"], & &1["date"]) == ["2025-01-01", "2026-01-21"]
      assert [%{"amount" => "1500.50", "reason" => "bonus"}] = facts["payments"]
    end

    test "a period starting mid-month counts only its days; no rate yet means nothing at the rate" do
      records = [
        %{
          "amount" => 30_000,
          "currency" => "EUR",
          "effectiveDate" => "2026-06-16",
          "reason" => "base_pay"
        }
      ]

      facts = Pay.compute(records, ~D[2026-06-01], ~D[2026-06-30])
      assert [%{"atRate" => %{"EUR" => "15000.00"}}] = facts["months"]

      facts = Pay.compute(records, ~D[2026-05-01], ~D[2026-05-31])
      assert [%{"atRate" => at_rate, "total" => total}] = facts["months"]
      assert at_rate == %{} and total == %{}
      assert facts["rates"] == []
    end
  end

  test "the person requests a service certificate; HR signs; the facts are frozen and hashed",
       ctx do
    record_fixture(%{id: ctx.person_id}, :rank_history, %{
      "grade" => "OR-4",
      "gradeTitle" => "Corporal",
      "effectiveDate" => "2025-05-01"
    })

    assert {:ok, certificate} =
             request(ctx, ctx.requester, :certificate_service, %{"presentTo" => "Bank"})

    # Only their own: not for someone else, and others in the unit don't see it.
    assert {:error, %Ash.Error.Forbidden{}} =
             request(ctx, ctx.requester, :certificate_service, %{}, ctx.bystander.person_id)

    assert [] = Ash.read!(Document, actor: ctx.bystander)

    assert {:ok, signed} = sign(ctx, certificate)
    assert signed.number == "1-дов"

    facts = stored(signed).data["facts"]

    assert [%{"title" => "Post", "unit" => "A Company, 1st Battalion, 10th Brigade"}] =
             facts["posts"]

    assert facts["rank"] == %{"grade" => "OR-4", "title" => "Corporal", "since" => "2025-05-01"}
    assert facts["serviceStart"] == Date.to_iso8601(Date.add(Date.utc_today(), -30))

    # The hash covers what the certificate states.
    assert signed.content_sha256 ==
             Sign.content_hash(stored(signed), signed.number, signed.registered_on)

    assert signed.pdf_key

    # Later records don't change a signed certificate.
    record_fixture(%{id: ctx.person_id}, :rank_history, %{
      "grade" => "OR-5",
      "effectiveDate" => Date.to_iso8601(Date.utc_today())
    })

    assert stored(signed).data["facts"]["rank"]["grade"] == "OR-4"

    [service, posts] =
      Print.sections(:certificate_service, stored(signed).data, App.Documents.Labels)

    assert ["Rank", "Corporal, OR-4"] in service["rows"]
    assert [["Post", "A Company, 1st Battalion, 10th Brigade", "—", _since]] = posts["rows"]
  end

  test "a pay certificate needs a valid period of at most 24 months", ctx do
    {:ok, reversed} =
      request(ctx, ctx.requester, :certificate_pay, %{
        "periodFrom" => "2026-03-01",
        "periodTo" => "2026-01-31"
      })

    assert {:error, error} = run(reversed, :submit, ctx.requester, %{assignees: [[ctx.hr.id]]})
    assert Exception.message(error) =~ "The end of the period is before its start."

    {:ok, long} =
      request(ctx, ctx.hr, :certificate_pay, %{
        "periodFrom" => "2023-01-01",
        "periodTo" => "2026-01-31"
      })

    assert {:error, error} = run(long, :submit, ctx.hr, %{assignees: [[ctx.hr.id]]})
    assert Exception.message(error) =~ "longer than 24 months"
  end

  test "pay, family and leave certificates state what the records hold", ctx do
    person = %{id: ctx.person_id}

    record_fixture(person, :compensation, %{
      "amount" => 30_000,
      "currency" => "UAH",
      "effectiveDate" => "2025-01-01",
      "reason" => "base_pay"
    })

    record_fixture(person, :family_status, %{
      "maritalStatus" => "married",
      "spouseName" => "Olena"
    })

    record_fixture(person, :dependent, %{
      "name" => "Taras",
      "relationship" => "child",
      "dateOfBirth" => "2015-04-02"
    })

    record_fixture(person, :leave, %{
      "leaveType" => "annual",
      "startDate" => "2026-03-01",
      "endDate" => "2026-03-10",
      "days" => 10,
      "basis" => "7-ос"
    })

    {:ok, pay} =
      request(ctx, ctx.requester, :certificate_pay, %{
        "periodFrom" => "2026-01-01",
        "periodTo" => "2026-03-31"
      })

    {:ok, pay} = sign(ctx, pay)
    assert stored(pay).data["facts"]["totals"] == %{"UAH" => "90000.00"}

    {:ok, family} = request(ctx, ctx.requester, :certificate_family, %{})
    {:ok, family} = sign(ctx, family)

    assert %{
             "maritalStatus" => "married",
             "spouseName" => "Olena",
             "dependants" => [%{"name" => "Taras", "relationship" => "child"}]
           } = stored(family).data["facts"]

    {:ok, leave} = request(ctx, ctx.requester, :certificate_leave, %{"year" => "2026"})
    {:ok, leave} = sign(ctx, leave)
    facts = stored(leave).data["facts"]

    assert %{"type" => "annual", "entitled" => 30, "used" => 10, "left" => 20} in facts[
             "balances"
           ]

    assert [%{"first" => "2026-03-01", "days" => 10, "basis" => "7-ос"}] = facts["leaves"]

    # One register for all certificates.
    assert Enum.map([pay, family, leave], & &1.number) == ["1-дов", "2-дов", "3-дов"]
  end
end
