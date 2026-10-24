defmodule App.Documents.Certificates do
  @moduledoc """
  Certificates on request (docs/design/certificates.md): what a
  certificate states, read from the database for a person on a date —
  computed when it is signed and frozen in its fields under `"facts"`
  (`App.Documents.Changes.Sign`), and shown as a preview before that.

  Facts are plain JSON (dates ISO, amounts as strings) so the content hash
  is stable; `sections/4` turns them into the printed sections in a
  language. Records are read as the system (no actor): the reader of the
  certificate is what the access log records.
  """

  require Ash.Query

  alias App.Documents.Certificates.{Pay, TripSettlement}
  alias App.Documents.Types
  alias App.People.{Assignment, Organization, PersonRecord, PersonRecordSchema}

  # A pay certificate covers at most this many months.
  @max_months 24

  @doc "The facts of a certificate kind (`App.Documents.Types.facts/1`) for a person on `date`."
  @spec facts(String.t(), String.t(), map(), Date.t()) :: map()
  def facts("service", person_id, _data, date) do
    assignments =
      Assignment
      |> Ash.Query.filter(person_id == ^person_id)
      |> Ash.Query.load(position: :organization)
      |> Ash.read!(authorize?: false)

    units = units()

    posts =
      assignments
      |> Enum.filter(&current?(&1, date))
      |> Enum.sort_by(& &1.starts_on, Date)
      |> Enum.map(fn a ->
        %{
          "title" => a.position.title,
          "unit" => unit_path(units, a.position.organization_id),
          "grade" => a.position.authorised_grade,
          "since" => Date.to_iso8601(a.starts_on)
        }
      end)

    start =
      assignments
      |> Enum.map(& &1.starts_on)
      |> Enum.filter(&(Date.compare(&1, date) != :gt))
      |> Enum.min(Date, fn -> nil end)

    rank =
      person_id
      |> records(:rank_history)
      |> Enum.filter(&on_or_before?(&1["effectiveDate"], date))
      |> Enum.max_by(& &1["effectiveDate"], fn -> nil end)

    %{
      "posts" => posts,
      "serviceStart" => start && Date.to_iso8601(start),
      "rank" =>
        rank &&
          %{
            "grade" => rank["grade"],
            "title" => rank["gradeTitle"],
            "since" => rank["effectiveDate"]
          }
    }
  end

  def facts("pay", person_id, data, _date) do
    {:ok, from, to} = pay_period(data)
    Pay.compute(records(person_id, :compensation), from, to)
  end

  def facts("family", person_id, _data, _date) do
    status = person_id |> records(:family_status) |> List.last()

    dependants =
      person_id
      |> records(:dependent)
      |> Enum.sort_by(&(&1["dateOfBirth"] || ""))
      |> Enum.map(&Map.take(&1, ["name", "relationship", "dateOfBirth"]))

    %{
      "maritalStatus" => status && status["maritalStatus"],
      "spouseName" => status && status["spouseName"],
      "dependants" => dependants
    }
  end

  # A business-trip report (docs/design/business-trips.md §Report): from its own fields.
  def facts("trip_settlement", _person_id, data, _date), do: TripSettlement.compute(data)

  def facts("leave_balance", person_id, data, _date) do
    year = data["year"]

    leaves =
      person_id
      |> records(:leave)
      |> Enum.map(&leave/1)
      |> Enum.filter(&(&1["days"] && String.starts_with?(&1["first"], "#{year}-")))
      |> Enum.sort_by(& &1["first"])

    balances =
      for type <- App.Leave.types(), entitled = App.Leave.entitlement(type) do
        used =
          leaves |> Enum.filter(&(&1["type"] == type)) |> Enum.map(& &1["days"]) |> Enum.sum()

        %{"type" => type, "entitled" => entitled, "used" => used, "left" => entitled - used}
      end

    %{"year" => year, "balances" => balances, "leaves" => leaves}
  end

  @doc """
  Whether a certificate request can be sent or signed: a valid pay period
  of at most #{@max_months} months, a year for the leave certificate.
  `:ok` or the reason (English; the page translates it).
  """
  @spec check(atom(), map()) :: :ok | {:error, String.t()}
  def check(type, data) do
    case Types.facts(type) do
      "pay" ->
        case pay_period(data) do
          {:ok, _from, _to} -> :ok
          error -> error
        end

      "leave_balance" ->
        if is_integer(data["year"]), do: :ok, else: {:error, "Choose the year."}

      "trip_settlement" ->
        TripSettlement.check(data)

      _ ->
        :ok
    end
  end

  defp pay_period(data) do
    with {:ok, from} <- Date.from_iso8601(data["periodFrom"] || ""),
         {:ok, to} <- Date.from_iso8601(data["periodTo"] || "") do
      cond do
        Date.compare(to, from) == :lt ->
          {:error, "The end of the period is before its start."}

        length(Pay.months(from, to)) > @max_months ->
          {:error, "The period is longer than 24 months."}

        true ->
          {:ok, from, to}
      end
    else
      _ -> {:error, "Enter the period."}
    end
  end

  @doc """
  The printed sections of a certificate's facts, in `locale` through the
  document labels (`App.Documents.Labels`): `%{"title", "rows"}` with
  label/value rows, or with a `"header"` for a table; `"empty"` says what
  an empty section means.
  """
  @spec sections(String.t(), map(), module(), String.t()) :: [map()]
  def sections("service", facts, labels, locale) do
    t = &labels.text(&1, locale)
    rank = facts["rank"]

    [
      %{
        "title" => t.("Service"),
        "rows" =>
          [
            [t.("In service since"), date(facts["serviceStart"])],
            rank &&
              [
                t.("Rank"),
                Enum.join(Enum.reject([rank["title"], rank["grade"]], &blank?/1), ", ")
              ],
            rank && [t.("Rank since"), date(rank["since"])]
          ]
          |> Enum.reject(&(is_nil(&1) or blank?(List.last(&1)))),
        "empty" => t.("No service recorded.")
      },
      %{
        "title" => t.("Current posts"),
        "header" => [t.("Post"), t.("Unit"), t.("Grade"), t.("Since")],
        "rows" =>
          Enum.map(
            facts["posts"],
            &[&1["title"], &1["unit"], &1["grade"] || "—", date(&1["since"])]
          ),
        "empty" => t.("No current post.")
      }
    ]
  end

  def sections("trip_settlement", facts, labels, locale) do
    t = &labels.text(&1, locale)
    money = &"#{group(&1)} #{facts["currency"]}"
    balance = Decimal.new(facts["balance"])

    [
      %{
        "title" => t.("Per-diem allowance"),
        "rows" => [
          [t.("Days"), to_string(facts["days"] || "—")],
          [t.("Rate per day"), money.(facts["rate"])],
          [t.("Allowance"), money.(facts["perDiem"])]
        ]
      },
      %{
        "title" => t.("Costs claimed"),
        "rows" => [
          [t.("Travel"), money.(facts["costs"]["travelCost"])],
          [t.("Accommodation"), money.(facts["costs"]["accommodationCost"])],
          [t.("Other costs"), money.(facts["costs"]["otherCost"])]
        ]
      },
      %{
        "title" => t.("Settlement"),
        "rows" => [
          [t.("Total"), money.(facts["total"])],
          [t.("Advance received"), money.(facts["advance"])],
          if(Decimal.compare(balance, 0) == :lt,
            do: [t.("To return"), money.(Decimal.to_string(Decimal.abs(balance)))],
            else: [t.("To pay out"), money.(facts["balance"])]
          )
        ]
      }
    ]
  end

  def sections("pay", facts, labels, locale) do
    t = &labels.text(&1, locale)
    reason = enum_labels(:compensation, "reason")

    [
      %{
        "title" => t.("Pay rate"),
        "header" => [t.("From"), t.("Monthly rate"), t.("Reason")],
        "rows" =>
          Enum.map(
            facts["rates"],
            &[date(&1["date"]), amount(&1), labels.choice(&1["reason"], reason, locale)]
          ),
        "empty" => t.("No pay rate recorded for the period.")
      },
      %{
        "title" => t.("Pay by month"),
        "header" => [t.("Month"), t.("At the rate"), t.("One-off payments"), t.("Total")],
        "rows" =>
          Enum.map(
            facts["months"],
            &[
              month(&1["month"]),
              amounts(&1["atRate"]),
              amounts(&1["oneOff"]),
              amounts(&1["total"])
            ]
          ),
        "empty" => "—"
      },
      %{
        "title" => t.("Total for the period"),
        "rows" => [
          [
            "#{date(facts["from"])} – #{date(facts["to"])}",
            amounts(facts["totals"])
          ],
          [t.("Source"), t.("Computed from the pay records")]
        ]
      },
      %{
        "title" => t.("One-off payments"),
        "header" => [t.("Date"), t.("Amount"), t.("Reason")],
        "rows" =>
          Enum.map(
            facts["payments"],
            &[date(&1["date"]), amount(&1), labels.choice(&1["reason"], reason, locale)]
          ),
        "empty" => t.("None in the period.")
      }
    ]
  end

  def sections("family", facts, labels, locale) do
    t = &labels.text(&1, locale)
    marital = enum_labels(:family_status, "maritalStatus")
    relationship = enum_labels(:dependent, "relationship")

    [
      %{
        "title" => t.("Family status"),
        "rows" =>
          [
            facts["maritalStatus"] &&
              [t.("Marital status"), labels.choice(facts["maritalStatus"], marital, locale)],
            facts["spouseName"] && [t.("Spouse"), facts["spouseName"]]
          ]
          |> Enum.reject(&is_nil/1),
        "empty" => t.("No family status recorded.")
      },
      %{
        "title" => t.("Dependants"),
        "header" => [t.("Name"), t.("Relationship"), t.("Date of birth")],
        "rows" =>
          Enum.map(
            facts["dependants"],
            &[
              &1["name"],
              labels.choice(&1["relationship"], relationship, locale),
              date(&1["dateOfBirth"]) || "—"
            ]
          ),
        "empty" => t.("No dependants recorded.")
      }
    ]
  end

  def sections("leave_balance", facts, labels, locale) do
    t = &labels.text(&1, locale)
    type = enum_labels(:leave, "leaveType")
    choice = &labels.choice(&1, type, locale)

    [
      %{
        "title" => "#{t.("Leave balance")} #{facts["year"]}",
        "header" => [t.("Type of leave"), t.("Entitled"), t.("Used"), t.("Left")],
        "rows" =>
          Enum.map(
            facts["balances"],
            &[choice.(&1["type"]), "#{&1["entitled"]}", "#{&1["used"]}", "#{&1["left"]}"]
          )
      },
      %{
        "title" => t.("Leave taken"),
        "header" => [
          t.("Type of leave"),
          t.("First day"),
          t.("Last day"),
          t.("Days"),
          t.("Order")
        ],
        "rows" =>
          Enum.map(
            facts["leaves"],
            &[
              choice.(&1["type"]),
              date(&1["first"]),
              date(&1["last"]),
              "#{&1["days"]}",
              &1["basis"] || "—"
            ]
          ),
        "empty" => t.("No leave recorded this year.")
      }
    ]
  end

  # Records of a kind, oldest first, their fields only (decrypted as the system).
  defp records(person_id, kind) do
    PersonRecord
    |> Ash.Query.filter(person_id == ^person_id and kind == ^kind)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.load(:data)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.data)
  end

  defp leave(data) do
    %{
      "type" => data["leaveType"],
      "first" => data["startDate"],
      "last" => data["endDate"],
      "days" => App.Leave.days(data["startDate"], data["endDate"]),
      "basis" => data["basis"]
    }
  end

  defp current?(assignment, date),
    do:
      Date.compare(assignment.starts_on, date) != :gt and
        (is_nil(assignment.ends_on) or Date.compare(assignment.ends_on, date) != :lt)

  defp on_or_before?(value, date) do
    case Date.from_iso8601(value || "") do
      {:ok, d} -> Date.compare(d, date) != :gt
      _ -> false
    end
  end

  defp units do
    Organization
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.id, &1})
  end

  # The unit and its parents, innermost first: "A Company, 1 Battalion, 10 Brigade".
  defp unit_path(units, id, seen \\ []) do
    case units[id] do
      nil ->
        nil

      unit ->
        parent =
          if unit.parent_id && unit.parent_id not in seen,
            do: unit_path(units, unit.parent_id, [id | seen])

        Enum.join(Enum.reject([unit.name, parent], &is_nil/1), ", ")
    end
  end

  defp enum_labels(kind, field),
    do: PersonRecordSchema.schema(kind)["properties"][field]["x-enum-labels"]

  defp blank?(value), do: value in [nil, ""]

  defp date(nil), do: nil

  defp date(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> Calendar.strftime(d, "%d.%m.%Y")
      _ -> value
    end
  end

  defp month(value), do: value |> String.split("-") |> Enum.reverse() |> Enum.join(".")

  defp amount(%{"amount" => amount, "currency" => currency}), do: "#{group(amount)} #{currency}"

  defp amounts(by_currency) when by_currency == %{}, do: "—"

  defp amounts(by_currency),
    do: by_currency |> Enum.sort() |> Enum.map_join("; ", fn {c, a} -> "#{group(a)} #{c}" end)

  # 25000.00 -> "25 000.00" (a no-break space between thousands).
  defp group(amount) do
    [whole | fraction] = String.split(amount, ".")

    {sign, digits} =
      if String.starts_with?(whole, "-"),
        do: {"-", String.slice(whole, 1..-1//1)},
        else: {"", whole}

    grouped =
      digits
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(" ", &Enum.join/1)
      |> String.reverse()

    Enum.join([sign <> grouped | fraction], ".")
  end
end
