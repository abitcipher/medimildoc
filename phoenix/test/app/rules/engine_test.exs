defmodule App.Rules.EngineTest do
  @moduledoc "docs/design/data-consistency.md: the ZEN engine through the NIF."
  use ExUnit.Case, async: true

  alias App.Rules.Engine

  @rule "priv/rules/identity_before_examination.json" |> File.read!() |> Jason.decode!()

  defp check(verified_at, at) do
    {:ok, result} =
      Engine.evaluate(@rule["graph"], %{
        "person" => %{"identityVerifiedAt" => verified_at},
        "event" => %{"at" => at}
      })

    result
  end

  test "identity before (or at) the examination is valid; after or missing is not" do
    assert %{"valid" => true} = check("2026-09-01T10:00:00Z", "2026-09-02T09:00:00Z")
    assert %{"valid" => true} = check("2026-09-02T09:00:00Z", "2026-09-02T09:00:00Z")

    assert %{"valid" => false, "code" => "identity_after_examination"} =
             check("2026-09-03T00:00:00Z", "2026-09-02T09:00:00Z")

    assert %{"valid" => false, "code" => "identity_missing"} = check(nil, "2026-09-02T09:00:00Z")
  end

  test "a trace shows each node; broken graphs are reported, not raised" do
    {:ok, result} =
      Engine.evaluate(
        @rule["graph"],
        %{"person" => %{"identityVerifiedAt" => nil}, "event" => %{"at" => "2026-09-02"}},
        trace: true
      )

    assert is_map(result["trace"])
    assert :ok = Engine.validate(@rule["graph"])
    assert {:error, _} = Engine.validate(%{"nodes" => [], "edges" => []})
    assert {:error, _} = Engine.evaluate(%{"nodes" => "nope"}, %{})
  end
end
