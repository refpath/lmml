defmodule Lmml.Manifest.ToolEventTest do
  use ExUnit.Case, async: true

  alias Lmml.Bundle
  alias Lmml.Manifest
  alias Lmml.Manifest.ToolEvent

  defp bundle_with_tool_embeds do
    {:ok, bundle} =
      Bundle.new_zip(
        "convo",
        "<!-- assistant -->\nLet me look.\n<!-- tool -->\nSee @call-1.json and @result-1.json.",
        %{
          "call-1.json" => ~s({"path":"README.md"}),
          "result-1.json" => ~s({"bytes":120})
        }
      )

    bundle
  end

  describe "new/4" do
    test "builds a well-formed event with the optional members given" do
      assert {:ok, event} =
               ToolEvent.new("call-1", "read_file", "ok",
                 arguments: "call-1.json",
                 result: "result-1.json",
                 provenance: %{"host" => "sandbox"}
               )

      assert event == %{
               "call_id" => "call-1",
               "tool" => "read_file",
               "status" => "ok",
               "arguments" => "call-1.json",
               "result" => "result-1.json",
               "provenance" => %{"host" => "sandbox"}
             }

      assert ToolEvent.well_formed?(event)
    end

    test "an unknown status is rejected" do
      assert {:error, {:unknown_status, "maybe"}} = ToolEvent.new("c", "t", "maybe")
    end

    test "an optional member of the wrong shape is malformed" do
      assert {:error, {:malformed_tool_event, _}} =
               ToolEvent.new("c", "t", "ok", provenance: "text")

      refute ToolEvent.well_formed?(%{
               "call_id" => "c",
               "tool" => "t",
               "status" => "ok",
               "result" => 1
             })

      refute ToolEvent.well_formed?(%{"tool" => "t", "status" => "ok"})
    end
  end

  describe "verify/1 with tool events" do
    test "events whose embeds are bound by the manifest verify" do
      bundle = bundle_with_tool_embeds()

      {:ok, event} =
        ToolEvent.new("call-1", "read_file", "ok",
          arguments: "call-1.json",
          result: "result-1.json"
        )

      {:ok, manifest} = Manifest.build(bundle, data: %{"tool_events" => [event]})
      {:ok, bundle} = Manifest.attach(bundle, manifest)

      assert :ok = Manifest.verify(bundle)
      assert [^event] = ToolEvent.list(Manifest.load!(bundle))
    end

    test "an event naming an embed the manifest does not bind is reported" do
      bundle = bundle_with_tool_embeds()
      {:ok, event} = ToolEvent.new("call-1", "read_file", "ok", result: "ghost.json")
      {:ok, manifest} = Manifest.build(bundle, data: %{"tool_events" => [event]})

      assert {:error, [{:missing_tool_embed, {"call-1", "ghost.json"}}]} =
               Manifest.verify(bundle, manifest)
    end

    test "duplicate call ids and malformed events are reported by position" do
      bundle = bundle_with_tool_embeds()
      {:ok, event} = ToolEvent.new("call-1", "read_file", "ok")

      {:ok, manifest} =
        Manifest.build(bundle, data: %{"tool_events" => [event, event, %{"nope" => true}]})

      assert {:error, issues} = Manifest.verify(bundle, manifest)
      assert {:duplicate_call_id, "call-1"} in issues
      assert {:malformed_tool_event, 2} in issues
    end

    test "a tool_events member that is not a list is malformed" do
      bundle = bundle_with_tool_embeds()
      {:ok, manifest} = Manifest.build(bundle, data: %{"tool_events" => %{}})

      assert {:error, [{:malformed_tool_events, %{}}]} = Manifest.verify(bundle, manifest)
    end

    test "a manifest without tool events lists none" do
      bundle = bundle_with_tool_embeds()
      {:ok, manifest} = Manifest.build(bundle)

      assert ToolEvent.list(manifest) == []
      assert ToolEvent.statuses() == ["ok", "error"]
    end
  end
end
