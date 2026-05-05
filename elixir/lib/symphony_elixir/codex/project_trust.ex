defmodule SymphonyElixir.Codex.ProjectTrust do
  @moduledoc """
  Ensures a Symphony workspace is recorded as a `trusted` project in
  `~/.codex/config.toml` so the Codex CLI app-server's JSON-RPC interface
  (`remoteControl`) is enabled for that workspace.

  Background (SYM-11923259980): when the Codex CLI app-server starts inside
  a workspace whose `.codex/` directory has not been added to
  `~/.codex/config.toml`'s `[projects]` table, Codex emits a `configWarning`
  followed by `remoteControl/status/changed` with `status=disabled`, and
  then never responds to the JSON-RPC `initialize` request. The Codex
  adapter therefore times out at `:response_timeout` after
  `codex.read_timeout_ms` extended by the noisy startup notifications.

  This module writes (or updates) the per-workspace
  `[projects."<canonical-path>"]` block with `trust_level = "trusted"`. The
  caller (`Codex.Adapter.start_session/2`) is responsible for canonicalising
  the workspace path and asserting it sits under the configured
  `workspace.root` BEFORE invoking this module — the SYM-11923259980
  acceptance constraint requires "do NOT auto-trust arbitrary paths — only
  the Symphony workspace root."

  The config-file path is overridable via the `SYMPHONY_CODEX_CONFIG_TOML`
  env var, which the test suite uses to redirect writes away from the
  developer's real `~/.codex/config.toml`.
  """

  require Logger

  @config_path_env "SYMPHONY_CODEX_CONFIG_TOML"
  @trusted_value ~s("trusted")

  @spec ensure_trusted(Path.t()) :: :ok | {:error, term()}
  def ensure_trusted(workspace) when is_binary(workspace) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace, :control_chars}}

      true ->
        do_ensure_trusted(workspace)
    end
  end

  defp do_ensure_trusted(workspace) do
    config_path = config_path()

    with :ok <- File.mkdir_p(Path.dirname(config_path)),
         {:ok, content} <- read_or_init(config_path),
         {updated, status} <- upsert_trust(content, workspace) do
      case status do
        :unchanged ->
          :ok

        op when op in [:added, :updated] ->
          atomic_write(config_path, updated)
      end
    end
  end

  @doc """
  Resolve the path to the Codex CLI config.toml that this module manages.

  Defaults to `~/.codex/config.toml`; tests override with the
  `SYMPHONY_CODEX_CONFIG_TOML` env var.
  """
  @spec config_path() :: Path.t()
  def config_path do
    case System.get_env(@config_path_env) do
      override when is_binary(override) and override != "" -> override
      _ -> Path.expand("~/.codex/config.toml")
    end
  end

  @doc """
  Pure transform: given the current TOML content and a workspace path,
  return `{updated_content, status}` where status is `:unchanged | :added
  | :updated`. Exposed for test coverage of the parsing logic without
  touching the filesystem.
  """
  @spec upsert_trust(String.t(), Path.t()) ::
          {String.t(), :added | :updated | :unchanged}
  def upsert_trust(content, workspace) when is_binary(content) and is_binary(workspace) do
    header = section_header(workspace)
    lines = String.split(content, "\n")

    case find_section(lines, header) do
      nil ->
        {append_section(content, header), :added}

      {start_idx, end_idx} ->
        case section_lines_status(lines, start_idx, end_idx) do
          :already_trusted ->
            {content, :unchanged}

          {:replace_trust, line_idx} ->
            updated_lines = List.replace_at(lines, line_idx, ~s(trust_level = #{@trusted_value}))
            {Enum.join(updated_lines, "\n"), :updated}

          :insert_trust ->
            updated_lines =
              List.insert_at(lines, start_idx + 1, ~s(trust_level = #{@trusted_value}))

            {Enum.join(updated_lines, "\n"), :updated}
        end
    end
  end

  defp read_or_init(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:read_failed, path, reason}}
    end
  end

  defp section_header(workspace), do: ~s([projects."#{toml_escape(workspace)}"])

  defp toml_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
  end

  defp find_section(lines, header) do
    indexed = Enum.with_index(lines)

    case Enum.find(indexed, fn {line, _idx} -> String.trim(line) == header end) do
      nil -> nil
      {_line, start_idx} -> {start_idx, next_section_index(lines, start_idx + 1)}
    end
  end

  defp next_section_index(lines, from_idx) do
    total = length(lines)

    cond do
      from_idx >= total ->
        total

      true ->
        from_idx..(total - 1)
        |> Enum.reduce_while(total, fn idx, acc ->
          line = Enum.at(lines, idx) || ""

          if section_header_line?(line) do
            {:halt, idx}
          else
            {:cont, acc}
          end
        end)
    end
  end

  defp section_header_line?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]")
  end

  defp section_lines_status(lines, start_idx, end_idx) do
    body_indices = Range.new(start_idx + 1, end_idx - 1, 1)

    Enum.reduce_while(body_indices, :insert_trust, fn idx, acc ->
      line = Enum.at(lines, idx) || ""

      case classify_trust_line(line) do
        :no_match -> {:cont, acc}
        :already_trusted -> {:halt, :already_trusted}
        :other_trust_value -> {:halt, {:replace_trust, idx}}
      end
    end)
  end

  defp classify_trust_line(line) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(~r/^trust_level\s*=\s*"trusted"\s*(#.*)?$/, trimmed) ->
        :already_trusted

      Regex.match?(~r/^trust_level\s*=/, trimmed) ->
        :other_trust_value

      true ->
        :no_match
    end
  end

  defp append_section(content, header) do
    block = header <> "\n" <> ~s(trust_level = #{@trusted_value}) <> "\n"

    cond do
      content == "" ->
        block

      String.ends_with?(content, "\n\n") ->
        content <> block

      String.ends_with?(content, "\n") ->
        content <> "\n" <> block

      true ->
        content <> "\n\n" <> block
    end
  end

  defp atomic_write(path, content) do
    tmp_path = path <> ".symphony.tmp"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp_path)
        {:error, {:write_failed, path, reason}}
    end
  end
end
