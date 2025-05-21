# System Patterns: MCP Server Elixir Library

## 1. Core Architecture

The library is structured around three main components:

1.  **`MCPServer.Implementation` (Behaviour):**
    *   Defines the contract for user-specific MCP logic.
    *   Developers create a handler module that `use MCPServer.Implementation` and implement callbacks for MCP methods (e.g., `list_resources/3`, `execute_tool/4`, `create_prompt_resource/4`).
    *   Provides default implementations for optional callbacks (e.g., `handle_client_capabilities/3`, `terminate/3`).
    *   The `__using__/1` macro in this module injects `@behaviour MCPServer.Implementation` and the default function implementations.

2.  **`MCPServer.Connection` (GenServer):**
    *   Manages the state for a single MCP connection/session.
    *   Each incoming HTTP request (via `MCPServer.Plug`) that isn't for an existing session conceptually starts or interacts with a `Connection` GenServer (though currently, a new GenServer is started per request for simplicity, this might evolve if session persistence across requests is needed without client-side session IDs).
    *   **State:** Holds the `handler_module`, the handler's internal `handler_state`, `client_capabilities` (received from "mcp/initialize"), and `server_capabilities` (defined by the handler).
    *   `init/1`: Calls the handler's `init/2` callback to initialize its state.
    *   `handle_call/3` (for `{:process_request, ...}`): 
        *   Decodes the JSON-RPC request.
        *   Maps the MCP method (e.g., "mcp/listResources") to the corresponding callback in the `handler_module`.
        *   Passes a `MCPServer.Context.t()` struct, the method parameters, and the current `handler_state` to the callback.
        *   Updates `handler_state` based on the callback's return value.
        *   Formats the callback's response (or error) into a JSON-RPC response.
    *   `terminate/2`: Calls the handler's `terminate/3` callback.

3.  **`MCPServer.Plug` (Plug):**
    *   The entry point for HTTP requests.
    *   `init/1`: Receives options, primarily `:mcp_handler` (the user's handler module) and `:mcp_handler_opts` (options for the handler's `init/2` callback). It starts the `MCPServer.Connection` GenServer and stores its PID.
    *   `call/2`:
        *   Reads the request body.
        *   Parses the JSON body using `JSON.decode/1`.
        *   Passes the parsed request and the `Plug.Conn` to `MCPServer.Connection.process_request/3`.
        *   Sends the JSON-RPC response (success or error) back to the client.

4.  **`MCPServer.Context` (Struct):**
    *   A struct passed to all handler callbacks.
    *   Contains: `connection_pid` (PID of the `MCPServer.Connection` GenServer), `plug_conn` (a map of selected details from the original `Plug.Conn`), `request_id` (from JSON-RPC), `client_capabilities`, and `custom_data` (for future use or user extension).
    *   Provides a consistent and richer context to the handler beyond just its own state.

## 2. Request Flow (HTTP)

```mermaid
graph TD
    ClientRequest[HTTP POST Request to /mcp_path] --> PlugCall{MCPServer.Plug.call/2};
    PlugCall --> ReadBody[Read Request Body];
    ReadBody --> ParseJSON[Parse JSON-RPC Request using JSON.decode/1];
    ParseJSON --> StartConn{Get/Ensure MCPServer.Connection PID (from Plug opts)};
    StartConn --> ProcessReq[MCPServer.Connection.process_request/3 with parsed request & Plug.Conn details];
    
    subgraph MCPServer.Connection GenServer
        ProcessReq --> HandleCall{:process_request};
        HandleCall --> GetHandlerState[Retrieve Handler Module & State];
        GetHandlerState --> CreateContext[Create MCPServer.Context.t()];
        CreateContext --> DispatchToHandler{Dispatch to Handler Callback e.g., handler.list_resources/3};
        DispatchToHandler -- :reply/:error, new_state --> UpdateHandlerState[Update Handler State];
        UpdateHandlerState --> FormatResponse[Format JSON-RPC Response];
    end

    FormatResponse --> SendResponse[MCPServer.Plug sends HTTP Response];
    ClientRequest --> SendResponse; 

    ParseJSON -- JSON Error --> ErrorResponse[Format JSON-RPC Error];
    ErrorResponse --> SendResponse;
    DispatchToHandler -- Error in Handler --> ErrorResponse;
```

## 3. Key Technical Decisions

*   **Behaviour for User Logic:** Provides a clear contract and allows for easy mocking in tests.
*   **GenServer for State:** Standard Elixir pattern for managing stateful processes. Each connection (or request, in the current model) gets its own isolated state.
*   **Plug for HTTP:** Leverages the well-established Plug standard for web integration, making it compatible with Phoenix and other Plug-based frameworks.
*   **Standard `JSON` Module:** Uses Elixir 1.18+'s built-in `JSON` module, avoiding external dependencies for JSON parsing/encoding.
*   **`MCPServer.Context` Struct:** Provides a structured way to pass relevant information to handler callbacks, improving explicitness over a simple map.
*   **Error Handling:** Handler callbacks return `{:reply, result, state}` or `{:error, error_object, state}`. The `Connection` GenServer translates these into JSON-RPC success or error responses.
*   **Default Implementations:** The `MCPServer.Implementation` behaviour provides default no-op or sensible defaults for optional MCP methods, reducing boilerplate for users.

## 4. Component Relationships

```mermaid
graph LR
    UserApp[User Application / Phoenix]
    UserHandler[User's Handler Module (implements MCPServer.Implementation)]
    MCPServer.Plug -- delegates to --> MCPServer.Connection;
    MCPServer.Connection -- calls callbacks on --> UserHandler;
    MCPServer.Implementation -- defines callbacks for --> UserHandler;
    MCPServer.Context -- passed to --> UserHandler;
    UserApp -- mounts --> MCPServer.Plug;
```

## 5. Critical Implementation Paths

*   **JSON-RPC Parsing and Serialization:** Correctly handling the JSON-RPC 2.0 spec for requests and responses.
*   **Method Dispatch:** Reliably mapping MCP method strings to the correct handler callbacks.
*   **State Management:** Ensuring handler state is correctly initialized, passed, updated, and terminated.
*   **Error Propagation:** Translating errors from handlers or internal processes into valid JSON-RPC error responses.
*   **`mcp/initialize` Flow:** Correctly handling client capabilities and returning server capabilities. 