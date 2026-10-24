defmodule App.People.FilesTest do
  use App.DataCase, async: false

  import App.Fixtures

  alias App.People.{Attachment, Files}
  alias App.StorageStub

  setup do
    App.Access.put_admin_full_data_access_override(false)
    %{person: person_fixture(), hr: user_fixture(:hr)}
  end

  defp file(bytes) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest of a png">>
  @pdf "%PDF-1.7 fake body"
  @dicom :binary.copy(<<0>>, 128) <> "DICM" <> "rest"

  defp store(actor, bytes, attrs), do: Files.store(actor, file(bytes), attrs)

  test "a photo is stored with its checked type, size and hash", %{person: person, hr: hr} do
    {:ok, a} = store(hr, @png, %{person_id: person.id, purpose: :photo, file_name: "me.png"})

    assert a.content_type == "image/png"
    assert a.size == byte_size(@png)
    assert a.sha256 == Base.encode16(:crypto.hash(:sha256, @png), case: :lower)
    assert a.uploaded_by_email == to_string(hr.email)
    assert StorageStub.object(a.object_key) == @png
    refute a.object_key =~ "me"
  end

  test "types come from the bytes: HTML named .png is refused, a PDF is no photo",
       %{person: person, hr: hr} do
    assert {:error, :unsupported_type} =
             store(hr, "<html><script>alert(1)</script>", %{
               person_id: person.id,
               purpose: :document,
               file_name: "evil.png"
             })

    assert {:error, :not_a_photo} =
             store(hr, @pdf, %{person_id: person.id, purpose: :photo, file_name: "x.pdf"})

    assert {:ok, %{content_type: "application/dicom"}} =
             store(hr, @dicom, %{person_id: person.id, purpose: :imaging, file_name: "ct.dcm"})

    assert Ash.read!(Attachment, authorize?: false) |> length() == 1
  end

  test "SVG and EPS are recognised from their content and only ever downloaded",
       %{person: person, hr: hr} do
    svg = """
    \uFEFF<?xml version="1.0" encoding="UTF-8"?>
    <!-- drawn by hand -->
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>alert(1)</script></svg>
    """

    eps = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\nshowpage\n"
    dos_eps = <<0xC5, 0xD0, 0xD3, 0xC6, 30, 0, 0, 0>>
    attrs = %{person_id: person.id, purpose: :document}

    {:ok, a} = store(hr, svg, Map.put(attrs, :file_name, "logo.svg"))
    {:ok, b} = store(hr, eps, Map.put(attrs, :file_name, "logo.eps"))
    {:ok, c} = store(hr, dos_eps, Map.put(attrs, :file_name, "old.eps"))

    assert {a.content_type, b.content_type, c.content_type} ==
             {"image/svg+xml", "application/postscript", "application/postscript"}

    # Never shown inline, even when asked: an SVG on our domain could run scripts.
    for file <- [a, b] do
      refute Files.inline?(file.content_type)
      {:ok, url} = Files.link(hr, file.id, inline: true)
      assert url =~ "attachment"
    end

    # Plain PostScript, other XML and SVG as a photo are refused.
    for {bytes, purpose} <- [
          {"%!PS-Adobe-3.0\nshowpage\n", :document},
          {"<?xml version=\"1.0\"?><html/>", :document},
          {svg, :photo}
        ] do
      assert {:error, _} =
               store(hr, bytes, %{attrs | purpose: purpose} |> Map.put(:file_name, "x"))
    end
  end

  test "who may read: photos with the person, documents as private data",
       %{person: person, hr: hr} do
    {:ok, photo} = store(hr, @png, %{person_id: person.id, purpose: :photo, file_name: "p.png"})
    {:ok, scan} = store(hr, @pdf, %{person_id: person.id, purpose: :document, file_name: "s.pdf"})

    viewer = user_fixture(:viewer)
    assert [%{id: id}] = Ash.read!(Attachment, actor: viewer)
    assert id == photo.id
    assert {:error, _} = Files.link(viewer, scan.id)
    assert Ash.read!(Attachment, actor: hr) |> length() == 2
  end

  # Clinicians are unit-scoped: the patient and the clinician share a unit.
  defp clinician_for(person) do
    unit = org_fixture("Clinic unit")
    assign_fixture(person, unit)
    unit_user_fixture(:viewer, [:clinician], unit)
  end

  test "a file on a medical record is exactly as readable as the record",
       %{person: person} do
    record = record_fixture(person, :medical_condition)
    clinician = clinician_for(person)

    {:ok, xray} =
      store(clinician, @dicom, %{
        person_id: person.id,
        record_id: record.id,
        purpose: :imaging,
        file_name: "xray.dcm"
      })

    assert xray.kind == :medical_condition
    assert [_] = Ash.read!(Attachment, actor: clinician)
    assert [] = Ash.read!(Attachment, actor: user_fixture(:hr))
    # A clinician of another unit doesn't see it either.
    other = unit_user_fixture(:viewer, [:clinician], org_fixture("Elsewhere"))
    assert [] = Ash.read!(Attachment, actor: other)
  end

  test "a record of another person can't take the file", %{person: person, hr: hr} do
    other = record_fixture(person_fixture(), :contact_info)

    assert {:error, _} =
             store(hr, @pdf, %{
               person_id: person.id,
               record_id: other.id,
               purpose: :document,
               file_name: "x.pdf"
             })
  end

  test "links: sensitive files are logged, photos are not; content type is forced",
       %{person: person, hr: hr} do
    {:ok, photo} = store(hr, @png, %{person_id: person.id, purpose: :photo, file_name: "p.png"})
    {:ok, scan} = store(hr, @pdf, %{person_id: person.id, purpose: :document, file_name: "s.pdf"})

    {:ok, url} = Files.link(hr, photo.id, inline: true)
    assert url =~ "https://files.test/hrda-files/f/"
    assert url =~ "response-content-type=image%2Fpng"
    assert url =~ "inline"
    assert Ash.read!(App.Audit.AccessLog, authorize?: false) == []

    {:ok, url} = Files.link(hr, scan.id)
    assert url =~ "attachment"
    assert [log] = Ash.read!(App.Audit.AccessLog, authorize?: false)
    assert log.record_id == scan.id and log.kind == "file:document"
  end

  test "deleting a file, its record or its person removes the stored objects",
       %{person: person, hr: hr} do
    {:ok, a} = store(hr, @pdf, %{person_id: person.id, purpose: :document, file_name: "a.pdf"})
    Ash.destroy!(a, actor: hr)
    assert StorageStub.object(a.object_key) == nil

    record = record_fixture(person, :contact_info)

    {:ok, b} =
      store(hr, @pdf, %{
        person_id: person.id,
        record_id: record.id,
        purpose: :document,
        file_name: "b.pdf"
      })

    Ash.destroy!(record, authorize?: false)
    assert StorageStub.object(b.object_key) == nil
    assert Ash.read!(Attachment, authorize?: false) == []
  end

  test "raising a record's classification raises its files'", %{person: person} do
    record = record_fixture(person, :medical_condition)
    clinician = clinician_for(person)

    {:ok, a} =
      store(clinician, @pdf, %{
        person_id: person.id,
        record_id: record.id,
        purpose: :document,
        file_name: "a.pdf"
      })

    record
    |> Ash.Changeset.for_update(:update, %{classification: :nato_secret}, authorize?: false)
    |> Ash.update!(authorize?: false)

    assert Ash.get!(Attachment, a.id, authorize?: false).classification == :nato_secret
  end
end
