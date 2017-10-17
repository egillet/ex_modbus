defmodule ExModbus.Mixfile do
  use Mix.Project

  def project do
    [app: :ex_modbus,
     version: "0.1.2",
     elixir: ">= 1.0.0",
     description: "An Elixir Modbus TCP/RTU client implementation.",
     package: package(),
     deps: deps()]
  end

  def package do
    [maintainers: ["Falco Hirschenberger"],
     licenses: ["MIT"],
     links: %{"GitHub" => "https://github.com/hirschenberger/ex_modbus"}
    ]
  end

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [applications: [:logger, :nerves_uart]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type `mix help deps` for more examples and options
  defp deps do
    [{:nerves_uart, ">= 0.1.1"},
     {:connection, "~> 1.0.4"},
     {:ex_doc, "~> 0.16", only: :dev}]
  end
end
