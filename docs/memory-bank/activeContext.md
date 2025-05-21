# Active Context: MCP Server Elixir Library

## 1. Current Work Focus

The immediate next step is to establish a basic test suite for the `mcp_server` library, focusing initially on the `mcp_server_demo` application to ensure end-to-end functionality. This will involve:

*   Setting up basic test helpers.
*   Writing a test for the `MCPServerDemo.EchoHandler` through the `MCPServer.Plug` to verify:
    *   Successful request-response cycle for a known MCP method (e.g., `mcp/listResources`).
    *   Correct JSON-RPC request parsing and response formatting.
    *   Handler `init/2` and the specific method callback (e.g., `list_resources/3`) are invoked.

Once the demo app has a basic test, we will expand testing to cover individual components of the `mcp_server` library more directly (e.g., unit tests for `MCPServer.Connection` logic, `MCPServer.Implementation` default functions).

## 2. Recent Changes Summary

*   **Core Library Implemented:** `MCPServer.Plug`, `MCPServer.Implementation` (behaviour), `MCPServer.Connection` (GenServer), and `MCPServer.Context` (struct) have been created and refined.
*   **JSON Handling:** Switched from Jason to the standard library `JSON` module (Elixir 1.18+).
*   **`MCPServer.Context`:** Introduced this struct to provide richer, structured context to handler callbacks. It includes selected details from `Plug.Conn` rather than the full `Plug.Conn` object.
*   **Demo Project (`mcp_server_demo`):**
    *   Created with an `MCPServerDemo.EchoHandler` and an `Application` module to run Bandit with the `MCPServer.Plug`.
    *   Successfully compiles and serves as a basic integration testbed.
*   **Typespecs & Warnings:** Addressed various typespec issues and compiler warnings. Some typespecs (like `Plug.Conn.t()`) were simplified for pragmatic reasons.
*   **`MCPServer.Implementation` Defaults:** Corrected the `defoverridable` list in the `__using__/1` macro to only include functions with actual default implementations, fixing compilation issues in the demo.

## 3. Next Steps (High-Level)

1.  **Test Suite for `mcp_server_demo` (Current Focus):** Verify basic end-to-end functionality.
2.  **Unit Tests for `mcp_server` library:**
    *   Test `MCPServer.Connection` logic in isolation (method dispatch, state transitions, error handling).
    *   Test `MCPServer.Plug` request handling and response generation.
    *   Test default implementations in `MCPServer.Implementation`.
3.  **Documentation:**
    *   Write comprehensive `@moduledoc` and `@doc` for all public modules and functions.
    *   Create a `README.md` for the `mcp_server` library with usage instructions and examples.
    *   Review and update `docs/mcp_server_elixir_design.md`.
4.  **Credo Integration:** Add and configure `credo` for static code analysis.
5.  **Refinements & Advanced Features (Post-MVP):**
    *   Consider WebSocket support.
    *   Consider batch JSON-RPC request support.
    *   More robust error handling and logging.

## 4. Active Decisions & Considerations

*   **Testing Strategy:** Start with integration-style tests via the demo app, then add more focused unit tests for library components. This ensures the primary user workflow is covered early.
*   **`Plug.Conn` in Context:** The decision to pass a map of selected `Plug.Conn` details to `MCPServer.Context.plug_conn` instead of the full `conn` is firm, for security and state management reasons.
*   **GenServer Lifecycle:** Currently, `MCPServer.Plug` starts a new `MCPServer.Connection` GenServer for each HTTP request. This is simple but might not be suitable for MCP features that imply a longer-lived session without a client-provided session identifier. For now, this is deemed sufficient for MVP.
*   **Error Object Granularity:** The `@type error_object :: map()` in `MCPServer.Implementation` is broad. We may refine this to a more specific struct or map shape as we define standard error codes/structures for the library.

## 5. Important Patterns & Preferences

*   **Clarity and Simplicity:** Prefer straightforward Elixir code. Use pattern matching effectively.
*   **Explicit Error Handling:** Use `{:ok, ...}` and `{:error, ...}` tuples. Avoid raising exceptions for flow control.
*   **Immutability:** Embrace Elixir's immutable data structures.
*   **Test-Driven (Aspirational):** While not strictly TDD, write tests alongside or shortly after feature implementation.
*   **Minimal Dependencies:** Stick to Elixir core and essential libraries like Plug.

## 6. Learnings & Project Insights

*   **Typespecs can be tricky:** Especially with external libraries or complex data structures. Pragmatism is needed; sometimes a slightly less precise typespec is better than a persistent compiler error if the underlying code is sound.
*   **`defoverridable` requires care:** Ensure that only functions with default implementations provided by the module using `defoverridable` are listed.
*   **Demo applications are invaluable:** They serve as the first line of integration testing and highlight issues that unit tests for isolated components might miss.
*   **Iterative Refinement:** The design (e.g., introduction of `MCPServer.Context`) evolves as implementation details are worked through. 