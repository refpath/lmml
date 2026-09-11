defmodule Mix.Tasks.Lmml.VerifyTest do
  use ExUnit.Case, async: false

  alias Lmml.Bundle
  alias Lmml.Manifest
  alias Mix.Tasks.Lmml.Verify

  setup do
    dir = Path.join(System.tmp_dir!(), "lmml_verify_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    %{dir: dir}
  end

  defp write_verified!(dir, name) do
    {:ok, bundle} = Bundle.new_zip(name, "See @a.txt.", %{"a.txt" => "x"})
    {:ok, manifest} = Manifest.build(bundle)
    {:ok, bundle} = Manifest.attach(bundle, manifest)
    path = Path.join(dir, name <> ".lmmlz")
    :ok = Bundle.write!(bundle, path)
    path
  end

  test "a bundle whose manifest matches its content is OK", %{dir: dir} do
    path = write_verified!(dir, "good")

    Verify.run([path])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "OK"
  end

  test "a tampered entry fails with the mismatch named", %{dir: dir} do
    path = write_verified!(dir, "tampered")
    {:ok, bundle} = Bundle.open(path)

    {:ok, tampered} =
      Bundle.new_zip("tampered", Bundle.narrative(bundle), Map.put(bundle.entries, "a.txt", "xx"))

    :ok = Bundle.write!(tampered, path)

    assert_raise Mix.Error, ~r/2 issue\(s\)/, fn -> Verify.run([path]) end
    assert_received {:mix_shell, :error, [msg]}
    assert msg =~ "digest mismatch: a.txt"
  end

  test "a missing manifest fails unless explicitly allowed", %{dir: dir} do
    path = Path.join(dir, "plain.lmml")
    File.write!(path, "no manifest here")

    assert_raise Mix.Error, ~r/1 issue/, fn -> Verify.run([path]) end

    Verify.run([path, "--allow-missing-manifest"])
    assert_received {:mix_shell, :info, [msg]}
    assert msg =~ "no manifest"
  end

  test "a policy limit refuses the archive before verification", %{dir: dir} do
    path = write_verified!(dir, "limited")

    assert_raise Mix.Error, ~r/refused: too_many_entries/, fn ->
      Verify.run([path, "--max-entries", "1"])
    end
  end

  test "usage errors are reported" do
    assert_raise Mix.Error, ~r/Usage/, fn -> Verify.run([]) end
    assert_raise Mix.Error, ~r/Usage/, fn -> Verify.run(["a", "--bogus"]) end
  end
end
