defmodule McpServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :mcp_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
      # We don't need to list mcp_server in applications here
      # as it's a library providing modules, not a runnable app itself.
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # No explicit JSON dependency needed for Elixir >= 1.18
      # {:jason, "~> 1.2"}, # Kept for reference if we needed to support older Elixir
      {:plug, "~> 1.14"}
      # Add other dependencies here, e.g., for testing, docs
      # {:ex_doc, "~> 0.27", only: :dev, runtime: false}
    ]
  end

  defp description() do
    "An Elixir implementation of the Model Context Protocol (MCP) server specification, designed for Plug and Phoenix integration."
  end

  defp package() do
    [
      maintainers: ["Your Name"], # TODO: Update maintainer
      licenses: ["Apache-2.0"], # TODO: Confirm license
      links: %{"GitHub" => "https://github.com/your_repo/mcp_server"} # TODO: Update repo URL
    ]
  end
end
