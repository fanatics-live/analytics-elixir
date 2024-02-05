defmodule AnalyticsElixir.Mixfile do
  use Mix.Project

  @source_url "https://github.com/fanatics-live/analytics-elixir"
  @version "0.2.7"

  def project do
    [
      app: :segment,
      version: @version,
      elixir: "~> 1.0",
      deps: deps(),
      description: "analytics_elixir",
      dialyzer: [plt_add_deps: [:app_tree]],
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:hackney, "~> 1.15"},
      {:jason, ">= 1.0.0"},
      {:retry, "~> 0.13"},
      {:telemetry, "~> 0.4.2 or ~> 1.0"},
      {:tesla, "~> 1.2"},
      {:persistent_queue, github: "fanatics-live/persistent_queue"},
      {:mox, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test]},
      {:credo_contrib, "~> 0.2.0", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "Segment",
      api_reference: false,
      source_ref: "#{@version}",
      source_url: @source_url
    ]
  end
end
