defmodule MCPServer.Plug do
  @moduledoc """
  Provides a Plug for integrating an MCP (Model Context Protocol) server
  into a Plug or Phoenix pipeline.

  This Plug handles incoming HTTP requests, parses them as JSON-RPC 2.0 messages
  using the standard Elixir `JSON` module (requires Elixir ~> 1.18),
  and dispatches them to a dedicated `MCPServer.Connection` GenServer instance
  that is started when this Plug is initialized.
  """
  import Plug.Conn
  require Logger

  alias MCPServer.Connection

  @behaviour Plug

  # No default_opts needed for json_parser anymore

  @impl Plug
  def init(opts) do
    # Validate and store options. Example: ensure :mcp_handler is provided.
    mcp_handler_module = Keyword.fetch!(opts, :mcp_handler)
    mcp_handler_opts = Keyword.get(opts, :mcp_handler_opts, [])

    # Start the Connection GenServer and store its PID in the options.
    # This PID will be used by call/2 to dispatch requests to the correct GenServer process.
    case Connection.start_link(mcp_handler_module, mcp_handler_opts) do
      {:ok, pid} ->
        Keyword.put(opts, :mcp_connection_pid, pid)
      {:error, reason} ->
        raise "Failed to start MCPServer.Connection: #{inspect(reason)}"
    end
  end

  @impl Plug
  def call(conn, opts) do
    mcp_connection_pid = Keyword.fetch!(opts, :mcp_connection_pid)

    # Only process POST requests
    if conn.method == "POST" do
      # Read and parse the JSON body
      # {:ok, body, conn} or {:error, reason, conn} or {:more, partial_body, conn}
      case Plug.Conn.read_body(conn) do
        {:ok, body_binary, conn} ->
          parse_and_dispatch_body(conn, body_binary, mcp_connection_pid, opts)
        {:error, reason, conn} -> # Simplified error handling for read_body
          Logger.error("[MCPServer.Plug] Error reading request body: #{inspect(reason)}")
          # Map common reasons to JSON-RPC errors, or use a generic one
          {code, message} =
            case reason do
              :timeout -> {-32000, "Request timeout reading body"}
              :too_large -> {-32000, "Request body too large"}
              :bad_encoding -> {-32700, "Parse error: Invalid encoding"}
              :closed -> {-32000, "Request body error: Connection closed prematurely"}
              _ -> {-32000, "Server error reading request body: #{reason}"}
            end
          send_error_response(conn, nil, code, message)
        {:more, _partial_body, _conn} ->
          # This case should ideally be handled by Plug or the adapter (e.g. by returning :too_large eventually)
          # For now, treat as an internal server error as we don't support chunked/streaming MCP requests directly here.
          send_error_response(conn, nil, -32000, "Server error: Incomplete request body (streaming not supported for MCP)")
      end
    else
      # Method not allowed for non-POST requests
      conn
      |> put_resp_header("allow", "POST")
      |> send_resp(405, "Method Not Allowed")
    end
  end

  defp parse_and_dispatch_body(conn, body_binary, mcp_connection_pid, _opts) do
    case JSON.decode(body_binary) do
      {:ok, json_rpc_request} when is_map(json_rpc_request) ->
        if Map.get(json_rpc_request, "jsonrpc") == "2.0" && is_binary(Map.get(json_rpc_request, "method")) do
          plug_details = %{
            remote_ip: conn.remote_ip,
            request_path: conn.request_path,
            method: conn.method,
            headers: conn.req_headers
          }

          case Connection.process_request(mcp_connection_pid, plug_details, json_rpc_request) do
            {:ok, mcp_response_payload} ->
              send_mcp_response(conn, mcp_response_payload)
            {:error, mcp_error_payload} ->
              send_mcp_response(conn, mcp_error_payload)
          end
        else
          send_error_response(conn, Map.get(json_rpc_request, "id"), -32600, "Invalid Request: Malformed JSON-RPC structure")
        end
      _other ->
        send_error_response(conn, nil, -32700, "Parse error: Invalid JSON")
    end
  end

  # --- Original send_mcp_response clauses ---
  defp send_mcp_response(conn, %{"id" => nil, "error" => _error_payload} = mcp_response_payload) do
    Logger.debug("[MCPServer.Plug] Sending error response for notification (no id): #{inspect(mcp_response_payload)}")
    conn
    |> put_resp_content_type("application/json-rpc")
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  defp send_mcp_response(conn, %{"id" => request_id, "result" => _result_payload} = mcp_response_payload) when not is_nil(request_id) do
    Logger.debug("[MCPServer.Plug] Sending success response for ID #{inspect(request_id)}: #{inspect(mcp_response_payload)}")
    conn
    |> put_resp_content_type("application/json-rpc")
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  defp send_mcp_response(conn, %{"id" => request_id, "error" => _error_payload} = mcp_response_payload) when not is_nil(request_id) do
    Logger.debug("[MCPServer.Plug] Sending error response for ID #{inspect(request_id)}: #{inspect(mcp_response_payload)}")
    conn
    |> put_resp_content_type("application/json-rpc")
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  defp send_mcp_response(conn, %{"id" => nil} = mcp_response_payload) do
    Logger.debug("[MCPServer.Plug] Sending generic response for notification (id: null) or unexpected null id case: #{inspect(mcp_response_payload)}")
    conn
    |> put_resp_content_type("application/json-rpc")
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  # Fallback if none of the above matched (should ideally not be reached if payloads are correct)
  defp send_mcp_response(conn, mcp_response_payload) do
    Logger.error("[MCPServer.Plug] Fallback send_mcp_response. This indicates an issue. Payload: #{inspect(mcp_response_payload)}")
    send_fallback_error(conn, mcp_response_payload) # Call the existing fallback
  end

  defp send_fallback_error(conn, mcp_response_payload) do
    Logger.warning("[MCPServer.Plug] Sending fallback error due to send_mcp_response mismatch.")
    fallback_error = %{
      "jsonrpc" => "2.0",
      "id" => Map.get(mcp_response_payload, "id", Map.get(mcp_response_payload, :id, nil)),
      "error" => %{
        "code" => -32000,
        "message" => "Internal server error: Malformed response payload for sending"
      }
    }
    conn
    |> put_resp_content_type("application/json-rpc")
    |> send_resp(500, JSON.encode!(fallback_error))
  end

  defp send_error_response(conn, request_id, code, message) do
    error_payload = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{
        "code" => code,
        "message" => message
      }
    }
    send_mcp_response(conn, error_payload) # This will now go through the main send_mcp_response logic
  end
end
