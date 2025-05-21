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

  @behaviour Plug

  # No default_opts needed for json_parser anymore

  @impl Plug
  def init(opts) do
    # Removed json_parser from config merging
    mcp_handler_module = Keyword.get(opts, :mcp_handler)
    mcp_handler_opts = Keyword.get(opts, :mcp_handler_opts, [])

    unless mcp_handler_module do
      raise ArgumentError, ":mcp_handler option is required for MCPServer.Plug"
    end

    unless is_atom(mcp_handler_module) do
      raise ArgumentError, ":mcp_handler must be a module"
    end

    case MCPServer.Connection.start_link(mcp_handler_module, mcp_handler_opts) do
      {:ok, pid} ->
        # Store the pid in the options that Plug.call/2 will receive.
        # opts here is the original opts passed to init.
        # We return a new keyword list that becomes the 'opts' for call/2.
        Keyword.put(opts, :mcp_connection_pid, pid)

      {:error, reason} ->
        raise "Failed to start MCPServer.Connection: #{inspect(reason)}"
    end
  end

  @impl Plug
  def call(conn, opts) do
    mcp_connection_pid = Keyword.fetch!(opts, :mcp_connection_pid)
    # json_parser is no longer fetched from opts

    if conn.method == "POST" do
      handle_post_request(conn, mcp_connection_pid)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(405, "Method Not Allowed. Only POST is supported for MCP.")
    end
  end

  # Removed json_parser argument
  defp handle_post_request(conn, mcp_connection_pid) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn_after_read_body} ->
        parse_and_dispatch_body(conn, body, mcp_connection_pid)

      {:error, :timeout} ->
        send_mcp_error_response(conn, nil, %{code: -32000, message: "Request body timeout"})

      {:error, reason} ->
        send_mcp_error_response(conn, nil, %{
          code: -32000,
          message: "Failed to read request body: #{reason}"
        })
    end
  end

  # Removed json_parser argument
  defp parse_and_dispatch_body(conn, body, mcp_connection_pid) do
    case JSON.decode(body) do
      {:ok, json_rpc_request} ->
        if is_map(json_rpc_request) && Map.has_key?(json_rpc_request, "method") do
          # Extract relevant details from Plug.Conn
          plug_details = %{
            remote_ip: conn.remote_ip,
            request_path: conn.request_path,
            method: conn.method,
            headers: conn.req_headers
          }
          mcp_response_payload = MCPServer.Connection.process_request(mcp_connection_pid, json_rpc_request, plug_details)
          send_mcp_response(conn, mcp_response_payload)
        else
          send_mcp_error_response(conn, Map.get(json_rpc_request, "id"), %{
            code: -32600,
            message: "Invalid Request"
          })
        end

      {:error, _json_error} ->
        send_mcp_error_response(conn, nil, %{code: -32700, message: "Parse error"})
    end
  end

  # --- Helper functions to send JSON-RPC responses ---

  # Removed json_parser argument
  defp send_mcp_response(conn, %{"id" => nil, "error" => _} = mcp_response_payload) do
    conn
    |> put_resp_content_type("application/json")
    # Using JSON directly
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  # Removed json_parser argument
  defp send_mcp_response(conn, %{"id" => request_id, "result" => _} = mcp_response_payload)
       when not is_nil(request_id) do
    conn
    |> put_resp_content_type("application/json")
    # Using JSON directly
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  # Removed json_parser argument
  defp send_mcp_response(conn, %{"id" => request_id, "error" => _} = mcp_response_payload)
       when not is_nil(request_id) do
    conn
    |> put_resp_content_type("application/json")
    # Using JSON directly
    |> send_resp(200, JSON.encode!(mcp_response_payload))
  end

  # Removed json_parser argument
  defp send_mcp_response(conn, %{"id" => nil} = _mcp_notification_ack_or_error_without_id) do
    send_resp(conn, 204, "")
  end

  # Removed json_parser argument
  defp send_mcp_error_response(conn, request_id, error_details_for_transport_issue) do
    response_payload = %{jsonrpc: "2.0", error: error_details_for_transport_issue, id: request_id}

    conn
    |> put_resp_content_type("application/json")
    # Using JSON directly
    |> send_resp(200, JSON.encode!(response_payload))
  end
end
