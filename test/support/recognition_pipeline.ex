defmodule RecognitionPipeline do
  use Membrane.Pipeline

  alias Google.Cloud.Speech.V1.StreamingRecognizeResponse
  alias Membrane.Element.{File, FLACParser, GCloud}

  @impl true
  def handle_init(_) do
    children = [
      src: %File.Source{location: "sample.flac"},
      parser: FLACParser,
      sink: %GCloud.SpeechToText{
        language_code: "en-GB"
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
