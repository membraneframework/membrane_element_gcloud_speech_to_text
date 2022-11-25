defmodule RecognitionPipeline do
  @moduledoc false
  use Membrane.Pipeline

  alias Google.Cloud.Speech.V1.StreamingRecognizeResponse
  alias Membrane.Element.{FLACParser, GCloud}

  @impl true
  def handle_init(_ctx, [file, target, opts]) do
    sink =
      struct!(
        GCloud.SpeechToText,
        [
          language_code: "en-GB",
          word_time_offsets: true,
          interim_results: false
        ] ++ opts
      )

    spec = [
      child(:src, %Membrane.File.Source{location: file})
      |> child(:parser, FLACParser)
      |> child(:sink, sink)
    ]

    {[spec: spec], %{target: target}}
  end

  @impl true
  def handle_child_notification(%StreamingRecognizeResponse{} = response, _element, _ctx, state) do
    send(state.target, response)
    {[], state}
  end

  @impl true
  def handle_child_notification({:end_of_stream, _pad}, :sink, _ctx, state) do
    send(state.target, :end_of_upload)
    {[], state}
  end

  @impl true
  def handle_child_notification(_notification, _element, _ctx, state) do
    {[], state}
  end
end
