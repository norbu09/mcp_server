# credo:disable-for-this-file Credo.Check.Readability.Specs
defmodule MCPServer.Implementation do
  @moduledoc """
  Defines the behaviour for an MCP (Model Context Protocol) server implementation.

  Modules wishing to act as MCP servers must adopt this behaviour and implement
  the required callbacks to handle various MCP requests and lifecycle events.

  The `use MCPServer.Implementation` directive in a user's module will
  automatically set `@behaviour MCPServer.Implementation` and can provide
  default implementations or helper functions in the future.

  ## State Management

  The `init/1` callback initializes a state that is passed through subsequent
  callbacks. This allows the implementation to maintain context across requests
  for a given MCP connection.

  ## Return Values

  Callbacks generally return tuples indicating success, reply, error, or control flow:
  - `{:ok, state}`: For successful state initialization or updates without a direct reply.
  - `{:ok, value, state}`: For successful operations returning a value and updating state.
  - `{:reply, data, state}`: To send a successful JSON-RPC response. `data` will be the `result` field.
  - `{:error, error_object, state}`: To send a JSON-RPC error response. `error_object` should be a map like
    `%{code: integer(), message: String.t(), data: any()}`.
  - `{:noreply, state}`: For operations that update state but don't send an immediate reply (e.g., handling async notifications).
  - `{:stop, reason, state}`: To terminate the connection handler.

  ## The `conn` Abstraction

  Most callbacks receive a `conn` argument. This will be a struct or map representing
  the MCP connection, providing context and potentially allowing the handler to send
  server-initiated messages (e.g., for client features like Sampling) in the future.
  For now, its structure is minimal but will be expanded.
  """

  # Represents the MCP connection context passed to callbacks.
  # alias MCPServer.Context # Removed unused alias
  @type conn_abstraction :: MCPServer.Context.t()

  @type error_object :: map()

  @doc """
  Initializes the MCP handler.

  Called when the MCP connection is established (e.g., when `MCPServer.Plug` first
  delegates to `MCPServer.Connection` for a new session/request).

  `opts` are the options passed from the Plug's configuration (`:mcp_handler_opts`)
  or when directly starting a connection.

  Should return `{:ok, initial_state}` or `{:stop, reason}` if initialization fails.
  """
  @callback init(opts :: keyword()) :: {:ok, state :: any()} | {:stop, reason :: any()}

  @doc """
  Defines the capabilities of this MCP server.

  This is called by the `MCPServer.Connection` GenServer to determine what
  features the server supports, which can then be communicated to the MCP client
  during capability negotiation, as per the MCP specification.

  The returned `capabilities_map` should conform to the MCP Server Capabilities structure.
  Example:
  ```elixir
  %{
    "resources" => %{
      "listResources" => %{ "dynamic": true },
      "getResource" => %{ "dynamic": true }
    },
    "prompts" => %{
      "listPrompts" => %{ "dynamic": true },
      "getPrompt" => %{ "dynamic": true }
    },
    "tools" => %{
      "listTools" => %{ "dynamic": true },
      "executeTool" => %{ "dynamic": true }
    }
    # Potentially "clientFeatures" like "sampling" if the server wants to use them.
  }
  ```
  """
  @callback server_capabilities(conn :: conn_abstraction(), state :: any()) ::
              {:ok, capabilities_map :: map(), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  @doc """
  Optional: Handles the client's declared capabilities.

  This callback is invoked after the client shares its capabilities with the server.
  The implementation can inspect `client_capabilities` and optionally adjust its
  `state` or behavior accordingly.

  If not implemented, a default pass-through implementation might be provided by
  `use MCPServer.Implementation`.
  """
  @callback handle_client_capabilities(
              conn :: conn_abstraction(),
              client_capabilities :: map(),
              state :: any()
            ) ::
              {:ok, new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  # --- Resource Callbacks --- (Based on MCP Specification)

  @doc """
  Handles a request to list available resources.

  `params` is a map of parameters sent by the client (e.g., filters, pagination).
  Should return `{:reply, list_of_resources, new_state}` where `list_of_resources`
  is a list of maps, each representing an MCP resource descriptor.
  Or `{:error, error_object, new_state}`.
  """
  @callback list_resources(conn :: conn_abstraction(), params :: map(), state :: any()) ::
              {:reply, list_of_resources :: list(map()), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  @doc """
  Handles a request to get a specific resource by its ID.

  `resource_id` is the identifier of the resource.
  `params` may contain additional parameters for fetching the resource.
  Should return `{:reply, resource_data, new_state}` where `resource_data` is a map
  representing the MCP resource content and metadata.
  Or `{:error, error_object, new_state}`.
  """
  @callback get_resource(
              conn :: conn_abstraction(),
              resource_id :: String.t(),
              params :: map(),
              state :: any()
            ) ::
              {:reply, resource_data :: map(), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  # --- Prompt Callbacks --- (Based on MCP Specification)

  @doc """
  Handles a request to list available prompts.

  `params` is a map of parameters sent by the client.
  Should return `{:reply, list_of_prompts, new_state}` where `list_of_prompts`
  is a list of maps, each representing an MCP prompt descriptor.
  Or `{:error, error_object, new_state}`.
  """
  @callback list_prompts(conn :: conn_abstraction(), params :: map(), state :: any()) ::
              {:reply, list_of_prompts :: list(map()), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  @doc """
  Handles a request to get a specific prompt template by its ID.

  `prompt_id` is the identifier of the prompt.
  `params` may contain additional parameters.
  Should return `{:reply, prompt_data, new_state}` where `prompt_data` is a map
  representing the MCP prompt template.
  Or `{:error, error_object, new_state}`.
  """
  @callback get_prompt(
              conn :: conn_abstraction(),
              prompt_id :: String.t(),
              params :: map(),
              state :: any()
            ) ::
              {:reply, prompt_data :: map(), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  # --- Tool Callbacks --- (Based on MCP Specification)

  @doc """
  Handles a request to list available tools.

  `params` is a map of parameters sent by the client.
  Should return `{:reply, list_of_tools, new_state}` where `list_of_tools`
  is a list of maps, each representing an MCP tool descriptor (including input/output schemas).
  Or `{:error, error_object, new_state}`.
  """
  @callback list_tools(conn :: conn_abstraction(), params :: map(), state :: any()) ::
              {:reply, list_of_tools :: list(map()), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  @doc """
  Handles a request to execute a specific tool by its ID.

  `tool_id` is the identifier of the tool.
  `tool_params` is a map of parameters provided by the client for the tool execution,
  which should conform to the tool's input schema.
  Should return `{:reply, tool_result, new_state}` where `tool_result` is the output
  of the tool execution, conforming to the tool's output schema.
  Or `{:error, error_object, new_state}`.
  """
  @callback execute_tool(
              conn :: conn_abstraction(),
              tool_id :: String.t(),
              tool_params :: map(),
              state :: any()
            ) ::
              {:reply, tool_result :: map() | any(), new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  # --- Optional Client Features (Server-Initiated) ---
  # These would be relevant if the server wants to use features like "sampling"
  # that are initiated by the server and expect a response from the client.

  @doc """
  Optional: Handles an asynchronous response from the client for a server-initiated request.

  For example, if the server made an LLM sampling request to the client, this callback
  would be invoked when the client sends back the sampling result.

  `request_id` is the ID of the original server-initiated request.
  `response_data` is the data sent back by the client.
  Should typically return `{:noreply, new_state}` or `{:error, error_object, new_state}`
  if the response indicates an error or is unexpected.
  """
  @callback handle_sampling_response(
              conn :: conn_abstraction(),
              request_id :: String.t() | integer(),
              response_data :: map(),
              state :: any()
            ) ::
              {:noreply, new_state :: any()}
              | {:error, error_object :: error_object(), new_state :: any()}

  # --- Lifecycle Callbacks ---

  @doc """
  Called when the MCP connection is terminating.

  This callback allows the implementation to perform any necessary cleanup.
  `reason` indicates why the connection is terminating (e.g., `:normal`, `:shutdown`, an error tuple).
  `conn_details` could be the `conn_abstraction` or other relevant data about the connection being closed.

  The return value is ignored.
  """
  @callback terminate(reason :: any(), conn_details :: conn_abstraction() | map(), state :: any()) ::
              any()

  # --- Macro to define the behaviour and provide defaults ---
  defmacro __using__(_opts) do
    quote do
      @behaviour MCPServer.Implementation

      # Provide default implementations for optional callbacks
      # Users can override these by defining their own.

      def handle_client_capabilities(_conn, _client_capabilities, state) do
        {:ok, state}
      end

      def handle_sampling_response(_conn, _request_id, _response_data, state) do
        {:noreply, state}
      end

      def terminate(_reason, _conn_details, _state) do
        :ok
      end

      def server_capabilities(_conn, state) do
        default_caps = %{
          "resources" => %{},
          "prompts" => %{},
          "tools" => %{}
        }
        {:ok, default_caps, state}
      end

      # Only functions with default implementations provided here should be overridable.
      defoverridable [
        handle_client_capabilities: 3,
        handle_sampling_response: 4,
        terminate: 3,
        server_capabilities: 2
        # Removed init:1, list_resources:3, get_resource:4, etc., as they don't have defaults here.
      ]
    end
  end
end
