defmodule Lmml.ManifestTest do
  use ExUnit.Case, async: true

  alias Lmml.Bundle
  alias Lmml.Manifest

  describe "load/1 when no manifest.json embed is mentioned" do
    test "returns {:ok, nil}, not an error" do
      {:ok, bundle} = Bundle.new_text("foo", "Just a plain narrative, no manifest at all.")
      assert {:ok, nil} = Manifest.load(bundle)
    end
  end

  describe "load/1 with an inline manifest.json embed" do
    test "decodes it regardless of bundle kind" do
      {:ok, bundle} =
        Bundle.new_text("foo", "@@@manifest.json\n{\"schema\": 1, \"assets\": [\"a.png\"]}\n@@@")

      assert {:ok, %Manifest{} = manifest} = Manifest.load(bundle)
      assert Manifest.get(manifest, "schema") == 1
      assert Manifest.get(manifest, "assets") == ["a.png"]
      assert Manifest.get(manifest, "missing") == nil
    end

    test "fetch/2 distinguishes a missing key from an explicit null value" do
      {:ok, bundle} =
        Bundle.new_text("foo", "@@@manifest.json\n{\"schema\": 1, \"note\": null}\n@@@")

      {:ok, manifest} = Manifest.load(bundle)

      assert Manifest.fetch(manifest, "schema") == {:ok, 1}
      assert Manifest.fetch(manifest, "note") == {:ok, nil}
      assert Manifest.fetch(manifest, "missing") == :error
    end
  end

  describe "load/1 with an external manifest.json reference" do
    test "resolves it against the zip's own entries" do
      {:ok, bundle} =
        Bundle.new_zip("convo", "See @manifest.json for details.", %{
          "manifest.json" => ~s({"schema": 2})
        })

      assert {:ok, %Manifest{} = manifest} = Manifest.load(bundle)
      assert Manifest.get(manifest, "schema") == 2
    end

    test "errors cleanly when the reference is unresolvable in a bare text bundle" do
      {:ok, bundle} = Bundle.new_text("foo", "See @manifest.json please.")

      assert {:error, {:unresolvable_reference, "manifest.json"}} = Manifest.load(bundle)
    end

    test "errors cleanly when the zip entry it points to is missing" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @manifest.json please.", %{})

      assert {:error, {:missing_entry, "manifest.json"}} = Manifest.load(bundle)
    end
  end

  describe "load/1 with malformed manifest content" do
    test "errors when the content is not valid JSON" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@manifest.json\nnot json at all {{{\n@@@")

      assert {:error, {:invalid_manifest, _reason}} = Manifest.load(bundle)
    end

    test "errors when the content decodes to something other than a JSON object" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@manifest.json\n[1, 2, 3]\n@@@")

      assert {:error, {:invalid_manifest, {:not_an_object, [1, 2, 3]}}} = Manifest.load(bundle)
    end
  end

  describe "load!/1" do
    test "returns the manifest struct directly on success" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@manifest.json\n{\"schema\": 1}\n@@@")
      assert %Manifest{} = Manifest.load!(bundle)
    end

    test "returns nil directly when there is no manifest, without raising" do
      {:ok, bundle} = Bundle.new_text("foo", "no manifest here")
      assert Manifest.load!(bundle) == nil
    end

    test "raises when the manifest is mentioned but unresolvable" do
      {:ok, bundle} = Bundle.new_text("foo", "@manifest.json")

      assert_raise RuntimeError, ~r/Failed to load lmml manifest/, fn ->
        Manifest.load!(bundle)
      end
    end
  end

  describe "load/1 with an archive entry the narrative never mentions" do
    test "finds manifest.json among the archive's entries" do
      {:ok, bundle} =
        Bundle.new_zip("convo", "No reference in the prose.", %{
          "manifest.json" => ~s({"lmml_version":"1","entries":{}})
        })

      assert {:ok, %Manifest{} = manifest} = Manifest.load(bundle)
      assert Manifest.declared_version(manifest) == "1"
      assert :ok = Bundle.validate(bundle)
    end
  end

  describe "versioning" do
    test "a manifest without lmml_version is legacy metadata that loads but cannot verify" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@manifest.json\n{\"schema\": 1}\n@@@")

      assert {:ok, manifest} = Manifest.load(bundle)
      assert Manifest.declared_version(manifest) == nil
      assert Manifest.entries(manifest) == %{}
      assert {:error, [:unversioned_manifest]} = Manifest.verify(bundle)
    end

    test "a version this library does not know is refused at load" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@manifest.json\n{\"lmml_version\": \"2\"}\n@@@")

      assert {:error, {:unsupported_version, "2"}} = Manifest.load(bundle)

      assert {:error, [{:invalid_manifest, {:unsupported_version, "2"}}]} =
               Manifest.verify(bundle)
    end

    test "the supported versions include the one this library writes" do
      assert Manifest.version() in Manifest.supported_versions()
      assert Manifest.version() == "1"
    end
  end

  describe "build/2" do
    setup do
      {:ok, bundle} =
        Bundle.new_zip("convo", "See @photo.png.\n\n@@@notes.txt\nhello\n@@@", %{
          "photo.png" => "PNGBYTES"
        })

      %{bundle: bundle}
    end

    test "binds every mentioned embed to digest, size and media type", %{bundle: bundle} do
      assert {:ok, manifest} = Manifest.build(bundle)
      assert Manifest.declared_version(manifest) == "1"

      assert %{
               "photo.png" => %{"sha256" => photo, "size" => 8, "media_type" => "image/png"},
               "notes.txt" => %{"sha256" => notes, "size" => 6, "media_type" => "text/plain"}
             } = Manifest.entries(manifest)

      assert photo == Lmml.Digest.sha256("PNGBYTES")
      assert notes == Lmml.Digest.sha256("hello\n")
    end

    test "carries extra data and per-entry trust, but not the reserved keys", %{bundle: bundle} do
      assert {:ok, manifest} =
               Manifest.build(bundle,
                 data: %{"session" => "s-1", "extensions" => %{"org.example" => %{"k" => 1}}},
                 trust: %{"notes.txt" => "untrusted"}
               )

      assert Manifest.get(manifest, "session") == "s-1"
      assert Manifest.extensions(manifest) == %{"org.example" => %{"k" => 1}}
      assert Manifest.entries(manifest)["notes.txt"]["trust"] == "untrusted"
      refute Map.has_key?(Manifest.entries(manifest)["photo.png"], "trust")

      assert {:error, {:reserved_key, "entries"}} =
               Manifest.build(bundle, data: %{"entries" => %{}})

      assert {:error, {:unknown_trust, "notes.txt"}} =
               Manifest.build(bundle, trust: %{"notes.txt" => "maybe"})
    end

    test "an unresolvable embed has no digest and fails the build" do
      {:ok, bundle} = Bundle.new_text("foo", "See @missing.png.")
      assert {:error, {:unresolvable_embed, "missing.png"}} = Manifest.build(bundle)
    end

    test "manifest.json is never listed among its own entries" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@manifest.json\n{}\n@@@\n\n@@@a.txt\n1\n@@@")
      {:ok, manifest} = Manifest.build(bundle)

      assert Map.keys(Manifest.entries(manifest)) == ["a.txt"]
    end
  end

  describe "encode/1 and digest/1" do
    test "the digest is over the canonical encoding, independent of stored formatting" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "x"})
      {:ok, manifest} = Manifest.build(bundle)
      {:ok, encoded} = Manifest.encode(manifest)
      {:ok, digest} = Manifest.digest(manifest)

      assert String.starts_with?(
               encoded,
               ~s({"entries":{"a.txt":{"media_type":"text/plain","sha256":")
             )

      assert digest == Lmml.Digest.sha256(encoded)

      # A pretty-printed copy of the same members has the same digest.
      pretty =
        ~s({\n  "lmml_version": "1",\n  "entries": ) <>
          Lmml.Canonical.encode!(Manifest.entries(manifest)) <> "\n}"

      {:ok, reloaded} = Bundle.new_text("foo", "@@@manifest.json\n" <> pretty <> "\n@@@")
      {:ok, reloaded_manifest} = Manifest.load(reloaded)
      assert Manifest.digest(reloaded_manifest) == {:ok, digest}
    end
  end

  describe "attach/2 and verify/1" do
    test "a zip bundle gains a manifest.json entry and verifies" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "x"})
      {:ok, manifest} = Manifest.build(bundle)

      assert {:ok, attached} = Manifest.attach(bundle, manifest)
      assert "manifest.json" in Bundle.entries(attached)
      assert Bundle.narrative(attached) == Bundle.narrative(bundle)
      assert :ok = Manifest.verify(attached)
      assert :ok = Bundle.validate(attached)
    end

    test "a text bundle gains an inline manifest block and verifies" do
      {:ok, bundle} = Bundle.new_text("foo", "@@@a.txt\nx\n@@@")
      {:ok, manifest} = Manifest.build(bundle)

      assert {:ok, attached} = Manifest.attach(bundle, manifest)
      assert Bundle.text?(attached)
      assert {:ok, ^manifest} = Manifest.load(attached)
      assert :ok = Manifest.verify(attached)

      # Attaching again replaces the block rather than stacking a second one.
      assert {:ok, again} = Manifest.attach(attached, manifest)
      assert length(Enum.filter(Bundle.embeds(again), &(&1.name == "manifest.json"))) == 1
      assert :ok = Manifest.verify(again)
    end

    test "a bundle without a manifest cannot verify" do
      {:ok, bundle} = Bundle.new_text("foo", "plain")
      assert {:error, [:no_manifest]} = Manifest.verify(bundle)
    end

    test "a changed entry is a digest and size mismatch" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "x"})
      {:ok, manifest} = Manifest.build(bundle)
      {:ok, tampered} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "xy"})

      assert {:error, issues} = Manifest.verify(tampered, manifest)
      assert {:digest_mismatch, "a.txt"} in issues
      assert {:size_mismatch, "a.txt"} in issues
    end

    test "an embed the narrative mentions but the manifest omits is missing" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "x"})
      {:ok, manifest} = Manifest.build(bundle)

      {:ok, wider} =
        Bundle.new_zip("convo", "See @a.txt and @b.txt.", %{"a.txt" => "x", "b.txt" => "y"})

      assert {:error, [{:missing_entry, "b.txt"}]} = Manifest.verify(wider, manifest)
    end

    test "an entry naming nothing in the bundle is unknown" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "x"})
      {:ok, manifest} = Manifest.build(bundle)
      {:ok, narrower} = Bundle.new_zip("convo", "nothing", %{})

      assert {:error, issues} = Manifest.verify(narrower, manifest)
      assert {:unknown_entry, "a.txt"} in issues
    end

    test "an unreferenced archive entry may still be bound and verified" do
      {:ok, bundle} = Bundle.new_zip("convo", "nothing", %{"extra.bin" => "zzz"})
      digest = Lmml.Digest.sha256("zzz")

      manifest = %Manifest{
        data: %{
          "lmml_version" => "1",
          "entries" => %{"extra.bin" => %{"sha256" => digest, "size" => 3}}
        }
      }

      assert :ok = Manifest.verify(bundle, manifest)
    end

    test "malformed members are reported rather than skipped" do
      {:ok, bundle} = Bundle.new_zip("convo", "See @a.txt.", %{"a.txt" => "x"})
      digest = Lmml.Digest.sha256("x")

      manifest = %Manifest{
        data: %{
          "lmml_version" => "1",
          "entries" => %{
            "a.txt" => %{"sha256" => digest, "size" => 1, "trust" => "sometimes"},
            "manifest.json" => %{"sha256" => digest, "size" => 1},
            "bad" => %{"sha256" => "nope"}
          },
          "extensions" => %{"org.example" => "not an object"}
        }
      }

      assert {:error, issues} = Manifest.verify(bundle, manifest)
      assert {:unknown_trust, "a.txt"} in issues
      assert {:unknown_entry, "manifest.json"} in issues
      assert {:malformed_entry, "bad"} in issues
      assert {:malformed_extensions, %{"org.example" => "not an object"}} in issues

      assert {:error, [{:malformed_entries, "x"}]} =
               Manifest.verify(bundle, %Manifest{data: %{"lmml_version" => "1", "entries" => "x"}})
    end
  end
end
