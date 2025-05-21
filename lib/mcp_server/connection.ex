defmodule MCPServer.Connection do
  @moduledoc """
  A GenServer that manages the state and lifecycle of a single MCP connection.

  It interacts with a user-defined MCP handler module (which adopts the
  `MCPServer.Implementation` behaviour) to process incoming MCP requests.
  """
  use GenServer
  require Logger # Added Logger

  # alias MCPServer.Implementation # Removed unused alias
  alias MCPServer.Context

  @notification_methods [] # Define as empty list for now
  @timeout 5000 # Default timeout for GenServer calls

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
  def process_request(pid, conn_details_map, request_body_map) do
    try do
      # If handle_call returns {:reply, payload_for_client, _new_state},
      # GenServer.call returns payload_for_client.
      # This payload_for_client can be a success map or an error map (from error_resp in handle_call).
      payload_from_genserver = GenServer.call(pid, {:process_request, conn_details_map, request_body_map}, @timeout)
      {:ok, payload_from_genserver} # Plug expects {:ok, payload} for successful processing by Connection
    rescue
      e -> # Catches GenServer crashes or timeouts
        Logger.error("[MCPServer.Connection] GenServer.call failed: #{inspect(e)}")
        # Try to get the original request ID if possible, for the error response
        original_request_id =
          if is_map(request_body_map) do
            Map.get(request_body_map, "id", Map.get(request_body_map, :id)) # check string then atom key
          else
            nil
          end

        error_payload = %{
          "jsonrpc" => "2.0",
          "id" => original_request_id,
          "error" => %{
            "code" => -32000, # Generic server error for GenServer failure
            "message" => "Internal server error: #{e.__struct__}" # Just the error type for security
          }
        }
        # This signifies that the Connection itself had an issue, not an application-level JSON-RPC error.
        {:error, error_payload} # Plug expects {:error, payload} if Plug itself cannot get a response from Connection
    end
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
  def handle_call({:process_request, conn_details_map, request_body_map}, _from, state) do
    Logger.debug("[Connection.handle_call] Received request_body_map: #{inspect(request_body_map)} -- Keys: #{inspect(Map.keys(request_body_map))}")

    jsonrpc_version = Map.get(request_body_map, "jsonrpc")
    mcp_method_name = Map.get(request_body_map, "method")
    request_id_from_body = Map.get(request_body_map, "id")
    params = Map.get(request_body_map, "params", %{})

    Logger.debug("[Connection.handle_call] Extracted jsonrpc: #{inspect(jsonrpc_version)}, method: #{inspect(mcp_method_name)}, id: #{inspect(request_id_from_body)}")

    context = %MCPServer.Context{
      connection_pid: self(),
      plug_conn: conn_details_map,
      request_id: request_id_from_body,
      client_capabilities: state.client_capabilities,
      custom_data: %{} # Initialize with empty custom_data
    }

    # Perform validations first
    validated_response_tuple =
      cond do
        jsonrpc_version != "2.0" ->
          genserver_reply_error(request_id_from_body, %{code: -32600, message: "Invalid Request: JSON-RPC version must be 2.0"}, state)

        is_nil(mcp_method_name) ->
          genserver_reply_error(request_id_from_body, %{code: -32600, message: "Invalid Request: method not specified"}, state)

        is_nil(request_id_from_body) and not Enum.member?(@notification_methods, mcp_method_name) ->
          genserver_reply_error(nil, %{code: -32602, message: "Invalid Request: id is required for this method"}, state)

        true ->
          # All basic validations passed, proceed to method-specific handling
          :proceed_to_dispatch
      end

    if validated_response_tuple == :proceed_to_dispatch do
      # Dispatch to the specific method handler
      case mcp_method_name do
        "mcp/initialize" ->
          client_caps_param = Map.get(params, "capabilities", %{})
          handle_mcp_initialize(context, client_caps_param, request_id_from_body, state)

        "mcp/listResources" ->
          case state.handler_module.list_resources(context, params, state.handler_state) do
            {:reply, data, new_handler_state} -> genserver_reply_success(request_id_from_body, mcp_method_name, data, %{state | handler_state: new_handler_state})
            {:error, error_obj, new_handler_state} -> genserver_reply_error(request_id_from_body, error_obj, %{state | handler_state: new_handler_state})
            other -> handle_unexpected_handler_return(other, request_id_from_body, mcp_method_name, state)
          end

        "mcp/getResource" ->
          resource_id = Map.get(params, "id")
          if resource_id do
            case state.handler_module.get_resource(context, resource_id, params, state.handler_state) do
              {:reply, data, new_handler_state} -> genserver_reply_success(request_id_from_body, mcp_method_name, data, %{state | handler_state: new_handler_state})
              {:error, error_obj, new_handler_state} -> genserver_reply_error(request_id_from_body, error_obj, %{state | handler_state: new_handler_state})
              other -> handle_unexpected_handler_return(other, request_id_from_body, mcp_method_name, state)
            end
          else
            genserver_reply_error(request_id_from_body, %{code: -32602, message: "Invalid params: missing resource id for mcp/getResource"}, state)
          end

        "mcp/listPrompts" ->
          case state.handler_module.list_prompts(context, params, state.handler_state) do
            {:reply, data, new_handler_state} -> genserver_reply_success(request_id_from_body, mcp_method_name, data, %{state | handler_state: new_handler_state})
            {:error, error_obj, new_handler_state} -> genserver_reply_error(request_id_from_body, error_obj, %{state | handler_state: new_handler_state})
            other -> handle_unexpected_handler_return(other, request_id_from_body, mcp_method_name, state)
          end

        "mcp/getPrompt" ->
          prompt_id = Map.get(params, "id")
          if prompt_id do
            case state.handler_module.get_prompt(context, prompt_id, params, state.handler_state) do
              {:reply, data, new_handler_state} -> genserver_reply_success(request_id_from_body, mcp_method_name, data, %{state | handler_state: new_handler_state})
              {:error, error_obj, new_handler_state} -> genserver_reply_error(request_id_from_body, error_obj, %{state | handler_state: new_handler_state})
              other -> handle_unexpected_handler_return(other, request_id_from_body, mcp_method_name, state)
            end
          else
            genserver_reply_error(request_id_from_body, %{code: -32602, message: "Invalid params: missing prompt id for mcp/getPrompt"}, state)
          end

        "mcp/listTools" ->
          case state.handler_module.list_tools(context, params, state.handler_state) do
            {:reply, data, new_handler_state} -> genserver_reply_success(request_id_from_body, mcp_method_name, data, %{state | handler_state: new_handler_state})
            {:error, error_obj, new_handler_state} -> genserver_reply_error(request_id_from_body, error_obj, %{state | handler_state: new_handler_state})
            other -> handle_unexpected_handler_return(other, request_id_from_body, mcp_method_name, state)
          end

        "mcp/executeTool" ->
          tool_id = Map.get(params, "toolId")
          tool_params = Map.get(params, "toolInputs", Map.get(params, "params"))
          if tool_id && tool_params do
            case state.handler_module.execute_tool(context, tool_id, tool_params, state.handler_state) do
              {:reply, data, new_handler_state} -> genserver_reply_success(request_id_from_body, mcp_method_name, data, %{state | handler_state: new_handler_state})
              {:error, error_obj, new_handler_state} -> genserver_reply_error(request_id_from_body, error_obj, %{state | handler_state: new_handler_state})
              other -> handle_unexpected_handler_return(other, request_id_from_body, mcp_method_name, state)
            end
          else
            genserver_reply_error(request_id_from_body, %{code: -32602, message: "Invalid params: missing toolId or toolInputs for mcp/executeTool"}, state)
          end
        nil -> # Method name was nil
          genserver_reply_error(request_id_from_body, %{code: -32600, message: "Invalid Request: method not specified"}, state)

        _unknown_method ->
          genserver_reply_error(request_id_from_body, %{code: -32601, message: "Method not found: #{mcp_method_name}"}, state)
      end
    else
      # One of the validations failed, validated_response_tuple is the GenServer reply
      validated_response_tuple
    end
  end

  # Handle the mcp/initialize method specifically
  defp handle_mcp_initialize(context_for_handler, client_capabilities_param, request_id, state) do
    # 1. Inform the handler about client capabilities
    case state.handler_module.handle_client_capabilities(context_for_handler, client_capabilities_param, state.handler_state) do
      {:ok, state_after_client_caps} ->
        # Server capabilities were fetched during Connection.init
        # The result for initialize includes 'serverCapabilities' and 'sessionId'
        result_data = %{
          "serverCapabilities" => state.server_capabilities,
          "sessionId" => nil # Explicitly include sessionId, can be nil
        }
        # For mcp/initialize, the result_data *is* the complete result object, not nested further.
        response_payload = %{
          "jsonrpc" => "2.0",
          "result" => result_data,
          "id" => request_id
        }
        new_genserver_state = %{state | handler_state: state_after_client_caps, client_capabilities: client_capabilities_param}
        {:reply, response_payload, new_genserver_state}

      {:error, error_obj, state_after_client_caps_error} ->
        # Handler failed to process client capabilities
        new_genserver_state = %{state | handler_state: state_after_client_caps_error}
        genserver_reply_error(request_id, error_obj, new_genserver_state)

      other ->
         Logger.error("[MCPServer.Connection] Unexpected return from handle_client_capabilities: #{inspect(other)}")
        default_error = %{
          code: -32000,
          message: "Internal server error: Handler returned unexpected value from handle_client_capabilities"
        }
        genserver_reply_error(request_id, default_error, state) # Keep original GenServer state
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

  # Builds an error response payload (map). Does not form the GenServer reply tuple.
  # This function is unused.
  # defp error_resp(id, code, message, data \\\\ nil) do
  #   payload = %{
  #     "jsonrpc" => "2.0",
  #     "id" => id,
  #     "error" => %{"code" => code, "message" => message}
  #   }
  #   if data, do: Map.put(payload["error"], "data", data), else: payload
  # end

  # --- New Helper Functions ---

  # Helper to build the final GenServer reply for a success case
  defp genserver_reply_success(request_id, mcp_method_name, handler_result_data, new_genserver_state) do
    result_object =
      case mcp_method_name do
        # "mcp/initialize" is handled by handle_mcp_initialize directly
        "mcp/listResources" -> %{"resources" => handler_result_data}
        "mcp/listPrompts" -> %{"prompts" => handler_result_data}
        "mcp/listTools" -> %{"tools" => handler_result_data}
        # For methods like getResource, getPrompt, executeTool, the handler_result_data *is* the result object
        _ -> handler_result_data # This covers getResource, getPrompt, executeTool
      end

    response = %{
      "jsonrpc" => "2.0",
      "result" => result_object,
      "id" => request_id
    }
    {:reply, response, new_genserver_state}
  end

  # Helper to build the final GenServer reply for an error case
  defp genserver_reply_error(request_id, handler_error_object, new_genserver_state) do
    response = %{
      "jsonrpc" => "2.0",
      "error" => handler_error_object, # This is %{code: ..., message: ...}
      "id" => request_id
    }
    {:reply, response, new_genserver_state}
  end

  defp handle_unexpected_handler_return(other_return, request_id, mcp_method_name, state) do
    Logger.error("[MCPServer.Connection] Unexpected return from handler for #{mcp_method_name}: #{inspect(other_return)}")
    error_obj = %{code: -32000, message: "Internal server error: Handler returned unexpected value for #{mcp_method_name}"}
    genserver_reply_error(request_id, error_obj, state) # Keep original GenServer state on unexpected handler return
  end
end
