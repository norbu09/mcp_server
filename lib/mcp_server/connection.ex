defmodule MCPServer.Connection do
  @moduledoc """
  A GenServer that manages the state and lifecycle of a single MCP connection.

  It interacts with a user-defined MCP handler module (which adopts the
  `MCPServer.Implementation` behaviour) to process incoming MCP requests.
  """
  use GenServer

  # alias MCPServer.Implementation # Removed unused alias
  alias MCPServer.Context

  # Define the state for this GenServer
  # The user's MCP implementation module
  defstruct handler_module: nil,
            # The state of the user's MCP implementation
            handler_state: nil,
            # conn_abstraction: %{}, # Represents context for handler callbacks (TODO)
            client_capabilities: nil,
            server_capabilities: nil
            # plug_details: nil # This field will be part of the Context struct, not GenServer state directly

  # --- Public API ---

  @doc """
  Starts the Connection GenServer.

  `handler_module` is the user's module implementing `MCPServer.Implementation`.
  `handler_opts` are the options passed to the handler module's `init/1` callback.
  """
  def start_link(handler_module, handler_opts, name \\ nil) do
    GenServer.start_link(__MODULE__, {handler_module, handler_opts}, name: name)
  end

  @doc """
  Processes a JSON-RPC request map, including details from the Plug connection.
  """
  def process_request(pid, json_rpc_request, plug_details) do
    GenServer.call(pid, {:process_request, json_rpc_request, plug_details})
  end

  # --- GenServer Callbacks ---

  @impl GenServer
  def init({handler_module, handler_opts}) do
    # Initialize the user's MCP handler
    case handler_module.init(handler_opts) do
      {:ok, initial_handler_state} ->
        # plug_conn details are not available at global init, only per-request
        context = %Context{connection_pid: self(), client_capabilities: nil, plug_conn: nil, request_id: nil}
        case handler_module.server_capabilities(context, initial_handler_state) do
          {:ok, server_caps, state_after_caps} ->
            {:ok,
             %__MODULE__{
               handler_module: handler_module,
               handler_state: state_after_caps,
               server_capabilities: server_caps,
               client_capabilities: nil # Explicitly nil until mcp/initialize
             }}

          {:error, error_obj, _state_after_caps} ->
            # Failed to get server capabilities, this is a critical init failure.
            # Consider if we should stop or proceed with no advertised capabilities.
            # For now, let's stop as capabilities are fundamental.
            {:stop, {:handler_init_failed, :server_capabilities_error, error_obj}}

          other ->
            {:stop, {:handler_init_failed, :bad_server_capabilities_return, other}}
        end

      {:stop, reason} ->
        {:stop, {:handler_init_failed, reason}}

      other ->
        # Handler init returned an unexpected value
        {:stop, {:handler_init_failed, :bad_return, other}}
    end
  end

  @impl GenServer
  def handle_call({:process_request, json_rpc_request, plug_details}, _from, state) do
    # Extract method, params, and id from the JSON-RPC request
    # MCP methods are namespaced, e.g., "mcp/listResources"
    # We need to map these to our behaviour callbacks.

    method = Map.get(json_rpc_request, "method")
    # Default to empty map if no params
    params = Map.get(json_rpc_request, "params", %{})
    # Can be nil for notifications
    request_id = Map.get(json_rpc_request, "id")

    # Create the context for the handler call
    context = %Context{
      connection_pid: self(),
      request_id: request_id,
      client_capabilities: state.client_capabilities,
      plug_conn: plug_details # Use the passed plug_details here
    }

    response_tuple =
      case method do
        # --- Standard MCP Methods ---
        "mcp/initialize" ->
          # The "initialize" request in MCP is special. It's where client capabilities are sent.
          # It expects server capabilities in return.
          client_caps_param = Map.get(params, "capabilities", %{})
          # For mcp/initialize, the context passed to handle_client_capabilities
          # should not yet have the client_capabilities being set from *this* request.
          # It uses the ones already in the GenServer state (which is nil before first initialize).
          # The new client_caps are then stored in GenServer state *after* this call.
          init_context = %Context{
            connection_pid: self(),
            request_id: request_id,
            client_capabilities: state.client_capabilities, # existing (nil on first call)
            plug_conn: plug_details
          }
          handle_mcp_initialize(init_context, client_caps_param, request_id, state)

        "mcp/listResources" ->
          state.handler_module.list_resources(context, params, state.handler_state)

        "mcp/getResource" ->
          # Assuming params include an "id" for the resource
          # Basic extraction, might need more robust parsing
          resource_id = Map.get(params, "id")

          if resource_id do
            state.handler_module.get_resource(context, resource_id, params, state.handler_state)
          else
            # Missing resource id for getResource
            {:error,
             %{code: -32602, message: "Invalid params: missing resource id for mcp/getResource"},
             state.handler_state}
          end

        "mcp/listPrompts" ->
          state.handler_module.list_prompts(context, params, state.handler_state)

        "mcp/getPrompt" ->
          prompt_id = Map.get(params, "id")

          if prompt_id do
            state.handler_module.get_prompt(context, prompt_id, params, state.handler_state)
          else
            {:error,
             %{code: -32602, message: "Invalid params: missing prompt id for mcp/getPrompt"},
             state.handler_state}
          end

        "mcp/listTools" ->
          state.handler_module.list_tools(context, params, state.handler_state)

        "mcp/executeTool" ->
          # Or just "id" - check MCP spec carefully for tool execution params
          tool_id = Map.get(params, "toolId")
          # Accommodate common variations
          tool_params = Map.get(params, "toolInputs", Map.get(params, "params"))

          if tool_id && tool_params do
            state.handler_module.execute_tool(context, tool_id, tool_params, state.handler_state)
          else
            {:error,
             %{
               code: -32602,
               message: "Invalid params: missing toolId or toolInputs for mcp/executeTool"
             }, state.handler_state}
          end

        # TODO: Add more MCP methods like shutdown, etc.

        # Method was not present or was nil
        nil ->
          {:error, %{code: -32600, message: "Invalid Request: method not specified"},
           state.handler_state}

        _unknown_method ->
          # Default for unknown methods
          error_obj = %{code: -32601, message: "Method not found: #{method}"}

          # Check if it might be a notification (no id) - though MCP spec implies most calls expect response.
          # For now, assume all unknown methods are errors if they have an ID.
          {:error, error_obj, state.handler_state}
      end

    # Process the response tuple from the handler callback
    case response_tuple do
      {:reply, result_data, new_handler_state} ->
        response_payload = %{jsonrpc: "2.0", result: result_data, id: request_id}
        {:reply, response_payload, %{state | handler_state: new_handler_state}}

      {:error, error_object, new_handler_state} ->
        response_payload = %{jsonrpc: "2.0", error: error_object, id: request_id}
        {:reply, response_payload, %{state | handler_state: new_handler_state}}

      # Add other cases like :noreply, :stop if handler can return them from these contexts
      _other ->
        # Handler returned an unexpected value for a request that expects reply/error
        default_error = %{
          code: -32000,
          message: "Internal server error: Handler returned unexpected value"
        }

        response_payload = %{jsonrpc: "2.0", error: default_error, id: request_id}
        # Keep the original handler state as we don't know if it's valid
        {:reply, response_payload, state}
    end
  end

  # Handle the mcp/initialize method specifically
  defp handle_mcp_initialize(context_for_handler, client_capabilities_param, request_id, state) do
    # 1. Inform the handler about client capabilities using the passed context
    case state.handler_module.handle_client_capabilities(context_for_handler, client_capabilities_param, state.handler_state) do
      {:ok, state_after_client_caps} ->
        response_payload = %{
          jsonrpc: "2.0",
          result: %{"capabilities" => state.server_capabilities},
          id: request_id
        }
        # Update GenServer state with the NEW client_capabilities from this request
        new_genserver_state = %{state | handler_state: state_after_client_caps, client_capabilities: client_capabilities_param}
        {:reply, response_payload, new_genserver_state}

      {:error, error_obj, state_after_client_caps_error} ->
        # Handler failed to process client capabilities
        response_payload = %{jsonrpc: "2.0", error: error_obj, id: request_id}
        # Store new state even on error
        new_genserver_state = %{state | handler_state: state_after_client_caps_error}
        {:reply, response_payload, new_genserver_state}

      _other ->
        default_error = %{
          code: -32000,
          message:
            "Internal server error: Handler returned unexpected value from handle_client_capabilities"
        }

        response_payload = %{jsonrpc: "2.0", error: default_error, id: request_id}
        # Keep original state
        {:reply, response_payload, state}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    # Call the handler's terminate callback for cleanup, if handler_module is set
    if state.handler_module do
      # plug_conn details are not directly available from Plug during terminate,
      # as this is a GenServer lifecycle callback, not tied to a specific HTTP request.
      # So, plug_conn remains nil here.
      context = %Context{
        connection_pid: self(),
        request_id: nil, # No specific request ID for terminate
        client_capabilities: state.client_capabilities,
        plug_conn: nil
      }
      state.handler_module.terminate(reason, context, state.handler_state)
    end

    :ok
  end
end
