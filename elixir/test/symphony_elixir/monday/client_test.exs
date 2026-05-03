defmodule SymphonyElixir.Monday.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Client

  setup do
    fixture = File.read!("test/fixtures/monday/items_page_response.json") |> Jason.decode!()
    {:ok, fixture: fixture}
  end

  describe "graphql/3" do
    test "issues request with auth header and JSON body", %{fixture: fixture} do
      mock_req = fn url, opts ->
        assert url == "https://api.monday.com/v2"
        assert {"Authorization", "test-token"} in opts[:headers]
        assert {"Content-Type", "application/json"} in opts[:headers]
        body = opts[:json]
        assert body["query"] =~ "items_page"
        {:ok, %Req.Response{status: 200, body: fixture}}
      end

      assert {:ok, response} =
               Client.graphql("query Foo { items_page { items { id } } }", %{},
                 req_fun: mock_req,
                 api_token: "test-token"
               )

      assert response["data"]["boards"] != nil
    end

    test "returns {:error, :auth_failed} on 401" do
      mock_req = fn _url, _opts ->
        {:ok, %Req.Response{status: 401, body: %{"error" => "Unauthorized"}}}
      end

      assert {:error, :auth_failed} =
               Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "bad")
    end

    test "returns {:error, :rate_limited} on 429" do
      mock_req = fn _url, _opts ->
        {:ok, %Req.Response{status: 429, body: %{"error" => "Complexity"}}}
      end

      assert {:error, :rate_limited} =
               Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "x")
    end

    test "returns {:error, :timeout} on transport timeout" do
      mock_req = fn _url, _opts -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, :timeout} =
               Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "x")
    end

    test "returns {:error, {:graphql_errors, list}} when response has errors" do
      mock_req = fn _url, _opts ->
        {:ok,
         %Req.Response{
           status: 200,
           body: %{"errors" => [%{"message" => "Field not found"}]}
         }}
      end

      assert {:error, {:graphql_errors, [%{"message" => "Field not found"}]}} =
               Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "x")
    end
  end
end
