defmodule Looot.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/loootai/looot-elixir"

  def project do
    [
      app: :looot,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Elixir client for the looot API: one token for data providers, runs with fallback, typed errors.",
      package: package(),
      docs: docs(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:req, "== 0.7.5"},
      {:jason, "== 1.4.5"},
      {:plug, "== 1.20.3", only: :test},
      {:ex_doc, "== 0.40.4", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://docs.looot.ai",
        "API reference" => "https://docs.looot.ai/reference",
        "looot" => "https://looot.ai"
      },
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}"
    ]
  end
end
