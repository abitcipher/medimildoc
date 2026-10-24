defmodule AppWeb.MyData do
  @moduledoc """
  A person's own data (docs/design/events-and-person-login.md) for
  `/me` and its downloads: the card rows of `AppWeb.SheetCard` read as
  their own (`own: true` — every category, still as the viewer, so
  sensitive reads are in the access log), and the same as Markdown, PDF
  (Typst, `priv/document_templates/personal_data.typ`) or JSON — the JSON
  machine-readable: the person's fields, posts and records as stored.
  """
  use Gettext, backend: AppWeb.Gettext

  require Ash.Query

  alias App.Documents.Pdf
  alias App.People.{Assignment, Person, PersonRecord}
  alias AppWeb.SheetCard

  @formats ~w(pdf markdown json)

  @doc "The download formats."
  @spec formats() :: [String.t()]
  def formats, do: @formats

  @doc "The person `user` is linked to, or nil."
  @spec person(map()) :: Person.t() | nil
  def person(%{person_id: nil}), do: nil

  def person(%{person_id: id} = user) do
    case Ash.get(Person, id, actor: user, authorize?: false) do
      {:ok, person} -> person
      _ -> nil
    end
  end

  @doc "The card rows of the user's own person."
  @spec rows(map(), Person.t()) :: [{atom(), String.t(), String.t()}]
  def rows(user, person), do: SheetCard.rows(person, user, own: true)

  @doc "The file for `format`: `{filename, content type, body}`."
  @spec export(String.t(), map(), Person.t()) ::
          {:ok, {String.t(), String.t(), iodata()}} | {:error, term()}
  def export("markdown", user, person),
    do: {:ok, {file(person, "md"), "text/markdown", markdown(rows(user, person))}}

  def export("json", user, person),
    do:
      {:ok,
       {file(person, "json"), "application/json",
        Jason.encode_to_iodata!(json(user, person), pretty: true)}}

  def export("pdf", user, person) do
    payload = %{
      title: gettext("My data"),
      generated: AppWeb.DateFormat.display(Date.utc_today()),
      lang: Gettext.get_locale(AppWeb.Gettext),
      rows: Enum.map(rows(user, person), fn {kind, label, value} -> [kind, label, value] end)
    }

    with {:ok, pdf} <- Pdf.render("personal_data.typ", payload),
         do: {:ok, {file(person, "pdf"), "application/pdf", pdf}}
  end

  defp file(person, ext), do: "my-data-#{person.person_id}.#{ext}"

  @doc "The card rows as Markdown (pure)."
  @spec markdown([{atom(), String.t(), String.t()}]) :: String.t()
  def markdown(rows) do
    rows
    |> Enum.map(fn
      {:title, label, _} -> "# #{label}"
      {:subtitle, id, post} -> "\n#{id} — #{post}"
      {:section, label, _} -> "\n## #{label}"
      {:record, label, _} -> "\n### #{label}"
      {:field, label, value} -> "- **#{label}:** #{value}"
      {:blank, _, _} -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # Machine-readable: as stored, not as shown.
  defp json(user, person) do
    read = &Ash.read!(&1, actor: user, authorize?: false)

    %{
      exported_at: DateTime.utc_now(),
      person:
        Map.take(person, [
          :id,
          :person_id,
          :given_name,
          :family_name,
          :patronymic,
          :email,
          :date_of_birth,
          :birth_country,
          :birth_region,
          :birth_locality
        ]),
      assignments:
        Assignment
        |> Ash.Query.filter(person_id == ^person.id)
        |> Ash.Query.load(position: :organization)
        |> read.()
        |> Enum.map(fn a ->
          %{
            post: a.position && a.position.title,
            unit: a.position && a.position.organization && a.position.organization.name,
            starts_on: a.starts_on,
            ends_on: a.ends_on
          }
        end),
      records:
        PersonRecord
        |> Ash.Query.filter(person_id == ^person.id)
        |> Ash.Query.sort(recorded_at: :desc)
        |> read.()
        |> Enum.map(fn r ->
          %{kind: r.kind, effective_on: r.effective_on, recorded_at: r.recorded_at, data: r.data}
        end)
    }
  end
end
