# Tech Context: MCP Server Elixir Library

## 1. Core Technologies

*   **Elixir:** The primary programming language.
    *   Version: `~> 1.18` (due to reliance on the built-in `JSON` module).
    *   Key features used: GenServer, Behaviours, Macros, Plug.Conn, standard library (Map, List, JSON, etc.).
*   **Plug:** Used for HTTP integration. `MCPServer.Plug` implements the Plug behaviour.
*   **JSON:** The MCP protocol is based on JSON-RPC 2.0. The library uses Elixir's built-in `JSON` module for parsing and encoding.
*   **Mix:** The Elixir build tool, used for dependency management, compilation, testing, and formatting.
*   **ExUnit:** Elixir's testing framework, will be used for unit tests.

## 2. Development Setup

*   Elixir installation (version 1.18 or later).
*   Standard Elixir development environment.
*   A Git client for version control.

## 3. Technical Constraints & Considerations

*   **Elixir Version:** Requires Elixir 1.18+ because it uses the standard library `JSON` module. This was a conscious decision to minimize external dependencies.
*   **JSON-RPC 2.0:** Must strictly adhere to the JSON-RPC 2.0 specification for request and response formats, including error objects.
*   **Stateless Plug vs. Stateful GenServer:** `MCPServer.Plug` itself is stateless per HTTP request (as Plugs should be). State is managed by the `MCPServer.Connection` GenServer, which is started by the Plug for each request in the current design.
*   **Plug.Conn Handling:** The `Plug.Conn` struct is large and contains sensitive information. `MCPServer.Context` only stores a map of explicitly extracted, relevant details from `Plug.Conn` rather than the whole struct, to avoid accidental leaks or oversized GenServer state if the context were to be stored more long-term.
*   **Typespecs:** While efforts are made to include accurate typespecs, some complex types like `Plug.Conn.t()` have been simplified (e.g., to `map() | nil` in `MCPServer.Context.t()`) to avoid persistent linter/compiler issues. The focus is on functional correctness first.

## 4. Dependencies

*   **`mcp_server` library itself:** No external Elixir package dependencies beyond Elixir core and Plug (which is a core part of most Elixir web development).
*   **`mcp_server_demo` application:**
    *   Path dependency on `mcp_server`.
    *   `bandit`: As the webserver to run the Plug.

## 5. Tool Usage Patterns

*   **`mix format`:** For code formatting, adhering to `.formatter.exs`.
*   **`mix compile`:** For compiling the project. Warnings are treated as errors where appropriate or addressed promptly.
*   **`mix test`:** For running ExUnit tests (to be developed).
*   **`mix credo`:** For static code analysis (to be introduced/configured).
*   **Git:** For version control, following standard branching and commit practices.
*   **IDE/Editor with ElixirLS:** For development assistance (autocompletion, diagnostics).

## 6. Design Document

A more detailed design discussion and evolution of the library's components is tracked in `docs/mcp_server_elixir_design.md`. This Memory Bank provides a snapshot and key architectural patterns, while the design document may contain more granular decision-making history. 