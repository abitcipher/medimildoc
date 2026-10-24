defmodule AppWeb.FileSize do
  @moduledoc "A file size for people: bytes, KB or MB."

  @spec display(non_neg_integer()) :: String.t()
  def display(bytes) when bytes < 1024, do: "#{bytes} B"
  def display(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  def display(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"
end
