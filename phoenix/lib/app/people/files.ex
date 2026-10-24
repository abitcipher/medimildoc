defmodule App.People.Files do
  @moduledoc """
  Storing and serving `App.People.Attachment`s
  (docs/design/reference-data-and-files.md).

  - `store/4` checks an uploaded file, hashes it, puts it in RustFS under
    an opaque key and creates the row (with the actor, so the resource
    policies decide); if the row can't be created the object is removed.
  - `link/3` returns a short-lived signed download link for a file the
    actor may read, writing the access log first for sensitive files.

  **File types come from the file's first bytes, never from the browser**,
  and only these are accepted: JPEG, PNG, WebP, TIFF, PDF, DICOM, ZIP,
  SVG and EPS. Links are served from the app's own domain, so an HTML or
  SVG file shown in the browser would run as the app; the allowlist, the
  content type forced on every link, and inline display only for raster
  images and PDF keep that from happening — SVG (which can carry scripts)
  and EPS (PostScript, a program) are only ever downloaded.
  """
  require Ash.Query

  alias App.Audit.AccessLogger
  alias App.People.Attachment

  @max_bytes 200 * 1024 * 1024
  @photo_max_bytes 10 * 1024 * 1024

  # {content type, extension, may be shown inline}
  @types %{
    jpeg: {"image/jpeg", "jpg", true},
    png: {"image/png", "png", true},
    webp: {"image/webp", "webp", true},
    tiff: {"image/tiff", "tif", false},
    pdf: {"application/pdf", "pdf", true},
    dicom: {"application/dicom", "dcm", false},
    zip: {"application/zip", "zip", false},
    svg: {"image/svg+xml", "svg", false},
    eps: {"application/postscript", "eps", false}
  }

  @photo_types [:jpeg, :png, :webp]

  # An SVG document: optional BOM, XML declaration, comments, processing
  # instructions and doctype, then the <svg> root element.
  @svg_root ~r/\A(?:\xEF\xBB\xBF)?\s*(?:<\?xml[^>]*\?>\s*)?(?:(?:<!--.*?-->|<\?[^>]*\?>|<!DOCTYPE[^>]*>)\s*)*<svg[\s>\/]/s

  @doc "Largest file accepted, in bytes (a portrait photo: #{@photo_max_bytes})."
  @spec max_bytes(atom()) :: pos_integer()
  def max_bytes(:photo), do: @photo_max_bytes
  def max_bytes(_purpose), do: @max_bytes

  @doc "File name extensions offered in the upload dialog for `purpose`."
  @spec accept(atom()) :: [String.t()]
  def accept(:photo), do: ~w(.jpg .jpeg .png .webp)
  def accept(_purpose), do: ~w(.jpg .jpeg .png .webp .tif .tiff .pdf .dcm .zip .svg .eps)

  @doc """
  Stores the uploaded file at `path` as a new attachment of `person_id`.
  `attrs`: `purpose`, `file_name`, optional `record_id`.
  """
  @spec store(map(), Path.t(), map(), keyword()) ::
          {:ok, Attachment.t()} | {:error, term()}
  def store(actor, path, attrs, _opts \\ []) do
    purpose = attrs[:purpose] || :document
    %{size: size} = File.stat!(path)

    with {:ok, type} <- detect(path),
         :ok <- allowed(type, purpose, size) do
      {content_type, _ext, _inline} = @types[type]
      key = "f/" <> Ash.UUIDv7.generate()

      attrs =
        Map.merge(attrs, %{
          purpose: purpose,
          content_type: content_type,
          size: size,
          sha256: sha256(path),
          object_key: key,
          file_name: clean_name(attrs[:file_name] || "file")
        })

      with :ok <- App.Storage.put_file(key, path, content_type) do
        create_or_remove(actor, attrs)
      end
    end
  end

  @doc """
  The checks every upload goes through, for files kept elsewhere (a
  document's files, docs/design/correspondence.md): the type from the
  first bytes (only the allowed ones), the size, the SHA-256 and a clean
  file name.
  """
  @spec check_upload(Path.t(), String.t()) ::
          {:ok,
           %{
             content_type: String.t(),
             size: non_neg_integer(),
             sha256: String.t(),
             file_name: String.t()
           }}
          | {:error, term()}
  def check_upload(path, file_name) do
    %{size: size} = File.stat!(path)

    with {:ok, type} <- detect(path),
         :ok <- allowed(type, :document, size) do
      {content_type, _ext, _inline} = @types[type]

      {:ok,
       %{
         content_type: content_type,
         size: size,
         sha256: sha256(path),
         file_name: clean_name(file_name || "file")
       }}
    end
  end

  # The row decides (policies); without it the stored object goes again.
  defp create_or_remove(actor, attrs) do
    case Attachment |> Ash.Changeset.for_create(:create, attrs, actor: actor) |> Ash.create() do
      {:ok, attachment} ->
        {:ok, attachment}

      {:error, error} ->
        App.Storage.delete(attrs.object_key)
        {:error, error}
    end
  end

  @doc """
  A signed download link (valid a few minutes) for `attachment_id`, if the
  actor may read it; sensitive files are logged first and get no link when
  the log can't be written. `inline: true` shows images and PDF in the
  browser (other types always download).
  """
  @spec link(map(), Ash.UUID.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def link(actor, attachment_id, opts \\ []) do
    with {:ok, attachment} <- Ash.get(Attachment, attachment_id, actor: actor),
         :ok <- AccessLogger.log_file_link(actor, attachment) do
      {:ok, signed_link(attachment, opts)}
    end
  end

  @doc """
  Signed links for many files the caller already read with the actor's
  policies, without logging — only for non-sensitive files (portrait
  photos as avatars); sensitive files must go through `link/3`.
  """
  @spec unlogged_link(Attachment.t(), keyword()) :: String.t()
  def unlogged_link(%Attachment{} = attachment, opts \\ []) do
    if AccessLogger.sensitive_file?(attachment),
      do: raise(ArgumentError, "sensitive files need a logged link (link/3)")

    signed_link(attachment, opts)
  end

  @doc """
  Portrait photo links for `person_ids` the actor may see:
  `%{person_id => url}` for those who have one (the newest photo). One
  query; links are cached for most of their hour so avatars keep stable
  URLs (browser caching). Photos aren't sensitive files, so not logged.
  """
  @spec photo_urls(map() | nil, [Ash.UUID.t()]) :: %{Ash.UUID.t() => String.t()}
  def photo_urls(_actor, []), do: %{}

  def photo_urls(actor, person_ids) do
    Attachment
    |> Ash.Query.filter(purpose == :photo and is_nil(record_id) and person_id in ^person_ids)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(actor: actor)
    |> Enum.uniq_by(& &1.person_id)
    |> Map.new(&{&1.person_id, cached_photo_link(&1)})
  end

  @photo_link_seconds 3600

  defp cached_photo_link(attachment) do
    key = {:photo_link, attachment.id}

    case App.Cache.fetch(key) do
      {:ok, url} ->
        url

      :miss ->
        url = unlogged_link(attachment, inline: true, expires_in: @photo_link_seconds)
        App.Cache.put(key, url, :timer.minutes(50))
        url
    end
  end

  @doc "Whether a file of this content type may be shown in the browser."
  @spec inline?(String.t()) :: boolean()
  def inline?(content_type),
    do: Enum.any?(@types, fn {_t, {ct, _ext, inline}} -> ct == content_type and inline end)

  defp signed_link(attachment, opts) do
    App.Storage.link(attachment.object_key, attachment.file_name,
      inline: opts[:inline] == true and inline?(attachment.content_type),
      content_type: attachment.content_type,
      expires_in: opts[:expires_in]
    )
  end

  defp allowed(type, :photo, size) do
    cond do
      type not in @photo_types -> {:error, :not_a_photo}
      size > @photo_max_bytes -> {:error, :too_large}
      true -> :ok
    end
  end

  defp allowed(_type, _purpose, size) when size > @max_bytes, do: {:error, :too_large}
  defp allowed(_type, _purpose, _size), do: :ok

  @doc false
  # The type from the first bytes (DICOM: "DICM" after a 128-byte preamble;
  # SVG: the root element after an optional XML declaration, comments and
  # doctype, so a few kilobytes are read).
  @spec detect(Path.t()) :: {:ok, atom()} | {:error, :unsupported_type}
  def detect(path) do
    case File.open!(path, [:read, :binary], &IO.binread(&1, 4096)) do
      head when is_binary(head) -> signature(head)
      _empty -> {:error, :unsupported_type}
    end
  end

  defp signature(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, :jpeg}
  defp signature(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, :png}
  defp signature(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, :webp}
  defp signature(<<"II", 42, 0, _::binary>>), do: {:ok, :tiff}
  defp signature(<<"MM", 0, 42, _::binary>>), do: {:ok, :tiff}
  defp signature(<<"%PDF-", _::binary>>), do: {:ok, :pdf}
  defp signature(<<_::binary-size(128), "DICM", _::binary>>), do: {:ok, :dicom}
  defp signature(<<"PK", 3, 4, _::binary>>), do: {:ok, :zip}
  # EPS: the DOS binary header, or a PostScript header naming EPSF.
  defp signature(<<0xC5, 0xD0, 0xD3, 0xC6, _::binary>>), do: {:ok, :eps}

  defp signature(<<"%!PS-Adobe-", rest::binary>>) do
    [first_line | _] = String.split(rest, ["\r", "\n"], parts: 2)
    if String.contains?(first_line, "EPSF-"), do: {:ok, :eps}, else: {:error, :unsupported_type}
  end

  defp signature(head) do
    if Regex.match?(@svg_root, head), do: {:ok, :svg}, else: {:error, :unsupported_type}
  end

  defp sha256(path) do
    path
    |> File.stream!(65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Keeps the name readable but drops path parts and control characters.
  defp clean_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "")
    |> String.slice(0, 200)
    |> case do
      "" -> "file"
      cleaned -> cleaned
    end
  end
end
