defmodule MCPServer.Context do
  @moduledoc """
  Represents the context of an MCP connection/request passed to handler callbacks.

  This struct provides the handler with information about the connection and
  potentially allows for server-initiated actions in the future (though not yet implemented).
  """
  # alias Plug.Conn # Removed as Plug.Conn.t() is not directly used in typespec now

  defstruct [
    # The PID of the MCPServer.Connection GenServer managing this specific MCP session/connection.
    # This could be used for advanced scenarios like server-initiated messages, but care must be taken
    # to avoid direct calls that could lead to deadlocks if not handled asynchronously.
    # For now, it's primarily for identification and future extension.
    connection_pid: nil,

    # The original Plug.Conn from the HTTP request.
    # This provides access to request headers, remote IP, etc.
    # Note: This will be nil if the MCP interaction is not over HTTP via Plug.
    plug_conn: nil, # This will hold a Plug.Conn struct, but typed as map() in @type t

    # The ID of the current JSON-RPC request, if applicable.
    # Useful if a handler needs to correlate actions with a specific request.
    request_id: nil,

    # Stores the client capabilities map once received via `mcp/initialize`.
    client_capabilities: nil,

    # User-defined data that can be carried through the context if necessary.
    # This is not populated by the library itself but can be used by wrappers or advanced handlers.
    custom_data: %{}
  ]

  @typedoc """
  The type for an MCP Context.

  The `plug_conn` field is typed as `map() | nil` for broad compatibility with
  typespec linters when dealing with `Plug.Conn.t()`. In practice, when the context
  originates from an HTTP request via `MCPServer.Plug`, this field will hold a map
  of extracted details from the `Plug.Conn` struct, such as `:remote_ip`,
  `:request_path`, `:method`, and `:headers`.
  """
  @type t :: %__MODULE__{
          connection_pid: pid() | nil,
          plug_conn: map() | nil,
          request_id: String.t() | integer() | nil,
          client_capabilities: map() | nil,
          custom_data: map()
        }
end
