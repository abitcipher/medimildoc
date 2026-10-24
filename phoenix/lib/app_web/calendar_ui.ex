defmodule AppWeb.CalendarUI do
  @moduledoc "Small helpers shared by month grids (the leave calendar, the duty roster)."
  use Gettext, backend: AppWeb.Gettext

  def weekend?(date), do: Date.day_of_week(date) >= 6

  def weekday(date),
    do:
      Enum.at(
        [
          gettext("Mo"),
          gettext("Tu"),
          gettext("We"),
          gettext("Th"),
          gettext("Fr"),
          gettext("Sa"),
          gettext("Su")
        ],
        Date.day_of_week(date) - 1
      )

  def month_label(date),
    do: "#{String.pad_leading(Integer.to_string(date.month), 2, "0")}.#{date.year}"

  @rows_page 25

  @doc """
  The first rows of a month grid as a stream (`:rows`, items
  `%{id, member}`), keeping as many as were shown when the same grid is
  reloaded (`keep: true`, after a change); the rest come with `more_rows/2`
  as the grid is scrolled to its end (`phx-viewport-bottom`).
  """
  @spec first_rows(Phoenix.LiveView.Socket.t(), [map()], keyword()) :: Phoenix.LiveView.Socket.t()
  def first_rows(socket, members, opts \\ []) do
    shown =
      if opts[:keep],
        do: max(socket.assigns[:shown] || @rows_page, @rows_page),
        else: @rows_page

    socket
    |> Phoenix.Component.assign(shown: min(shown, length(members)))
    |> Phoenix.LiveView.stream(:rows, members |> Enum.take(shown) |> Enum.map(&row/1),
      reset: true
    )
  end

  @doc "The next page of rows of the grid."
  @spec more_rows(Phoenix.LiveView.Socket.t(), [map()]) :: Phoenix.LiveView.Socket.t()
  def more_rows(socket, members) do
    shown = socket.assigns.shown
    next = members |> Enum.drop(shown) |> Enum.take(@rows_page) |> Enum.map(&row/1)

    socket
    |> Phoenix.Component.assign(shown: shown + length(next))
    |> Phoenix.LiveView.stream(:rows, next)
  end

  defp row(member), do: %{id: member.person_id, member: member}
end
