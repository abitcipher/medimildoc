defmodule App.Clinical.VitalsTest do
  use ExUnit.Case, async: true

  alias App.Clinical.Vitals

  @normal %{
    "respiratoryRate" => 16,
    "spo2" => 98,
    "onOxygen" => false,
    "systolic" => 124,
    "heartRate" => 72,
    "consciousness" => "alert",
    "temperature" => 36.8
  }

  test "normal adult vital signs: NEWS2 0, low risk, no flags" do
    assert {:ok, %{score: 0, risk: :low}} = Vitals.news2(@normal)
    assert Vitals.flags(@normal) == %{}
  end

  test "each NEWS2 band boundary (RCP chart, SpO2 scale 1)" do
    cases = [
      {"respiratoryRate", 8, 3},
      {"respiratoryRate", 9, 1},
      {"respiratoryRate", 11, 1},
      {"respiratoryRate", 12, 0},
      {"respiratoryRate", 20, 0},
      {"respiratoryRate", 21, 2},
      {"respiratoryRate", 24, 2},
      {"respiratoryRate", 25, 3},
      {"spo2", 91, 3},
      {"spo2", 92, 2},
      {"spo2", 93, 2},
      {"spo2", 94, 1},
      {"spo2", 95, 1},
      {"spo2", 96, 0},
      {"onOxygen", true, 2},
      {"systolic", 90, 3},
      {"systolic", 91, 2},
      {"systolic", 100, 2},
      {"systolic", 101, 1},
      {"systolic", 110, 1},
      {"systolic", 111, 0},
      {"systolic", 219, 0},
      {"systolic", 220, 3},
      {"heartRate", 40, 3},
      {"heartRate", 41, 1},
      {"heartRate", 50, 1},
      {"heartRate", 51, 0},
      {"heartRate", 90, 0},
      {"heartRate", 91, 1},
      {"heartRate", 110, 1},
      {"heartRate", 111, 2},
      {"heartRate", 130, 2},
      {"heartRate", 131, 3},
      {"consciousness", "new_confusion", 3},
      {"consciousness", "unresponsive", 3},
      {"temperature", 35.0, 3},
      {"temperature", 35.1, 1},
      {"temperature", 36.0, 1},
      {"temperature", 36.1, 0},
      {"temperature", 38.0, 0},
      {"temperature", 38.1, 1},
      {"temperature", 39.0, 1},
      {"temperature", 39.1, 2}
    ]

    for {key, value, expected} <- cases do
      {:ok, %{parts: parts}} = Vitals.news2(Map.put(@normal, key, value))
      assert parts[key] == expected, "#{key} #{value}: expected #{expected}, got #{parts[key]}"
    end
  end

  test "risk levels: a single 3 is low-medium, 5-6 medium, 7+ high" do
    assert {:ok, %{score: 3, risk: :low_medium}} =
             Vitals.news2(Map.put(@normal, "consciousness", "voice"))

    # RR 22 (2) + HR 112 (2) + SpO2 95 (1) = 5
    assert {:ok, %{score: 5, risk: :medium}} =
             Vitals.news2(%{@normal | "respiratoryRate" => 22, "heartRate" => 112, "spo2" => 95})

    # RR 26 (3) + SBP 95 (2) + HR 112 (2) = 7
    assert {:ok, %{score: 7, risk: :high}} =
             Vitals.news2(%{
               @normal
               | "respiratoryRate" => 26,
                 "systolic" => 95,
                 "heartRate" => 112
             })
  end

  test "NEWS2 needs all seven parameters" do
    assert {:incomplete, ["onOxygen", "temperature"]} =
             Vitals.news2(Map.drop(@normal, ["onOxygen", "temperature"]))
  end

  test "flags mark values outside the normal band" do
    assert Vitals.flags(%{"heartRate" => 130, "systolic" => 95, "temperature" => 36.5}) ==
             %{"heartRate" => :high, "systolic" => :low}

    assert Vitals.flags(%{"consciousness" => "pain"}) == %{"consciousness" => :low}
  end
end
