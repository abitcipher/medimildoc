defmodule App.People.PersonIdTest do
  use ExUnit.Case, async: true

  alias App.People.PersonId

  describe "generate/0" do
    test "produces a 12-character code" do
      for _ <- 1..200 do
        assert String.length(PersonId.generate()) == 12
      end
    end

    test "always satisfies valid?/1 (shape round-trip)" do
      for _ <- 1..200 do
        code = PersonId.generate()
        assert PersonId.valid?(code), "#{code} failed valid?/1"
      end
    end

    test "produces different codes across calls (not a fixed sequence)" do
      codes = for _ <- 1..50, do: PersonId.generate()
      # Not a strict uniqueness guarantee (that's generate_unique/0's job)
      # — just confirms this isn't somehow deterministic/constant.
      assert length(Enum.uniq(codes)) > 1
    end
  end

  describe "valid?/1" do
    test "rejects the wrong length" do
      refute PersonId.valid?("ABCD")
      refute PersonId.valid?(PersonId.generate() <> "X")
    end

    test "rejects two consonants (or two vowels) in a row" do
      # B-C-D-U-N-A-B-E-G-E-M-I: "BC" at the start breaks alternation.
      refute PersonId.valid?("BCDUNABEGEMI")
    end

    test "rejects a letter used more than twice" do
      # Properly alternating (T-A-T-A-T-A-...) but both T and A appear
      # three times — alternation alone isn't enough to reject it.
      refute PersonId.valid?("TATATABEGEMI")
    end

    test "rejects non-letter characters and lowercase" do
      refute PersonId.valid?("tudunabegemi")
      refute PersonId.valid?("TUD-UNABEGEM")
    end

    test "not a binary at all" do
      refute PersonId.valid?(nil)
      refute PersonId.valid?(12)
    end
  end

  describe "format/1 and unformat/1" do
    test "groups into 4-4-4 and round-trips" do
      code = PersonId.generate()
      formatted = PersonId.format(code)
      assert formatted =~ ~r/^[A-Z]{4}-[A-Z]{4}-[A-Z]{4}$/
      assert PersonId.unformat(formatted) == code
    end

    test "unformat/1 tolerates lowercase and stray whitespace, same as a human would type it back" do
      code = PersonId.generate()
      formatted = PersonId.format(code)
      messy = formatted |> String.downcase() |> String.replace("-", " ")
      assert PersonId.unformat(messy) == code
    end
  end

  describe "to_did/1 and from_did/1" do
    test "round-trips through the configured DID method" do
      code = PersonId.generate()
      did = PersonId.to_did(code)
      assert did == "did:example:person:#{code}"
      assert PersonId.from_did(did) == code
    end

    test "from_did/1 rejects a URI for a different method/type or malformed input" do
      code = PersonId.generate()
      refute PersonId.from_did("did:example:organization:#{code}")
      refute PersonId.from_did("not-a-did-at-all")
      refute PersonId.from_did(PersonId.to_did(code) <> "X")
    end

    test "to_did/1 respects a configured did_method" do
      Application.put_env(:app, :did_method, "gov:ua")
      code = PersonId.generate()
      assert PersonId.to_did(code) == "did:gov:ua:person:#{code}"
      assert PersonId.from_did("did:gov:ua:person:#{code}") == code
    after
      Application.delete_env(:app, :did_method)
    end
  end
end
