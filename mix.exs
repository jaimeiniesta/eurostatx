defmodule Eurostatx.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/jaimeiniesta/eurostatx"

  def project do
    [
      app: :eurostatx,
      version: @version,
      elixir: "~> 1.18",
      name: "Eurostatx",
      source_url: @source_url,
      homepage_url: @source_url,
      description:
        "An Elixir client for the Eurostat APIs (Statistics, SDMX 2.1 and 3.0, Catalogue, " <>
          "Async and Files), with Explorer integration",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      deps: deps(),
      docs: docs(),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"}
      ],
      test_coverage: [
        tool: ExCoveralls
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      name: "eurostatx",
      files: ~w(lib livebooks mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Demo" => "https://jaimeiniesta.com/en/eurostatx",
        "Eurostat API" =>
          "https://ec.europa.eu/eurostat/web/user-guides/data-browser/api-data-access"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      assets: %{"assets" => "assets"},
      extras: [
        {"README.md", title: "Overview"},
        "CHANGELOG.md" | Path.wildcard("livebooks/*.livemd")
      ],
      groups_for_extras: [
        General: ["README.md", "CHANGELOG.md"],
        Livebooks: Path.wildcard("livebooks/*.livemd")
      ],
      groups_for_modules: [
        "Data APIs": [
          Eurostatx.Data,
          Eurostatx.Statistics
        ],
        "Metadata APIs": [
          Eurostatx.Catalogue,
          Eurostatx.Codelists,
          Eurostatx.Datasets,
          Eurostatx.Structure
        ],
        "Other APIs": [
          Eurostatx.Async,
          Eurostatx.Files
        ],
        "Formats and Explorer Integration": [
          Eurostatx.DataFrame,
          Eurostatx.JSONStat,
          Eurostatx.Period,
          Eurostatx.TSV
        ],
        "Supporting Modules": [
          Eurostatx.Client,
          Eurostatx.Error,
          Eurostatx.Telemetry,
          Eurostatx.Telemetry.Logger
        ]
      ]
    ]
  end

  defp deps do
    [
      # Required dependencies
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.3"},
      {:nimble_options, "~> 1.0"},
      {:nimble_csv, "~> 1.2"},
      {:saxy, "~> 1.6"},
      {:explorer, "~> 0.12"},

      # Development deps
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:sobelow, "~> 0.16", only: [:dev, :test], runtime: false},

      # Test deps
      {:plug, "~> 1.16", only: :test},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
