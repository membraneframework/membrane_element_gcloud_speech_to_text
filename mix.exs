defmodule Membrane.Element.GCloud.SpeechToText.MixProject do
  use Mix.Project

  @version "0.10.0"
  @github_url "https://github.com/membraneframework/membrane-element-gcloud-speech-to-text"

  def project do
    [
      app: :membrane_element_gcloud_speech_to_text,
      version: @version,
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),

      # hex
      description: "Membrane Multimedia Framework (Google Cloud SpeechToText Element)",
      package: package(),

      # docs
      name: "Membrane Element: GCloud SpeechToText",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:gun, "~> 2.2.0", override: true},
      {:membrane_core, "~> 1.0"},
      {:membrane_flac_format, "~> 0.2.0"},
      {:gcloud_speech_grpc, "~> 0.4.0"},
      {:qex, "~> 0.5"},
      {:credo, "~> 1.7", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:membrane_file_plugin, "~> 0.16.0", only: :test},
      {:membrane_flac_plugin, "~> 0.11.0", only: :test}
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.Element]
    ]
  end

  defp dialyzer() do
    opts = [
      flags: [:error_handling],
      plt_add_apps: [:syntax_tools]
    ]

    if System.get_env("CI") == "true" do
      # Store PLTs in cacheable directory for CI
      File.mkdir_p!(Path.join([__DIR__, "priv", "plts"]))
      [plt_local_path: "priv/plts", plt_core_path: "priv/plts"] ++ opts
    else
      opts
    end
  end
end
