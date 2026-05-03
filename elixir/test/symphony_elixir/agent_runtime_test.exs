defmodule SymphonyElixir.AgentRuntimeTest do
  use ExUnit.Case, async: true

  defmodule FakeAdapter do
    @behaviour SymphonyElixir.AgentRuntime

    @impl true
    def start_session(_workspace_path, _config), do: {:ok, %{handle: :fake}}

    @impl true
    def send_turn(_session, _prompt, _opts), do: :ok

    @impl true
    def stream_events(_session), do: Stream.cycle([%{kind: :noop}]) |> Stream.take(0)

    @impl true
    def stop_session(_session), do: :ok

    @impl true
    def runtime_native_tokens(_session), do: %{input: 0, output: 0}

    @impl true
    def passes_safety_floor?(_config, _floor), do: true
  end

  test "FakeAdapter implements all 6 AgentRuntime callbacks" do
    assert {:ok, _} = FakeAdapter.start_session("/tmp", %{})
    assert :ok = FakeAdapter.send_turn(%{}, "hi", [])
    assert is_struct(FakeAdapter.stream_events(%{}), Stream) or is_function(FakeAdapter.stream_events(%{}))
    assert :ok = FakeAdapter.stop_session(%{})
    assert %{input: 0, output: 0} = FakeAdapter.runtime_native_tokens(%{})
    assert FakeAdapter.passes_safety_floor?(%{}, %{}) == true
  end
end
