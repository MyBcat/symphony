defmodule SymphonyElixir.Monday.Client do
  @moduledoc """
  Monday.com GraphQL transport. All requests go to the configured endpoint with
  the configured api_token. Returns normalized error tuples for common failure
  modes; callers do not parse HTTP statuses directly.
  """

  alias SymphonyElixir.Config

  @default_endpoint "https://api.monday.com/v2"
  @default_timeout_ms 15_000

  @type error ::
          :auth_failed
          | :rate_limited
          | :timeout
          | {:http, non_neg_integer()}
          | {:graphql_errors, [map()]}
          | {:transport, term()}

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def graphql(query, variables, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, endpoint_from_config())
    api_token = Keyword.get(opts, :api_token, api_token_from_config())
    req_fun = Keyword.get(opts, :req_fun, &Req.post/2)

    headers = [
      {"Authorization", api_token},
      {"Content-Type", "application/json"},
      {"API-Version", "2024-10"}
    ]

    body = %{"query" => query, "variables" => variables || %{}}

    endpoint
    |> req_fun.(headers: headers, json: body, receive_timeout: @default_timeout_ms)
    |> handle_response()
  end

  defp handle_response({:ok, %{status: 200, body: body}}), do: handle_ok_body(body)
  defp handle_response({:ok, %{status: 401}}), do: {:error, :auth_failed}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :auth_failed}
  defp handle_response({:ok, %{status: 429}}), do: {:error, :rate_limited}
  defp handle_response({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp handle_response({:error, %Req.TransportError{reason: :timeout}}), do: {:error, :timeout}
  defp handle_response({:error, reason}), do: {:error, {:transport, reason}}

  defp handle_ok_body(%{"errors" => errors}) when is_list(errors) and errors != [],
    do: {:error, {:graphql_errors, errors}}

  defp handle_ok_body(body) when is_map(body), do: {:ok, body}

  defp endpoint_from_config do
    case Config.settings!() do
      %{tracker: %{endpoint: endpoint}} when is_binary(endpoint) and endpoint != "" -> endpoint
      _ -> @default_endpoint
    end
  end

  defp api_token_from_config do
    case Config.settings!() do
      %{tracker: %{api_token: token}} when is_binary(token) -> token
      _ -> nil
    end
  end
end
