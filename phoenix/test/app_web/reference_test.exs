defmodule AppWeb.ReferenceTest do
  # Not async: one test swaps the global IHDS request options.
  use AppWeb.ConnCase, async: false

  alias App.Cache

  import App.Fixtures
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias AppWeb.ReferenceComponents

  setup do
    Cache.clear()
    on_exit(&Cache.clear/0)
  end

  describe "GET /reference/:dataset" do
    test "signed out: 401", %{conn: conn} do
      assert conn |> get(~p"/reference/countries") |> json_response(401)
    end

    test "entries with labels in the session language and search words", %{conn: conn} do
      body =
        conn
        |> authenticated_conn(user_fixture(:viewer))
        # What the picker sends; the HTML pipeline would answer 406.
        |> put_req_header("accept", "application/json")
        |> get(~p"/reference/countries?lang=uk")
        |> json_response(200)

      ua = Enum.find(body["entries"], &(&1["code"] == "UA"))
      assert ua["label"] == "Україна"
      assert ua["flag"] == "ua"
      assert "ukraine" in ua["words"]
      # Folded like the picker folds typed text ("ї" loses its diaeresis).
      assert Enum.any?(ua["words"], &String.starts_with?(&1, "укра"))
      assert "ukr" in ua["exact"]
    end

    test "unknown dataset: 404", %{conn: conn} do
      conn = authenticated_conn(conn, user_fixture(:viewer))
      assert conn |> get(~p"/reference/secrets") |> json_response(404)
    end
  end

  describe "languages and currencies" do
    test "lookup works for lower-case language and upper-case currency codes" do
      assert %{"label" => "ukrainien"} = App.IHDS.lookup("languages", "uk", "fr")

      assert %{"label" => "українська гривня", "symbol" => "₴"} =
               App.IHDS.lookup("currencies", "uah", "uk")
    end

    test "served to the picker", %{conn: conn} do
      conn =
        conn
        |> authenticated_conn(user_fixture(:viewer))
        |> put_req_header("accept", "application/json")

      languages = conn |> get(~p"/reference/languages?lang=en") |> json_response(200)
      assert Enum.any?(languages["entries"], &(&1["code"] == "uk" and &1["label"] == "Ukrainian"))

      currencies = conn |> get(~p"/reference/currencies?lang=en") |> json_response(200)
      assert Enum.any?(currencies["entries"], &(&1["code"] == "EUR" and &1["label"] == "Euro"))
    end

    test "a currency input is a picker over currencies" do
      html =
        render_component(&AppWeb.CoreComponents.input/1,
          type: "currency",
          id: "cur",
          name: "d[currency]",
          value: "UAH",
          label: "Currency"
        )

      assert html =~ ~s(data-source="/reference/currencies?lang=en")
      assert html =~ "Ukrainian Hryvnia"
    end

    test "record cards show language and currency names, not codes" do
      person = person_fixture()

      language =
        record_fixture(
          person,
          :language_proficiency,
          sample(:language_proficiency, "language", "fr")
        )

      pay = record_fixture(person, :compensation, sample(:compensation, "currency", "UAH"))

      html = render_component(&AppWeb.RecordComponents.record_card/1, record: language)
      assert html =~ "French"

      html = render_component(&AppWeb.RecordComponents.record_card/1, record: pay)
      assert html =~ "Ukrainian Hryvnia"
    end
  end

  describe "places and regions" do
    test "searched through the app, with context, flag and the place's region", %{conn: conn} do
      body =
        conn
        |> authenticated_conn(user_fixture(:viewer))
        |> put_req_header("accept", "application/json")
        |> get(~p"/reference/places/search?q=Андріївка&lang=uk&country=UA")
        |> json_response(200)

      crimea = Enum.find(body["entries"], &(&1["code"] == "UA01020010010075540"))
      assert crimea["context"] == "Бахчисарайський р-н, Автономна Республіка Крим"
      assert crimea["flag"] == "ua"
      assert crimea["region"] == "UA01000000000013043"
      assert crimea["region_label"] == "Автономна Республіка Крим"
      assert Enum.all?(body["entries"], &(&1["country"] == "UA"))
    end

    test "places are never sent whole", %{conn: conn} do
      conn =
        conn
        |> authenticated_conn(user_fixture(:viewer))
        |> put_req_header("accept", "application/json")

      assert conn |> get(~p"/reference/places") |> json_response(404)
    end

    test "a linked place shows its flag and context; free text says so" do
      linked = place_input("Андріївка", "UA01020010010075540")
      assert linked =~ ~s(phx-hook="ReferenceAutocomplete")
      assert linked =~ ~r/type="hidden" id="p_code" name="p\[code\]" value="UA01020010010075540"/
      assert linked =~ "Бахчисарайський р-н"
      assert linked =~ ~s(src="/flags/4x3/ua.svg")

      free = place_input("Nowhere-on-Sea", nil)
      assert free =~ "Немає у списку"
    end

    test "the person form saves the text and the code", %{conn: conn} do
      person = person_fixture()
      conn = authenticated_conn(conn, user_fixture(:hr))
      {:ok, view, _html} = Phoenix.LiveViewTest.live(conn, ~p"/people/#{person.id}/edit")

      assert Phoenix.LiveViewTest.has_element?(
               view,
               ~s([phx-hook="ReferenceAutocomplete"][data-region-input$="birth_region"])
             )

      view
      |> Phoenix.LiveViewTest.form("#person-form", %{"form" => %{"birth_locality" => "Андріївка"}})
      |> Phoenix.LiveViewTest.render_submit(%{
        "form" => %{"birth_locality_code" => "UA01020010010075540"}
      })

      saved = Ash.get!(App.People.Person, person.id, authorize?: false)
      assert saved.birth_locality == "Андріївка"
      assert saved.birth_locality_code == "UA01020010010075540"
    end
  end

  describe "learned values" do
    defp document(person, authority) do
      App.People.IdentityDocument
      |> Ash.Changeset.for_create(
        :create,
        %{
          person_id: person.id,
          document_type: :passport,
          number: "TEST-7",
          issuing_authority: authority
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)
    end

    test "a saved issuing authority is sent to IHDS; an unchanged one is not" do
      doc = document(person_fixture(), "State Migration Service")
      assert_received {:ihds_learned, "issuing_authority", "State Migration Service"}

      doc
      |> Ash.Changeset.for_update(:update, %{note: "renewed"}, authorize?: false)
      |> Ash.update!(authorize?: false)

      refute_received {:ihds_learned, _, _}
    end

    test "records send only the fields marked x-suggest" do
      person = person_fixture()

      record_fixture(
        person,
        :vetting_record,
        sample(:vetting_record, "investigatingAuthority", "Defence Vetting Agency")
      )

      assert_received {:ihds_learned, "vetting_authority", "Defence Vetting Agency"}

      record_fixture(person, :allergy_intolerance)
      refute_received {:ihds_learned, _, _}
    end

    test "suggestions are served to signed-in users for known categories only", %{conn: conn} do
      conn =
        conn
        |> authenticated_conn(user_fixture(:viewer))
        |> put_req_header("accept", "application/json")

      body =
        conn
        |> get(~p"/reference/learned/issuing_authority/search?q=State")
        |> json_response(200)

      assert [%{"label" => "State Authority"} | _] = body["entries"]

      assert conn |> get(~p"/reference/learned/diagnosis/search?q=a") |> json_response(404)
    end

    test "the identity document form offers them" do
      html =
        render_component(&AppWeb.CoreComponents.input/1,
          type: "suggest",
          suggest: "issuing_authority",
          id: "ia",
          name: "d[issuing_authority]",
          value: nil,
          label: "Issuing authority"
        )

      assert html =~ ~s(data-source="/reference/learned/issuing_authority/search")
    end
  end

  describe "country display" do
    test "flag and name in the current language, code on hover" do
      Gettext.put_locale("uk")
      html = render_component(&ReferenceComponents.country/1, code: "UA")
      assert html =~ "Україна"
      assert html =~ ~s(src="/flags/4x3/ua.svg")
      assert html =~ ~s(title="UA")
    after
      Gettext.put_locale("en")
    end

    test "nothing stored: a dash; an unknown code: the code itself" do
      assert render_component(&ReferenceComponents.country/1, code: nil) =~ "—"
      assert render_component(&ReferenceComponents.country/1, code: "QQ") =~ "QQ"
    end
  end

  describe "country input" do
    test "a picker with the stored code in a hidden input" do
      html = country_input()
      assert html =~ ~s(phx-hook="ReferencePicker")
      assert html =~ ~s(data-source="/reference/countries?lang=en")
      assert html =~ ~r/type="hidden" id="c" name="p\[c\]" value="DE"/
      assert html =~ "Germany"
    end

    test "IHDS down: a plain two-letter field, so the form still works" do
      previous = Application.get_env(:app, :ihds_req_options)
      Application.put_env(:app, :ihds_req_options, plug: &Plug.Conn.send_resp(&1, 503, ""))
      on_exit(fn -> Application.put_env(:app, :ihds_req_options, previous) end)

      html = country_input()
      refute html =~ "ReferencePicker"
      assert html =~ ~s(maxlength="2")
      assert html =~ ~s(value="DE")
    end
  end

  test "the person page shows the birth country by name", %{conn: conn} do
    person = person_fixture(%{birth_country: "FR", birth_locality: "Lyon"})

    html =
      conn
      |> authenticated_conn(user_fixture(:hr))
      |> get(~p"/people/#{person.id}")
      |> html_response(200)

    assert html =~ "Lyon"
    assert html =~ "France"
    assert html =~ ~s(src="/flags/4x3/fr.svg")
  end

  defp sample(kind, key, value), do: Map.put(App.Demo.sample_record_data(kind), key, value)

  defp place_input(text, code) do
    Gettext.put_locale("uk")

    render_component(&AppWeb.ReferenceComponents.autocomplete/1,
      kind: "place",
      id: "p",
      name: "p[text]",
      value: text,
      code_id: "p_code",
      code_name: "p[code]",
      code_value: code
    )
  after
    Gettext.put_locale("en")
  end

  defp country_input do
    render_component(&AppWeb.CoreComponents.input/1,
      type: "country",
      id: "c",
      name: "p[c]",
      value: "DE",
      label: "Country"
    )
  end
end
