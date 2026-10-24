defmodule AppWeb.Sparkline do
  @moduledoc """
  A small inline SVG trend line (docs/design/clinical-module.md: the app's
  own sparklines, no chart library): values in time order, the normal band
  shaded, the last point marked in the flag colour. Scales to the values
  and the band together, so a value outside the band stays visible.
  Decorative for screen readers (`aria-hidden`); the value next to it
  carries the information.
  """
  use Phoenix.Component

  @width 96
  @height 24
  @pad 3

  attr :values, :list, required: true, doc: "numbers, oldest first"
  attr :band, :any, default: nil, doc: "{low, high} normal range, or nil"
  attr :flag, :atom, default: nil, doc: ":low / :high for the last value"

  def sparkline(%{values: values} = assigns) when length(values) < 2 do
    assigns = assign(assigns, :width, @width)

    ~H"""
    <span class="inline-block" style={"width: #{@width}px"} aria-hidden="true"></span>
    """
  end

  def sparkline(assigns) do
    values = assigns.values
    {band_low, band_high} = assigns.band || {nil, nil}
    bounds = Enum.reject(values ++ [band_low, band_high], &is_nil/1)
    {min, max} = {Enum.min(bounds), Enum.max(bounds)}
    span = if max == min, do: 1, else: max - min
    step = (@width - 2 * @pad) / (length(values) - 1)
    y = fn v -> Float.round(@height - @pad - (v - min) / span * (@height - 2 * @pad), 1) end

    points =
      values
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> {Float.round(@pad + i * step, 1), y.(v)} end)

    {last_x, last_y} = List.last(points)

    assigns =
      assign(assigns,
        width: @width,
        height: @height,
        points: Enum.map_join(points, " ", fn {px, py} -> "#{px},#{py}" end),
        band_y: band_low && y.(band_high),
        band_h: band_low && y.(band_low) - y.(band_high),
        last_x: last_x,
        last_y: last_y
      )

    ~H"""
    <svg
      width={@width}
      height={@height}
      viewBox={"0 0 #{@width} #{@height}"}
      class="shrink-0 overflow-visible"
      aria-hidden="true"
    >
      <rect
        :if={@band_y}
        x="0"
        y={@band_y}
        width={@width}
        height={@band_h}
        class="fill-success/15"
      />
      <polyline
        points={@points}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        stroke-linejoin="round"
        class="opacity-60"
      />
      <circle
        cx={@last_x}
        cy={@last_y}
        r="2.5"
        class={if @flag, do: "fill-error", else: "fill-current"}
      />
    </svg>
    """
  end
end
