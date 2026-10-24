defmodule App.Demo.Correspondence do
  @moduledoc """
  Demo records management (part of `App.Demo`): this year's file plan
  from the template (docs/design/registers-file-plan.md) and registered
  letters with instructions (docs/design/correspondence.md). Kept apart
  from `App.Demo` so neither module depends on too many others.
  """

  alias App.Documents.{Counter, Document, Instruction, Instructions}
  alias App.Leave.CalendarData
  alias App.Records.{CaseLookup, FilePlan}

  @doc "The file plan, then the letters, for the demo `users`."
  @spec build([map()]) :: :ok
  def build(users) do
    build_file_plan(users)
    build_letters(users)
    :ok
  end

  # --- file plan ------------------------------------------------------------

  # This year's file plan from the template (docs/design/registers-file-plan.md),
  # if there is none yet, so signed documents have cases. Not demo data
  # itself: purging leaves it, like any other configuration.
  defp build_file_plan(users) do
    admin = Enum.find(users, &String.starts_with?(to_string(&1.email), "admin@"))

    if admin do
      FilePlan.copy(:template, today().year, admin)
      # A plan kept from an earlier seed: file the new demo documents too.
      Enum.each(FilePlan.cases(today().year, admin), &FilePlan.file_backlog/1)
    end
  end

  # --- correspondence --------------------------------------------------------

  # Registered letters addressed to the commander's battalion
  # (docs/design/correspondence.md), numbered in test registers like the
  # demo orders: instructions to HR (one overdue) and to the commander, and
  # one letter already answered by a signed reply. No scans (no files).
  @letters [
    {"Обласна військова адміністрація", "Про надання списку військовослужбовців у відпустках", 3,
     :hr},
    {"Територіальний центр комплектування", "Про уточнення облікових даних", -1, :hr},
    {"Військова частина А0000", "Про проведення спільних навчань", 5, :commander},
    {"Обласний військовий госпіталь", "Про направлення на лікування", 7, :reply}
  ]

  defp build_letters(users) do
    by_key = Map.new(users, &{&1.email |> to_string() |> String.split("@") |> hd(), &1})
    records = by_key["records_officer"]
    commander = by_key["commander"]
    unit = commander && commander.person_id && CalendarData.unit_of(commander.person_id)

    if records && unit do
      @letters
      |> Enum.with_index(1)
      |> Enum.each(fn {letter, index} -> demo_letter(letter, index, unit, by_key) end)
    end
  end

  defp demo_letter({sender, summary, due_in, executor}, index, unit, by_key) do
    records = by_key["records_officer"]
    received = Date.add(today(), -index)

    data = %{
      "sender" => sender,
      "senderNumber" => "#{100 + index}/#{index}",
      "senderDate" => Date.to_iso8601(Date.add(received, -2)),
      "receivedOn" => Date.to_iso8601(received),
      "delivery" => "edms",
      "summary" => summary,
      "unit" => unit
    }

    letter =
      Document
      |> Ash.Changeset.for_create(:create, %{type: :incoming_letter, data: data}, actor: records)
      |> Ash.create!(actor: records)
      |> seed_registered("вх", received, records)

    if executor == :reply do
      give_demo_instruction(letter, due_in, :hr, by_key)
      demo_reply(letter, data, by_key)
    else
      give_demo_instruction(letter, due_in, executor, by_key)
    end
  end

  defp demo_reply(letter, data, by_key) do
    records = by_key["records_officer"]

    reply =
      Document
      |> Ash.Changeset.for_create(
        :create,
        %{
          type: :outgoing_letter,
          basis_id: letter.id,
          data: %{
            "addressee" => data["sender"],
            "unit" => data["unit"],
            "subject" => "Відповідь на лист № #{data["senderNumber"]}",
            "text" => "Інформацію надаємо в додатку."
          }
        },
        actor: records
      )
      |> Ash.create!(actor: records)
      |> seed_registered("вих", today(), by_key["commander"])

    {:ok, _} = Instructions.close_by_reply(reply)
  end

  defp give_demo_instruction(letter, due_in, executor, by_key) do
    commander = by_key["commander"]

    Instruction
    |> Ash.Changeset.for_create(
      :give,
      %{
        document_id: letter.id,
        text: "Підготувати відповідь",
        executor_id: by_key[Atom.to_string(executor)].id,
        due_on: Date.add(today(), due_in)
      },
      actor: commander
    )
    |> Ash.create!(actor: commander)
  end

  # Marked registered directly in a test register (no PDF), filed into
  # this year's case, like the demo orders.
  defp seed_registered(document, code, date, signer) do
    register = "TEST-" <> code
    seq = Counter.next(register, date.year)

    Ash.Seed.update!(document, %{
      state: :signed,
      register: register,
      register_year: date.year,
      register_seq: seq,
      number: "TEST-#{seq}-#{code}",
      registered_on: date,
      signed_at: DateTime.new!(date, ~T[10:00:00]),
      signed_by_id: signer.id,
      case_id: CaseLookup.case_id(document.type, date.year)
    })
  end

  defp today, do: Date.utc_today()
end
