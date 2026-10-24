defmodule AppWeb.DocumentLabels do
  @moduledoc """
  The web layer's `App.Documents.Labels`: printed documents in the print
  language through the same Gettext catalogs as the UI (`AppWeb.SchemaText`).
  Configured in `config :app, :document_labels`.
  """
  @behaviour App.Documents.Labels

  use Gettext, backend: AppWeb.Gettext

  @doc false
  # Words the domain writes itself (App.Documents.Effects, Print), marked
  # for extraction.
  def texts,
    do: [
      gettext_noop("Medical board"),
      gettext_noop("Yes"),
      gettext_noop("No"),
      # App.Documents.Effects.check/1
      gettext_noop("The person already holds a post; use a transfer order."),
      gettext_noop("The person holds no post; use an appointment order."),
      gettext_noop("The person already holds this post."),
      gettext_noop("The transfer must be after the current post started."),
      gettext_noop("The person holds no post to be released from."),
      gettext_noop("The release date is before the current post started."),
      gettext_noop("The post does not exist."),
      # priv/rules/identity_before_examination.json
      gettext_noop("No identity document was entered before this examination."),
      gettext_noop("The identity document was entered after this examination."),
      gettext_noop("Identity verified before examination"),
      gettext_noop("The last day of leave is before the first day."),
      gettext_noop("The last day of the trip is before the first day."),
      gettext_noop("The discharge date is before the admission date."),
      gettext_noop("Sick leave needs both its first and last day."),
      gettext_noop("The last day of sick leave is before the first day."),
      # priv/rules/leave_within_balance.json, leave_no_overlap.json
      gettext_noop("Leave within the balance"),
      gettext_noop("More days are requested than are left for this type of leave this year."),
      gettext_noop("Leave periods don't overlap"),
      # priv/rules/fitness_from_signed_conclusion.json
      gettext_noop("Fitness only from a signed conclusion"),
      gettext_noop("This fitness status is not backed by a signed medical board conclusion."),
      # priv/rules/leave_within_unit_limit.json
      gettext_noop("Leave within the unit limit"),
      gettext_noop("Too many of the unit would be away on these days."),
      gettext_noop("The period overlaps another leave of this person."),
      # priv/rules/no_diagnosis_in_restrictions.json, signed_after_basis.json,
      # assignments_no_overlap.json
      gettext_noop("No diagnosis in duty restrictions"),
      gettext_noop("The duty restrictions seem to contain a diagnosis code."),
      gettext_noop("Signed after its basis"),
      gettext_noop("The document is signed before the document it is based on."),
      gettext_noop("Assignments of a person do not overlap"),
      gettext_noop("The assignment overlaps another assignment of this person."),
      # App.Documents.Changes.Acknowledge
      gettext_noop("The order does not exist."),
      gettext_noop("This document is not acknowledged."),
      gettext_noop("Only a signed order can be acknowledged."),
      gettext_noop("The date is in the future."),
      gettext_noop("The date is before the order was signed."),
      # App.Documents.Certificates (sections and checks)
      gettext_noop("Amount"),
      gettext_noop("At the rate"),
      gettext_noop("Choose the year."),
      gettext_noop("Computed from the pay records"),
      gettext_noop("Current posts"),
      gettext_noop("Date"),
      gettext_noop("Date of birth"),
      gettext_noop("Days"),
      gettext_noop("Dependants"),
      gettext_noop("Enter the period."),
      gettext_noop("Entitled"),
      gettext_noop("Family status"),
      gettext_noop("First day"),
      gettext_noop("From"),
      gettext_noop("Grade"),
      gettext_noop("In service since"),
      gettext_noop("Last day"),
      gettext_noop("Leave balance"),
      gettext_noop("Leave taken"),
      gettext_noop("Left"),
      gettext_noop("Marital status"),
      gettext_noop("Month"),
      gettext_noop("Monthly rate"),
      gettext_noop("Name"),
      gettext_noop("No current post."),
      gettext_noop("No dependants recorded."),
      gettext_noop("No family status recorded."),
      gettext_noop("No leave recorded this year."),
      gettext_noop("No pay rate recorded for the period."),
      gettext_noop("No service recorded."),
      gettext_noop("None in the period."),
      gettext_noop("One-off payments"),
      gettext_noop("Order"),
      gettext_noop("Pay by month"),
      # Business-trip report settlement (App.Documents.Certificates.TripSettlement)
      gettext_noop("Per-diem allowance"),
      gettext_noop("Days"),
      gettext_noop("Rate per day"),
      gettext_noop("Allowance"),
      gettext_noop("Costs claimed"),
      gettext_noop("Travel"),
      gettext_noop("Accommodation"),
      gettext_noop("Other costs"),
      gettext_noop("Settlement"),
      gettext_noop("Total"),
      gettext_noop("Advance received"),
      gettext_noop("To return"),
      gettext_noop("To pay out"),
      gettext_noop("Give the trip's actual first and last day, the last not before the first."),
      gettext_noop("Pay rate"),
      gettext_noop("Post"),
      gettext_noop("Rank"),
      gettext_noop("Rank since"),
      gettext_noop("Reason"),
      gettext_noop("Relationship"),
      gettext_noop("Service"),
      gettext_noop("Since"),
      gettext_noop("Source"),
      gettext_noop("Spouse"),
      gettext_noop("The end of the period is before its start."),
      gettext_noop("The period is longer than 24 months."),
      gettext_noop("Total"),
      gettext_noop("Total for the period"),
      gettext_noop("Type of leave"),
      gettext_noop("Unit"),
      gettext_noop("Used")
    ]

  @impl true
  def text(text, locale),
    do:
      Gettext.with_locale(AppWeb.Gettext, locale, fn -> Gettext.gettext(AppWeb.Gettext, text) end)

  @impl true
  def choice(value, labels, locale),
    do:
      Gettext.with_locale(AppWeb.Gettext, locale, fn ->
        AppWeb.SchemaText.choice(value, labels)
      end)
end
