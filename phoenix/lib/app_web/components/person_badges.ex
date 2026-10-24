defmodule AppWeb.PersonBadges do
  @moduledoc """
  Small badges for people lists (direct reports, readiness): the person's
  avatar, their position and a status. Each shows short details on hover
  and keyboard focus (`data-float-tip`, assets/js/float_tip.js — not
  clipped by the scrolling list) and to screen readers (`aria-label`). What they show comes from rows the
  caller built through the normal read policies (`AppWeb.PersonRows`), so
  a badge never reveals more than its viewer may read.

  Avatars show initials until photos exist (a photo URL, when given, is
  used instead; stored photos come with the file storage step).
  """
  use Phoenix.Component
  use Gettext, backend: AppWeb.Gettext

  @avatar_colors ~w(bg-primary bg-secondary bg-accent bg-info bg-success bg-warning)

  # Literal class names (Tailwind only keeps classes it can see in code).
  @status_colors %{
    "success" => "badge-success",
    "warning" => "badge-warning",
    "error" => "badge-error",
    "info" => "badge-info",
    "neutral" => "badge-neutral"
  }

  @doc "Round avatar: photo if there is one, else initials on a stable colour."
  attr :name, :string, required: true
  attr :key, :string, required: true, doc: "stable value for the colour (person id)"
  attr :photo_url, :string, default: nil
  attr :tip, :string, default: nil, doc: "hover text (defaults to the name)"

  def avatar(assigns) do
    assigns =
      assigns
      |> assign(:tip, assigns.tip || assigns.name)
      |> assign(:initials, initials(assigns.name))
      |> assign(
        :color,
        Enum.at(@avatar_colors, :erlang.phash2(assigns.key, length(@avatar_colors)))
      )

    ~H"""
    <span class="shrink-0" data-float-tip={@tip} aria-label={@tip} role="img">
      <img :if={@photo_url} src={@photo_url} alt="" class="size-7 rounded-full object-cover" />
      <span
        :if={!@photo_url}
        class={[
          "grid size-7 place-items-center rounded-full text-[0.65rem] font-semibold text-white",
          @color
        ]}
        aria-hidden="true"
      >
        {@initials}
      </span>
    </span>
    """
  end

  @doc """
  A position as a compact badge with its short label
  (`App.People.PositionLabel`: "Rifleman A.Co¦1Bn¦OR-3"); hover shows the
  title, unit and grade in full.
  """
  attr :position, :map, default: nil, doc: "%{title, organization, grade} or nil"
  attr :class, :any, default: nil

  def position(%{position: nil} = assigns) do
    ~H"""
    <span class={["badge badge-sm badge-ghost opacity-60", @class]}>{gettext("No position")}</span>
    """
  end

  def position(assigns) do
    p = assigns.position

    tip =
      [p.title, p.organization, p.grade && gettext("grade %{grade}", grade: p.grade)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    assigns = assign(assigns, :tip, tip)

    ~H"""
    <span
      class={["badge badge-sm badge-outline max-w-56", @class]}
      data-float-tip={@tip}
      aria-label={@tip}
    >
      <span class="min-w-0 truncate">{App.People.PositionLabel.short(@position)}</span>
    </span>
    """
  end

  @doc """
  A status as a small coloured badge with one symbol (`+`, `–`, `~`, as
  declared in the kind's schema, `x-enum-badges`); hover shows the status
  name and `details`.
  """
  attr :label, :string, required: true
  attr :badge, :map, default: nil, doc: ~s(%{"symbol", "color"} from the schema)
  attr :details, :list, default: []

  def status(assigns) do
    badge = assigns.badge || %{}

    assigns =
      assigns
      |> assign(:symbol, badge["symbol"] || "?")
      |> assign(:color_class, Map.get(@status_colors, badge["color"], "badge-ghost"))
      |> assign(:tip, Enum.join([assigns.label | Enum.reject(assigns.details, &is_nil/1)], " · "))

    ~H"""
    <span
      class={["badge badge-sm w-6 shrink-0 justify-center font-bold", @color_class]}
      data-float-tip={@tip}
      aria-label={@tip}
      role="img"
    >
      <span aria-hidden="true">{@symbol}</span>
    </span>
    """
  end

  defp initials(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> then(fn words -> if length(words) > 2, do: [hd(words), List.last(words)], else: words end)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end
end
