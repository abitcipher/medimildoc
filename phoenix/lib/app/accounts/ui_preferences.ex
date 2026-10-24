defmodule App.Accounts.UiPreferences do
  @moduledoc """
  A user's interface settings (`User.ui_preferences`,
  docs/design/ui-preferences.md): how forms are shown, chosen separately
  for narrow screens (phones; below the `md` breakpoint, 768 px) and for
  wide screens.

  - `edit_form` — an edit form opens `inline` (in the page) or in a
    `modal` window.
  - `create_form` — where the control for adding an entry is: the form
    always `visible` under the list, a labelled button in a `toolbar`
    above it (the default), a `compact` icon button, or an item in a ⋮
    `menu`. An opened form is shown the way `edit_form` says.
  - `forms` — the same `create_form` choice for one form (`forms/0`),
    overriding the general one; without it the form follows the general
    choice.
  - `sections` — how content sections look: `glow` (a frame whose border
    lights up in colour near the pointer; the default), `static` (the
    frame only) or `off`. One choice for all screens: on touch screens and
    with reduced motion there is no glow anyway.
  - Forms shown in a window: `window_controls` — the window buttons
    `left` (default) or `right`, the form buttons in the opposite corner;
    `form_buttons` — Save/Cancel at the end of the `form` (default) or in
    the window `header`; `window_border` — a thin `colour` gradient frame
    (default) or a `contrast` one (dark on light themes, light grey on
    dark).

  Stored as `%{"edit_form" => %{"narrow" => "modal"}, "forms" =>
  %{"identifier" => %{"wide" => "compact"}}, …}`; anything unknown is
  dropped, a missing value is the default. Pure.
  """

  @settings %{
    "edit_form" => {~w(inline modal), "inline"},
    "create_form" => {~w(visible toolbar compact menu), "toolbar"}
  }
  @widths ~w(narrow wide)

  # Forms with an add control that can be set on their own (labels in
  # AppWeb.InterfaceLive).
  @forms ~w(organization position provider assignment identifier identity_document deputy case)

  @section_styles ~w(glow static off)

  # One value for all screens, the default first.
  @singles %{
    "sections" => @section_styles,
    "window_controls" => ~w(left right),
    "form_buttons" => ~w(form header),
    "window_border" => ~w(colour contrast)
  }

  @doc "The general settings and their values."
  @spec settings() :: [{String.t(), [String.t()]}]
  def settings,
    do: Enum.map(~w(edit_form create_form), fn s -> {s, elem(@settings[s], 0)} end)

  @spec widths() :: [String.t()]
  def widths, do: @widths

  @doc "The forms that can have their own add-control setting."
  @spec forms() :: [String.t()]
  def forms, do: @forms

  @doc "The section styles, the default first."
  @spec section_styles() :: [String.t()]
  def section_styles, do: @section_styles

  @doc "How content sections look (`glow`, `static` or `off`)."
  @spec section_style(map() | nil) :: String.t()
  def section_style(prefs), do: single(prefs, "sections")

  @doc "`prefs` with the section style set; `:error` for an unknown one."
  @spec put_section_style(map() | nil, String.t()) :: {:ok, map()} | :error
  def put_section_style(prefs, value), do: put_single(prefs, "sections", value)

  @doc "The settings with one value for all screens, and their values (default first)."
  @spec singles() :: map()
  def singles, do: @singles

  @doc "The value of a one-value setting (`singles/0`), or its default."
  @spec single(map() | nil, String.t()) :: String.t()
  def single(prefs, key) do
    [default | _] = values = Map.fetch!(@singles, key)
    value = (prefs || %{})[key]
    if value in values, do: value, else: default
  end

  @doc "`prefs` with a one-value setting set; `:error` for an unknown setting or value."
  @spec put_single(map() | nil, String.t(), String.t()) :: {:ok, map()} | :error
  def put_single(prefs, key, value) do
    if value in Map.get(@singles, key, []),
      do: {:ok, prefs |> normalize() |> Map.put(key, value)},
      else: :error
  end

  @doc "The value of a general `setting` for screens of `width` (narrow or wide)."
  @spec get(map() | nil, String.t(), String.t()) :: String.t()
  def get(prefs, setting, width) when width in @widths do
    {values, default} = Map.fetch!(@settings, setting)
    value = get_in(prefs || %{}, [setting, width])
    if value in values, do: value, else: default
  end

  @doc "Where the add control of `form` is on `width`: its own setting, else the general one."
  @spec create_mode(map() | nil, String.t() | nil, String.t()) :: String.t()
  def create_mode(prefs, form, width) do
    case form_override(prefs, form, width) do
      nil -> get(prefs, "create_form", width)
      value -> value
    end
  end

  @doc "`form`'s own setting for `width`, or nil when it follows the general one."
  @spec form_override(map() | nil, String.t() | nil, String.t()) :: String.t() | nil
  def form_override(prefs, form, width) do
    {values, _default} = @settings["create_form"]
    value = get_in(prefs || %{}, ["forms", form, width])
    if form in @forms and value in values, do: value
  end

  @doc "`prefs` with `setting` for `width` set to `value`; `:error` for anything unknown."
  @spec put(map() | nil, String.t(), String.t(), String.t()) :: {:ok, map()} | :error
  def put(prefs, setting, width, value) do
    case @settings[setting] do
      {values, _default} when width in @widths ->
        if value in values,
          do: {:ok, prefs |> normalize() |> put_in([Access.key(setting, %{}), width], value)},
          else: :error

      _ ->
        :error
    end
  end

  @doc """
  `prefs` with `form`'s own add-control setting for `width` set to `value`,
  or removed with `"default"` (the form then follows the general one).
  """
  @spec put_form(map() | nil, String.t(), String.t(), String.t()) :: {:ok, map()} | :error
  def put_form(prefs, form, width, value) do
    {values, _default} = @settings["create_form"]
    prefs = normalize(prefs)

    cond do
      form not in @forms or width not in @widths ->
        :error

      value == "default" ->
        {:ok, drop_form(prefs, form, width)}

      value in values ->
        {:ok, put_in(prefs, [Access.key("forms", %{}), Access.key(form, %{}), width], value)}

      true ->
        :error
    end
  end

  defp drop_form(prefs, form, width) do
    by_width = prefs |> get_in(["forms", form]) |> Kernel.||(%{}) |> Map.delete(width)

    forms =
      if by_width == %{},
        do: Map.delete(prefs["forms"] || %{}, form),
        else: Map.put(prefs["forms"] || %{}, form, by_width)

    if forms == %{}, do: Map.delete(prefs, "forms"), else: Map.put(prefs, "forms", forms)
  end

  @doc "Only known settings, forms, widths and values."
  @spec normalize(term()) :: map()
  def normalize(prefs) when is_map(prefs) do
    general =
      for {setting, {values, _default}} <- @settings,
          kept = keep(prefs[setting], values),
          kept != %{},
          into: %{},
          do: {setting, kept}

    {create_values, _default} = @settings["create_form"]

    by_form = if is_map(prefs["forms"]), do: prefs["forms"], else: %{}

    forms =
      for form <- @forms,
          kept = keep(by_form[form], create_values),
          kept != %{},
          into: %{},
          do: {form, kept}

    general = if forms == %{}, do: general, else: Map.put(general, "forms", forms)

    for {key, values} <- @singles, prefs[key] in values, into: general, do: {key, prefs[key]}
  end

  def normalize(_prefs), do: %{}

  defp keep(%{} = by_width, values),
    do: Map.filter(by_width, fn {w, v} -> w in @widths and v in values end)

  defp keep(_other, _values), do: %{}
end
