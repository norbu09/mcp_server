# Elixir MCP Server Library - Design Document

This document outlines the design for an Elixir library that implements the Model Context Protocol (MCP) server specification.

## 1. Goals

*   Provide an idiomatic Elixir interface for creating MCP servers.
*   Integrate seamlessly with Plug and Phoenix applications.
*   Adhere to the [MCP Specification](https://modelcontextprotocol.io/specification/2025-03-26).
*   Enable easy extension and customization by users.
*   Prioritize security and user control as outlined in the MCP specification.
*   Leverage Elixir ~> 1.18 features, including the standard `JSON` module.

## 2. Core Components

The library will consist of the following main components:

*   **`MCPServer.Implementation` (Behaviour):** Defines the contract for user-specific MCP server logic.
*   **`MCPServer.Connection` (GenServer):** Manages the state of an MCP connection, handles JSON-RPC message parsing (using `JSON`), dispatching, and lifecycle.
*   **`MCPServer.Plug` (Plug):** Provides the HTTP interface, adapting incoming requests (using `JSON` for parsing/encoding) to the MCP connection GenServer.
*   **Configuration:** Application-level and Plug-level configuration options (excluding JSON parser selection).
*   **Supervisor:** For managing the lifecycle of connection GenServers.

## 3. User-Facing API (The `MCPServer.Implementation` Behaviour)

Users will implement the `MCPServer.Implementation` behaviour to define their server's capabilities.

```elixir
defmodule MyApp.MyMCPServer do
  use MCPServer.Implementation, otp_app: :my_app # Example of passing app config

  @impl MCPServer.Implementation
  def init(opts) do
    # Opts are from Plug or direct start_link
    # Returns {:ok, state} or {:stop, reason}
  end

  # --- Capabilities (Server -> Client) ---
  @impl MCPServer.Implementation
  def server_capabilities(conn, state) do
    # Returns {:ok, capabilities_map, state}
    # Capabilities map should conform to MCP spec
  end

  # --- Client -> Server Handlers ---

  # Optional: Handle client's declared capabilities
  @impl MCPServer.Implementation
  def handle_client_capabilities(conn, client_capabilities, state) do
    # Returns {:ok, new_state} or {:error, reason, new_state}
  end

  # Resources
  @impl MCPServer.Implementation
  def list_resources(conn, params, state) do
    # params typically include filters, pagination
    # Returns {:reply, list_of_resources, state} or {:error, error_object, state}
  end

  @impl MCPServer.Implementation
  def get_resource(conn, resource_id, params, state) do
    # Returns {:reply, resource_data, state} or {:error, error_object, state}
  end

  # Prompts
  @impl MCPServer.Implementation
  def list_prompts(conn, params, state) do
    # Returns {:reply, list_of_prompts, state} or {:error, error_object, state}
  end

  @impl MCPServer.Implementation
  def get_prompt(conn, prompt_id, params, state) do
    # Returns {:reply, prompt_data, state} or {:error, error_object, state}
  end

  # Tools
  @impl MCPServer.Implementation
  def list_tools(conn, params, state) do
    # Returns {:reply, list_of_tools, state} or {:error, error_object, state}
  end

  @impl MCPServer.Implementation
  def execute_tool(conn, tool_id, tool_params, state) do
    # Returns {:reply, tool_result, state} or {:error, error_object, state}
  end

  # --- Optional Client Features (Server-Initiated) ---
  # Example: Sampling
  @impl MCPServer.Implementation
  def handle_sampling_response(conn, request_id, response_data, state) do
    # Handles the async response from a sampling request made by the server
    # Returns {:noreply, new_state} or {:error, error_object, new_state}
  end


  # --- Lifecycle Callbacks ---
  @impl MCPServer.Implementation
  def terminate(reason, conn_details, state) do
    # Cleanup logic
    # conn_details might include connection info if available
    # Returns :ok
  end
end
```

**Key aspects of the `MCPServer.Implementation` behaviour:**

*   **`use MCPServer.Implementation`**: This macro will:
    *   Define the `@behaviour MCPServer.Implementation`.
    *   Provide default implementations for optional callbacks (e.g., `handle_client_capabilities` could default to `{:ok, state}`).
    *   Potentially inject helper functions or macros for constructing valid MCP responses.
*   **`conn`**: This argument, passed to most callbacks, is an `MCPServer.Context.t()` struct. It provides:
    *   `connection_pid`: The PID of the `MCPServer.Connection` GenServer for the current MCP session.
    *   `request_id`: The ID of the current JSON-RPC request (if any).
    *   `client_capabilities`: A map of capabilities declared by the client (once `mcp/initialize` is processed).
    *   `plug_conn`: When the request originates from `MCPServer.Plug`, this field contains a map of relevant details extracted from the `Plug.Conn` struct (e.g., `:remote_ip`, `:request_path`, `:method`, `:headers`). It is `nil` otherwise (e.g., for `init/1` or `terminate/3` contexts not tied to a specific request).
    *   `custom_data`: An empty map for user-defined contextual data.
*   **`state`**: User-defined state, managed similarly to GenServer state.
*   **Return values**:
    *   `{:ok, state}` / `{:ok, value, state}`
    *   `{:reply, data, state}`
    *   `{:error, error_object, state}`: `error_object` is a `map()` that SHOULD conform to MCP JSON-RPC error structure (e.g., `%{code: integer(), message: String.t(), data: any()}`).
    *   `{:noreply, state}`
    *   `{:stop, reason, state}`

## 4. `MCPServer.Plug` Details

The `MCPServer.Plug` will adapt HTTP requests to the MCP protocol.

*   **Initialization (`init/1`)**:
    *   Accepts options:
        *   `:mcp_handler` (required): The user's implementation module (e.g., `MyApp.MyMCPServer`).
        *   `:mcp_handler_opts` (optional): Options to pass to the handler's `init/1`.
        *   (JSON parser option is removed).
*   **Call (`call/2`)**:
    *   **Request Handling**:
        *   Parses the HTTP request body as JSON-RPC 2.0 using `JSON.decode/1`.
        *   For WebSocket connections (if supported later for bi-directional communication), it would handle the upgrade. For now, assume HTTP request/response.
        *   Validates the JSON-RPC message (presence of `jsonrpc`, `method`, `id`/`params`).
    *   **Dispatching**:
        *   Starts or reuses an `MCPServer.Connection` GenServer instance (potentially one per HTTP connection, or managed based on session/token if applicable, TBD).
        *   Forwards the parsed MCP method and params to the GenServer.
    *   **Response Handling**:
        *   Receives the response from the GenServer (`:reply` or `:error`).
        *   Formats it as a JSON-RPC 2.0 response using `JSON.encode!/1`.
        *   Sends it back as an HTTP response with appropriate content type (`application/json-rpc` or `application/json`).

```elixir
# Example of how it might be used in a Phoenix router:
# forward "/mcp", MCPServer.Plug, mcp_handler: MyApp.MyMCPServer, mcp_handler_opts: [foo: :bar]

# Or in a Plug.Builder pipeline:
# plug MCPServer.Plug, mcp_handler: MyApp.MyMCPServer
```

## 5. `MCPServer.Connection` (GenServer) Details

This GenServer is the heart of the MCP request lifecycle management.

*   **`start_link/1`**:
    *   Takes `args` typically including:
        *   The handler module (e.g., `MyApp.MyMCPServer`).
        *   Initial options for the handler's `init/1`.
        *   Reference to the transport (e.g., Plug.Conn, or WebSocket PID if applicable).
*   **`init/1`**:
    *   Calls the `YourHandler.init(opts)` callback.
    *   Initializes its own state, including the handler's state and the handler module.
*   **`handle_call/3` (for synchronous operations from the Plug)**:
    *   Receives parsed MCP requests (method, params, id).
    *   Invokes the corresponding callback on the user's handler module (e.g., `list_resources`, `execute_tool`).
    *   Passes the current handler state and `conn` abstraction.
    *   Returns the result to the Plug (which then forms the HTTP response).
*   **`handle_cast/2` / `handle_info/2` (for asynchronous operations or messages)**:
    *   E.g., handling WebSocket messages, server-initiated actions, timeouts.
*   **State Management**:
    *   The GenServer's state will include:
        *   `handler_module`: The user's implementation module.
        *   `handler_state`: The state returned by the user's callbacks.
        *   `client_capabilities`: Once received.
        *   `server_capabilities`: As defined by the user's `server_capabilities/2` callback.
        *   (The `conn_abstraction` / `mcp_connection_details` is now constructed on-the-fly for each handler call as an `MCPServer.Context.t()` struct, and is not part of the GenServer's own persistent state, though its components like `client_capabilities` are).
*   **Error Handling**:
    *   Catches errors from handler callbacks.
    *   Formats them into standard MCP JSON-RPC error responses.
*   **Lifecycle**:
    *   Calls `YourHandler.terminate/3` when the GenServer stops.

## 6. JSON-RPC Handling

*   The library MUST correctly parse and generate JSON-RPC 2.0 messages using the standard `JSON` module.
*   This includes handling:
    *   Request objects: `jsonrpc`, `method`, `params`, `id`.
    *   Response objects: `jsonrpc`, `result`, `id` (for success).
    *   Error objects: `jsonrpc`, `error: {code, message, data}`, `id` (for failure).
    *   Batch requests (OPTIONAL, consider for v1 or later).
    *   Notifications (requests without an `id`).

## 7. Security Considerations (MCP Spec Alignment)

*   The library itself will not enforce user consent flows directly but will provide hooks or expect the handler implementation to manage them.
*   Documentation will emphasize the security responsibilities of the implementer (user of this library) as per the MCP spec:
    *   User consent for data access and tool execution.
    *   Data privacy.
    *   Tool safety and validation of tool descriptions.
    *   Controls for LLM sampling.

## 8. Configuration

*   **Application Environment**:
    *   Default settings (e.g., logging levels).
    *   (JSON parser configuration is no longer needed here).
*   **Plug Options**:
    *   `mcp_handler`: User's module.
    *   `mcp_handler_opts`: User's module init opts.

## 9. Future Considerations / Extensions

*   **WebSocket Support**: For true bi-directional MCP, including server-initiated messages like notifications or sampling requests. This would likely involve a different Plug entry point or an upgrade mechanism.
*   **Batch JSON-RPC Requests**: Processing an array of JSON-RPC request objects.
*   **Automatic Capability Negotiation**: More elaborate helpers for the `server_capabilities` and `handle_client_capabilities` flow.
*   **Telemetry**: Emitting Telemetry events for key actions.

This document provides the foundational design. We will refine details as implementation progresses. 