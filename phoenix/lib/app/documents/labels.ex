defmodule App.Documents.Labels do
  @moduledoc """
  Where printed documents get their words: labels and choice values in the
  print language (docs/design/documents-core.md: Ukrainian templates).
  The translations live in the web layer (Gettext), which the domain must
  not import, so the implementation is configured
  (`config :app, :document_labels`) — `AppWeb.DocumentLabels` in the app,
  this module's own identity implementation otherwise (English as
  written).
  """

  @doc "A label or text from a type's JSON, in `locale`."
  @callback text(String.t(), String.t()) :: String.t()

  @doc "A choice value shown with the property's `x-enum-labels`, in `locale`."
  @callback choice(String.t(), map() | nil, String.t()) :: String.t()

  @behaviour __MODULE__

  @impl true
  def text(text, _locale), do: text

  @impl true
  def choice(value, labels, _locale), do: (labels || %{})[value] || value

  @doc "The configured implementation."
  @spec impl() :: module()
  def impl, do: Application.get_env(:app, :document_labels, __MODULE__)
end
