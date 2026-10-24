defmodule AppWeb.GettextCatalogsTest do
  @moduledoc """
  `mix gettext.extract --merge` pre-fills new strings with "fuzzy" guesses
  from similar existing ones ("Security clearance" got "Security
  officer"'s translation). Gettext serves those guesses as real
  translations, so a fuzzy entry in a catalog is a wrong string on screen.
  Every translation must be written and checked by hand.
  """
  use ExUnit.Case, async: true

  defp catalogs,
    do: Path.wildcard(Path.expand("../../priv/gettext/*/LC_MESSAGES/*.po", __DIR__))

  test "no catalog contains fuzzy (machine-guessed) entries" do
    assert catalogs() != []

    for catalog <- catalogs() do
      refute File.read!(catalog) =~ ~r/^#,.*\bfuzzy\b/m, "#{catalog} has fuzzy entries"
    end
  end

  test "every translation uses the same %{bindings} as its msgid" do
    for catalog <- catalogs(), entry <- String.split(File.read!(catalog), "\n\n") do
      with [_, msgid] <- Regex.run(~r/^msgid "(.*)"$/m, entry),
           [_, msgstr] <- Regex.run(~r/^msgstr "(.+)"$/m, entry) do
        bindings =
          &(Regex.scan(~r/%\{(\w+)\}/, &1) |> Enum.map(fn [_, b] -> b end) |> Enum.sort())

        assert bindings.(msgid) == bindings.(msgstr), "#{catalog}: #{msgid}"
      end
    end
  end
end
