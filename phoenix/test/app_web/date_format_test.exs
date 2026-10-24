defmodule AppWeb.DateFormatTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AppWeb.DateFormat

  test "dates display as dd.mm.yyyy; ISO strings too; other values pass through" do
    assert DateFormat.display(~D[2025-12-31]) == "31.12.2025"
    assert DateFormat.display("2026-01-05") == "05.01.2026"
    assert DateFormat.display(~U[2026-01-05 10:00:00Z]) == "05.01.2026"
    assert DateFormat.display(nil) == ""
    assert DateFormat.display("not a date") == "not a date"
  end

  test "parse accepts only real dates in the pattern" do
    assert DateFormat.parse("31.12.2025") == {:ok, ~D[2025-12-31]}
    assert DateFormat.parse("1.2.2026") == {:ok, ~D[2026-02-01]}
    assert DateFormat.parse("31.02.2026") == :error
    assert DateFormat.parse("2026-02-01") == :error
  end

  test "the date input shows dd.mm.yyyy but submits the ISO value" do
    html =
      render_component(&AppWeb.CoreComponents.input/1,
        type: "date",
        name: "form[starts_on]",
        id: "starts_on",
        value: ~D[2026-03-04],
        label: "Starts",
        required: true
      )

    assert html =~ ~s(id="starts_on-display")
    assert html =~ ~s(value="04.03.2026")
    assert html =~ ~s(name="form[starts_on]")
    assert html =~ ~s(value="2026-03-04")
    assert html =~ ~s(placeholder="dd.mm.yyyy")
    assert html =~ ~s(phx-hook="DateInput")
  end
end
