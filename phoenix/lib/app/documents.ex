defmodule App.Documents do
  @moduledoc """
  Ash domain for documents with a lifecycle (docs/design/documents-core.md):
  typed documents about a person, their route steps, history and register
  counters. What a document type contains and does is declared in
  `priv/document_types/` (`App.Documents.Types`).
  """
  use Ash.Domain

  resources do
    resource(App.Documents.Document)
    resource(App.Documents.Step)
    resource(App.Documents.Event)
    resource(App.Documents.Counter)
    resource(App.Documents.Acknowledgement)
    resource(App.Documents.Deputy)
    resource(App.Documents.DocumentFile)
    resource(App.Documents.Instruction)
  end
end
