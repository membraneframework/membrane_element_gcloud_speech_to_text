# Membrane Multimedia Framework: GCloud Speech To Text

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_element_gcloud_speech_to_text.svg)](https://hex.pm/packages/membrane_element_gcloud_speech_to_text)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane-element-gcloud-speech-to-text.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane-element-gcloud-speech-to-text)

This package provides a Sink wrapping [Google Cloud Speech To Text Streaming API client](https://hex.pm/packages/gcloud_speech_grpc).
Currently supports only audio streams in FLAC format.

The docs can be found at [HexDocs](https://hexdocs.pm/membrane_element_gcloud_speech_to_text).

## Installation

The package can be installed by adding `membrane_element_gcloud_speech_to_text` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:membrane_element_gcloud_speech_to_text, "~> 0.1.0"}
  ]
end
```

## Configuration

To use the element you need a `config/config.exs` file with Google credentials:

```elixir
use Mix.Config

config :goth, json: "a_path/to/google/credentials/creds.json" |> File.read!()
```

More info on how to configure credentials can be found in [README of Goth library](https://github.com/peburrows/goth#installation)
used for authentication.

## Usage

The input stream for this element should be parsed, so most of the time it should be
placed in pipeline right after [FLACParser](https://github.com/membraneframework/membrane-element-flac-parser)

Here's an example of pipeline streaming audio file to speech recognition API:

```elixir
defmodule SpeechRecognition do
  use Membrane.Pipeline

  alias Google.Cloud.Speech.V1.StreamingRecognizeResponse
  alias Membrane.Element.{File, FLACParser, GCloud}

  @impl true
  def handle_init(_) do
    children = [
      src: %File.Source{location: "sample.flac"},
      parser: FLACParser,
      sink: %GCloud.SpeechToText{
        interim_results: false,
        language_code: "en-GB",
        word_time_offsets: true
      }
    ]

    links = %{
      {:src, :output} => {:parser, :input},
      {:parser, :output} => {:sink, :input}
    }

    spec = %Membrane.Pipeline.Spec{
      children: children,
      links: links
    }

    {{:ok, spec}, %{}}
  end

  @impl true
  def handle_notification(%StreamingRecognizeResponse{} = response, _element, state) do
    IO.inspect(response)
    {:ok, state}
  end

  def handle_notification(_notification, _element, state) do
    {:ok, state}
  end
end
```

The pipeline also requires [a config file](#configuration) and the following dependencies:

```elixir
[
  {:membrane_core, "~> 0.3.0"},
  {:membrane_element_file, "~> 0.2"},
  {:membrane_element_flac_parser, "~> 0.1"},
  {:membrane_element_gcloud_speech_to_text, "~> 0.1"}
]
```

## Testing

Tests tagged `:external` are excluded by default since they contact the real API and require
configuration of credentials. See [Configuration](#configuration)

## Fixture

A recording fragment in `test/fixtures` comes from an audiobook
"The adventures of Sherlock Holmes (version 2)" available on [LibriVox](https://librivox.org/the-adventures-of-sherlock-holmes-by-sir-arthur-conan-doyle/)

## Copyright and License

Copyright 2019, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane-element-gcloud-speech-to-text)

[![Software Mansion](https://membraneframework.github.io/static/logo/swm_logo_readme.png)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane-element-gcloud-speech-to-text)

Licensed under the [Apache License, Version 2.0](LICENSE)
