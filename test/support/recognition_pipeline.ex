defmodule RecognitionPipeline do
  use Membrane.Pipeline

  alias Google.Cloud.Speech.V1.StreamingRecognizeResponse
  alias Membrane.Element.{File, FLACParser, GCloud}

  @impl true
  def handle_init([file, target, opts]) do
    children = [
      src: %File.Source{location: file},
      parser: FLACParser,
      sink:
        struct!(
          GCloud.SpeechToText,
          [
            language_code: "en-GB",
            word_time_offsets: true,
            interim_results: false
          ] ++ opts
        )
    ]

    links = %{
      {:src, :output} => {:parser, :input},
      {:parser, :output} => {:sink, :input}
    }

    spec = %Membrane.Pipeline.Spec{
      children: children,
      links: links
    }

    {{:ok, spec}, %{target: target}}
  end

  @impl true
  def handle_notification(%StreamingRecognizeResponse{} = response, _element, state) do
    send(state.target, response)
    {:ok, state}
  end

  def handle_notification({:end_of_stream, _pad}, :sink, state) do
    send(state.target, :end_of_upload)
    {:ok, state}
  end

  def handle_notification(_notification, _element, state) do
    {:ok, state}
  end
end
