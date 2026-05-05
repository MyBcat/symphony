defmodule SymphonyElixir.E2E.SymphonyRunner do
  @moduledoc """
  Spawns the Symphony escript binary as a long-running OS subprocess and
  streams its combined stdout/stderr to a log file. Used by the e2e nightly
  Mix task (`Mix.Tasks.Symphony.E2eNightly`) as the `symphony_subprocess`
  dependency the harness wires through.

  Lives in its own module — and is excluded from coverage in `mix.exs` — so
  the harness/Mix task layers stay 100% unit-testable. This module is
  exercised in CI by the live e2e workflow.
  """

  @doc """
  Spawn `bin/symphony --i-understand-... <workflow_path>` as a Port. Streams
  output to `log_path`. Returns:

    * `{:ok, %{log_tail: tail}}` on a clean exit
    * `{:error, {:port_exit_nonzero, status}, tail}` on a non-zero exit
    * `{:error, {:shutdown, reason}, tail}` when the parent harness shuts us
      down (Task.shutdown). On shutdown, SIGTERM/SIGKILL is delivered to the
      OS pid so Symphony actually dies.
    * `{:error, {:symphony_binary_not_found, binary}, ""}` when the binary
      path doesn't exist on disk.

  `opts`:
    * `:binary`   — path to the symphony escript (required)
    * `:log_path` — path to write combined stdout/stderr (required)
    * `:opts`     — keyword list with at least `:workflow_path` (required)
  """
  @spec spawn(keyword()) ::
          {:ok, %{log_tail: String.t()}} | {:error, term(), String.t()}
  def spawn(opts) do
    Process.flag(:trap_exit, true)

    binary = Keyword.fetch!(opts, :binary)
    log_path = Keyword.fetch!(opts, :log_path)
    runner_opts = Keyword.fetch!(opts, :opts)
    workflow_path = Keyword.fetch!(runner_opts, :workflow_path)

    File.mkdir_p!(Path.dirname(log_path))
    {:ok, log_io} = File.open(log_path, [:write, :binary])

    args = [
      "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
      workflow_path
    ]

    binary_path = System.find_executable(binary) || binary

    cond do
      not File.regular?(binary_path) ->
        File.close(log_io)
        {:error, {:symphony_binary_not_found, binary}, ""}

      true ->
        port =
          Port.open({:spawn_executable, binary_path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args}
          ])

        os_pid = port_os_pid(port)
        result = collect_port_output(port, log_io, log_path, os_pid)
        File.close(log_io)
        result
    end
  end

  defp port_os_pid(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp collect_port_output(port, log_io, log_path, os_pid) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(log_io, data)
        collect_port_output(port, log_io, log_path, os_pid)

      {^port, {:exit_status, 0}} ->
        {:ok, %{log_tail: tail_log(log_path)}}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit_nonzero, status}, tail_log(log_path)}

      {:EXIT, _from, reason} ->
        # Harness polling loop hit the desired terminal state and called
        # Task.shutdown/2 on us. trap_exit lets us catch the :shutdown signal
        # so the OS subprocess actually dies (Erlang ports do not propagate
        # signals on close by default).
        _ = maybe_kill_os_pid(os_pid)
        {:error, {:shutdown, reason}, tail_log(log_path)}
    after
      30_000 -> collect_port_output(port, log_io, log_path, os_pid)
    end
  end

  defp maybe_kill_os_pid(nil), do: :ok

  defp maybe_kill_os_pid(os_pid) when is_integer(os_pid) do
    System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
    Process.sleep(2_000)
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  defp tail_log(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.take(-200)
        |> Enum.join("\n")

      _ ->
        ""
    end
  end
end
