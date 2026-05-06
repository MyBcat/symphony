defmodule SymphonyElixir.Secrets.Resolver do
  @moduledoc """
  Resolves AWS Secrets Manager secrets via the `secret_exec.py` wrapper for
  per-repo secret injection (Spec 4 §2.4 / DL-003).

  Symphony declares secrets in WORKFLOW.md per repo:

      repos:
        hubspot-funnel-site:
          secrets:
            - "mybcat/integrations/api-keys/hubspot:HUBSPOT_TOKEN"
            - "mybcat/json-secret:STRIPE_KEY:secret_key"   # optional JSON field

  Each entry is `<SECRET_ID>:<ENV_VAR>[:<JSON_FIELD>]`. The resolver translates
  every entry to `secret_exec.py --secret-env <ENV_VAR>=<SECRET_ID>[:<FIELD>]`
  and writes the resolved values to `.env.symphony` in the workspace root with
  mode `0o600`. Symphony then wraps both the `after_create` hook and the
  agent's port-spawn command to source that file.

  This module never returns secret values to its caller; values flow only into
  the on-disk `.env.symphony` file (chmod 0600), and from there into the
  agent's environment via the wrapping mechanism.

  `secret_exec.py` is invoked via `python3 <path>` so the wrapper does not
  need its executable bit set on every host.
  """

  require Logger

  @default_secret_exec_path "/mnt/d_drive/repos/finances/scripts/secret_exec.py"
  @env_filename ".env.symphony"

  @type secret_ref :: String.t()
  @type secret_spec :: %{env: String.t(), secret_id: String.t(), field: String.t() | nil}
  @type opts :: keyword()

  @doc """
  The default path to `secret_exec.py` if WORKFLOW.md does not override it.
  """
  @spec default_secret_exec_path() :: String.t()
  def default_secret_exec_path, do: @default_secret_exec_path

  @doc """
  Returns the relative filename Symphony uses for the per-workspace env file.
  """
  @spec env_filename() :: String.t()
  def env_filename, do: @env_filename

  @doc """
  Parse a single `<SECRET_ID>:<ENV_VAR>[:<FIELD>]` reference into a structured
  spec. Returns `{:error, ...}` for malformed input — the caller decides how to
  surface the failure.
  """
  @spec parse_ref(secret_ref()) :: {:ok, secret_spec()} | {:error, term()}
  def parse_ref(ref) when is_binary(ref) do
    trimmed = String.trim(ref)

    cond do
      trimmed == "" ->
        {:error, {:invalid_secret_ref, :blank}}

      String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_secret_ref, :control_characters}}

      true ->
        case String.split(trimmed, ":") do
          [secret_id, env] ->
            build_spec(secret_id, env, nil, trimmed)

          [secret_id, env, field] ->
            build_spec(secret_id, env, field, trimmed)

          _ ->
            {:error, {:invalid_secret_ref, :unexpected_token_count}}
        end
    end
  end

  def parse_ref(other), do: {:error, {:invalid_secret_ref, {:not_a_string, other}}}

  @doc """
  Parse all references for a repo, collecting parse errors with the offending
  raw string so the caller can refuse dispatch with the bad entry name.
  """
  @spec parse_refs([secret_ref()]) :: {:ok, [secret_spec()]} | {:error, term()}
  def parse_refs(refs) when is_list(refs) do
    refs
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      case parse_ref(raw) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_secret_ref, raw, reason}}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      other -> other
    end
  end

  def parse_refs(_other), do: {:error, {:invalid_secrets_list, :not_a_list}}

  @doc """
  Resolve every `secret_ref` for a repo and write `.env.symphony` to the
  workspace root.

  Returns `:ok` after the file has been written and chmod'd to `0o600`. Returns
  `{:error, ...}` if parsing fails, the wrapper script is missing, or
  `secret_exec.py` exits non-zero (e.g. AWS auth failure or unknown secret).
  Secret values never appear in returned errors.

  Options:
    * `:secret_exec_path` (string)  — overrides the default wrapper path.
    * `:repo_key`         (string)  — annotates errors with the repo identity.
    * `:python_executable`(string)  — overrides `python3` lookup, used by tests.
    * `:cmd`              (function) — `(executable, args, opts) → {output, status}`
       seam used by tests to stub out subprocess invocation.
  """
  @spec write_env_file([secret_ref()], Path.t(), opts()) :: :ok | {:error, term()}
  def write_env_file(secret_refs, workspace_path, opts \\ [])

  @spec write_env_file([secret_ref()], Path.t(), opts()) :: :ok | {:error, term()}
  def write_env_file([], _workspace_path, _opts), do: :ok

  def write_env_file(secret_refs, workspace_path, opts) when is_list(secret_refs) do
    repo_key = Keyword.get(opts, :repo_key, "<unknown>")

    with {:ok, specs} <- parse_refs(secret_refs),
         {:ok, secret_exec} <- locate_secret_exec(opts),
         {:ok, python} <- locate_python(opts),
         :ok <- ensure_workspace_dir(workspace_path),
         env_file_path <- env_file_path(workspace_path),
         _ <- Logger.info(symphony_log_line("resolving secrets", repo_key, specs, env_file_path)),
         {:ok, _output} <- run_writer(secret_exec, python, specs, env_file_path, opts),
         :ok <- File.chmod(env_file_path, 0o600),
         :ok <- verify_env_file(env_file_path, specs) do
      Logger.info("Symphony secrets wrote #{@env_filename} repo=#{repo_key} count=#{length(specs)} path=#{env_file_path}")

      :ok
    else
      {:error, {:invalid_secret_ref, _raw, _reason}} = err ->
        annotate(err, repo_key)

      {:error, _reason} = err ->
        # Defense in depth: a post-write failure (e.g., chmod or verify_env_file
        # tripping after the Python writer already produced a partial file)
        # could otherwise leave a `.env.symphony` on disk with potentially
        # unsafe perms. Remove it on every error path so the caller sees a
        # clean workspace plus the structured failure tuple.
        cleanup_partial_env_file(workspace_path)
        annotate(err, repo_key)
    end
  end

  defp cleanup_partial_env_file(workspace_path) when is_binary(workspace_path) do
    _ = File.rm_rf(env_file_path(workspace_path))
    :ok
  end

  defp cleanup_partial_env_file(_workspace_path), do: :ok

  @doc """
  Verify every declared secret resolves successfully. Used at boot
  (`Application.start/2`) to refuse start-up when AWS Secrets Manager is
  inaccessible or any path is missing.

  `secrets_by_repo` is a map of `%{repo_key => [secret_ref, ...]}`. Returns
  `:ok` when every reference resolves; otherwise `{:error, [{repo_key,
  secret_ref, reason}, ...]}` listing each failing path. Secret values are
  never logged or returned.
  """
  @spec check_all(map(), opts()) :: :ok | {:error, [tuple()]}
  def check_all(secrets_by_repo, opts \\ []) when is_map(secrets_by_repo) do
    case locate_secret_exec(opts) do
      {:error, reason} ->
        {:error, [{:secret_exec_unavailable, nil, reason}]}

      {:ok, secret_exec} ->
        secrets_by_repo
        |> Enum.flat_map(fn {repo_key, refs} ->
          refs
          |> List.wrap()
          |> Enum.map(&{repo_key, &1})
        end)
        |> Enum.reduce([], fn {repo_key, ref}, errors ->
          case check_one(secret_exec, ref, opts) do
            :ok -> errors
            {:error, reason} -> [{repo_key, ref, reason} | errors]
          end
        end)
        |> case do
          [] -> :ok
          errors -> {:error, Enum.reverse(errors)}
        end
    end
  end

  @doc """
  Verify a single reference resolves. Used by `check_all/2`; exposed separately
  so callers can probe individual entries.
  """
  @spec check_one(Path.t(), secret_ref(), opts()) :: :ok | {:error, term()}
  def check_one(secret_exec, ref, opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd, &default_cmd/3)

    with {:ok, %{} = spec} <- parse_ref(ref),
         {:ok, python} <- locate_python(opts) do
      args = [secret_exec, "--secret-env", secret_env_arg(spec), "--", "true"]

      case cmd_fn.(python, args, env_safe_opts()) do
        {_output, 0} ->
          :ok

        {output, status} ->
          {:error, {:secret_exec_nonzero, status, redact_output(output, ref)}}
      end
    end
  end

  @doc """
  Return the full path to `.env.symphony` for `workspace_path`.
  """
  @spec env_file_path(Path.t()) :: Path.t()
  def env_file_path(workspace_path) when is_binary(workspace_path) do
    Path.join(workspace_path, @env_filename)
  end

  @doc """
  Wraps a shell command so that `.env.symphony` (if present in the cwd) is
  sourced into the environment before the command runs. Used for both the
  `after_create` hook and the adapter port-spawn command.
  """
  @spec wrap_command(String.t()) :: String.t()
  def wrap_command(command) when is_binary(command) do
    """
    if [ -f ./#{@env_filename} ]; then
      __symphony_xtrace=0
      case "$-" in
        *x*) __symphony_xtrace=1; set +x ;;
      esac
      set -a
      . ./#{@env_filename}
      set +a
      if [ "$__symphony_xtrace" = "1" ]; then set -x; fi
      unset __symphony_xtrace
    fi
    #{command}
    """
  end

  @doc """
  Returns the list of env-var names declared for a repo. Public so the
  scrubber and logger can show env names without ever touching values.
  """
  @spec declared_env_names([secret_ref()]) :: [String.t()]
  def declared_env_names(secret_refs) when is_list(secret_refs) do
    secret_refs
    |> Enum.map(fn raw ->
      case parse_ref(raw) do
        {:ok, %{env: env}} -> env
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ------- internal helpers -------

  defp build_spec(secret_id, env, field, raw) do
    cond do
      String.trim(secret_id) == "" ->
        {:error, {:invalid_secret_ref, :blank_secret_id, raw}}

      String.trim(env) == "" ->
        {:error, {:invalid_secret_ref, :blank_env_name, raw}}

      not env_name_safe?(env) ->
        {:error, {:invalid_secret_ref, :unsafe_env_name, raw}}

      not secret_id_safe?(secret_id) ->
        {:error, {:invalid_secret_ref, :unsafe_secret_id, raw}}

      not field_safe?(field) ->
        {:error, {:invalid_secret_ref, :unsafe_field, raw}}

      true ->
        {:ok,
         %{
           env: String.trim(env),
           secret_id: String.trim(secret_id),
           field: normalize_optional(field)
         }}
    end
  end

  defp env_name_safe?(env) when is_binary(env) do
    String.match?(env, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
  end

  defp env_name_safe?(_), do: false

  defp secret_id_safe?(value) when is_binary(value) do
    not String.match?(value, ~r/[\s'"`$;|&<>\\]/)
  end

  defp secret_id_safe?(_), do: false

  defp field_safe?(nil), do: true
  defp field_safe?(""), do: true
  defp field_safe?(value) when is_binary(value), do: secret_id_safe?(value)
  defp field_safe?(_), do: false

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      other -> other
    end
  end

  defp locate_secret_exec(opts) do
    case Keyword.get(opts, :secret_exec_path) || @default_secret_exec_path do
      nil ->
        {:error, {:secret_exec_path_missing, @default_secret_exec_path}}

      path when is_binary(path) ->
        if File.regular?(path) do
          {:ok, path}
        else
          {:error, {:secret_exec_path_missing, path}}
        end

      other ->
        {:error, {:secret_exec_path_invalid, other}}
    end
  end

  defp locate_python(opts) do
    explicit = Keyword.get(opts, :python_executable)

    if is_binary(explicit) and File.regular?(explicit) do
      {:ok, explicit}
    else
      case System.find_executable("python3") || System.find_executable("python") do
        nil -> {:error, :python_not_found}
        path -> {:ok, path}
      end
    end
  end

  defp ensure_workspace_dir(workspace_path) do
    cond do
      not is_binary(workspace_path) ->
        {:error, {:invalid_workspace_path, workspace_path}}

      not File.dir?(workspace_path) ->
        {:error, {:workspace_missing, workspace_path}}

      true ->
        :ok
    end
  end

  defp run_writer(secret_exec, python, specs, env_file_path, opts) do
    cmd_fn = Keyword.get(opts, :cmd, &default_cmd/3)

    secret_env_args = Enum.flat_map(specs, fn spec -> ["--secret-env", secret_env_arg(spec)] end)
    env_names = Enum.map(specs, & &1.env)

    args =
      [secret_exec | secret_env_args] ++
        ["--", python, "-c", writer_script(), env_file_path | env_names]

    case cmd_fn.(python, args, env_safe_opts()) do
      {output, 0} ->
        if output != "" do
          safe_output = redact_output(output, env_names_for_redaction(specs))

          Logger.debug("secret_exec.py wrapper output (redacted): #{safe_output}")
        end

        {:ok, output}

      {output, status} ->
        {:error, {:secret_resolution_failed, status, redact_output(output, env_names_for_redaction(specs))}}
    end
  end

  defp secret_env_arg(%{env: env, secret_id: secret_id, field: nil}), do: "#{env}=#{secret_id}"

  defp secret_env_arg(%{env: env, secret_id: secret_id, field: field}) when is_binary(field) do
    "#{env}=#{secret_id}:#{field}"
  end

  # The Python writer runs INSIDE secret_exec.py's child process, so it sees
  # resolved secret values via os.environ. It writes a single-quoted .env file
  # to disk at argv[1], one KEY='value' line per env name in argv[2:]. It writes
  # to a temp file opened at 0600 and atomically replaces the target, so there
  # is no default-umask window where secret values sit in a world-readable file.
  # Single quoting keeps the file parseable by `set -a; . ./.env.symphony; set
  # +a` and makes special characters safe.
  defp writer_script do
    """
    import os, sys
    env_path = sys.argv[1]
    keys = sys.argv[2:]
    tmp_path = env_path + ".tmp." + str(os.getpid())


    def squote(value):
        return "'" + value.replace("'", "'\\\\''") + "'"


    try:
        fd = os.open(tmp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            for key in keys:
                value = os.environ.get(key, "")
                fh.write(key + "=" + squote(value) + "\\n")

        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, env_path)
        os.chmod(env_path, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
        raise
    """
  end

  defp verify_env_file(env_file_path, specs) do
    case File.stat(env_file_path) do
      {:ok, %File.Stat{mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0 do
          verify_env_file_keys(env_file_path, specs)
        else
          {:error, {:env_file_permissions_unsafe, env_file_path, mode}}
        end

      {:error, reason} ->
        {:error, {:env_file_missing, env_file_path, reason}}
    end
  end

  defp verify_env_file_keys(env_file_path, specs) do
    expected = MapSet.new(Enum.map(specs, & &1.env))

    case File.read(env_file_path) do
      {:ok, content} ->
        present =
          content
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case String.split(line, "=", parts: 2) do
              [key | _] -> [key]
              _ -> []
            end
          end)
          |> MapSet.new()

        case MapSet.difference(expected, present) |> MapSet.to_list() do
          [] -> :ok
          missing -> {:error, {:env_file_missing_keys, missing}}
        end

      {:error, reason} ->
        {:error, {:env_file_unreadable, env_file_path, reason}}
    end
  end

  defp env_names_for_redaction(specs) do
    Enum.map_join(specs, " ", & &1.env)
  end

  # Defense-in-depth scrub of stderr/stdout from `secret_exec.py`. The wrapper
  # already replaces resolved values with `[REDACTED_SECRET]` before printing,
  # but we apply the regex scrubber on top so any AWS error payload that
  # happens to embed a secret-shaped substring (auth tokens echoed back by
  # AWS, etc.) does not survive into Symphony's disk log.
  defp redact_output(output, _ref) when is_binary(output) do
    output
    |> String.slice(0, 1024)
    |> SymphonyElixir.Secrets.Scrubber.scrub()
  end

  defp redact_output(output, _ref), do: inspect(output)

  defp annotate({:error, reason}, repo_key) do
    {:error, {:secret_resolution_failed, repo_key, reason}}
  end

  defp env_safe_opts do
    [stderr_to_stdout: true]
  end

  defp default_cmd(executable, args, opts) when is_list(args) do
    System.cmd(executable, args, opts)
  end

  defp symphony_log_line(action, repo_key, specs, env_file_path) do
    env_names = Enum.map_join(specs, ",", & &1.env)
    secret_paths = Enum.map_join(specs, ",", & &1.secret_id)

    "Symphony secrets #{action} repo=#{repo_key} env_names=#{env_names} secret_paths=#{secret_paths} env_file=#{env_file_path}"
  end
end
