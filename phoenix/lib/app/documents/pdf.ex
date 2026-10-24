defmodule App.Documents.Pdf do
  @moduledoc """
  Renders a document's PDF with Typst (docs/design/documents-core.md):
  the type's template (`priv/document_templates`) reads the print payload
  (`App.Documents.Print`) as `data.json`; fonts only from `priv/fonts`
  (Liberation Serif, SIL OFL), never the system's, so the output is the
  same everywhere; PDF/A-2b for long-term archiving.

  The binary comes from `config :app, :typst_path` (default `typst` on the
  PATH; in the image `/usr/local/bin/typst`).
  """

  @spec render(String.t(), map()) :: {:ok, binary()} | {:error, term()}
  def render(template, payload) do
    # Resolved at run time: in a release priv/ lives with the app, not
    # where it was compiled (found on the first production run).
    templates = Application.app_dir(:app, "priv/document_templates")
    fonts = Application.app_dir(:app, "priv/fonts")
    dir = Path.join(System.tmp_dir!(), "doc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      for file <- File.ls!(templates),
          Path.extname(file) == ".typ",
          do: File.cp!(Path.join(templates, file), Path.join(dir, file))

      File.write!(Path.join(dir, "data.json"), Jason.encode!(payload))
      out = Path.join(dir, "out.pdf")

      args = [
        "compile",
        "--root",
        dir,
        "--font-path",
        fonts,
        "--ignore-system-fonts",
        "--pdf-standard",
        "a-2b",
        Path.join(dir, template),
        out
      ]

      case System.cmd(typst(), args, stderr_to_stdout: true) do
        {_output, 0} -> {:ok, File.read!(out)}
        {output, status} -> {:error, {:typst_failed, status, String.slice(output, 0, 2000)}}
      end
    rescue
      error in ErlangError -> {:error, {:typst_unavailable, error.original}}
    after
      File.rm_rf(dir)
    end
  end

  defp typst, do: Application.get_env(:app, :typst_path, "typst")
end
