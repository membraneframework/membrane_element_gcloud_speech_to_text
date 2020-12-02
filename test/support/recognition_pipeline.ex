defmodule RecognitionPipeline do
  use Membrane.Pipeline

  alias Google.Cloud.Speech.V1.StreamingRecognizeResponse
  alias Membrane.Element.{FLACParser, GCloud}

  @impl true
  def handle_init([file, target, opts]) do
    children = [
      src: %Membrane.File.Source{location: file},
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

    spec = %Membrane.ParentSpec{
      children: children,
      links: links
    }

    {{:ok, spec: spec}, %{target: target}}
  end

  @impl true
  def handle_notification(%StreamingRecognizeResponse{} = response, _element, _ctx, state) do
    send(state.target, response)
    {:ok, state}
  end

  @impl true
  def handle_notification({:end_of_stream, _pad}, :sink, _ctx, state) do
    send(state.target, :end_of_upload)
    {:ok, state}
  end

  @impl true
  def handle_notification(_notification, _element, _ctx, state) do
    {:ok, state}
  end
end
