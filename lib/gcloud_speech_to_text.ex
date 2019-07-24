defmodule Membrane.Element.GCloud.SpeechToText do
  use Membrane.Element.Base.Sink
  use Membrane.Log, tags: :membrane_element_gcloud_stt

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Event.EndOfStream
  alias GCloud.SpeechAPI.Streaming.Client

  alias Google.Cloud.Speech.V1.{
    RecognitionConfig,
    StreamingRecognitionConfig,
    StreamingRecognizeRequest,
    StreamingRecognizeResponse
  }

  def_input_pad :input,
    caps: FLAC,
    demand_unit: :buffers

  def_options language_code: [
                type: :string,
                default: "en-US",
                description: """
                The language of the supplied audio.
                See [Language Support](https://cloud.google.com/speech-to-text/docs/languages)
                for a list of supported languages codes.
                """
              ],
              interim_results: [
                type: :boolean,
                default: false,
                description: """
                If set to true, the interim results may be returned by recognition API.
                See [Google API docs](https://cloud.google.com/speech-to-text/docs/reference/rpc/google.cloud.speech.v1#google.cloud.speech.v1.StreamingRecognitionConfig)
                for more info.
                """
              ]

  # TODO: maybe add more options

  @impl true
  def handle_init(opts) do
    state = opts |> Map.merge(%{api_client: nil})
    {:ok, state}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    {:ok, api_client} = Client.start_link()
    {:ok, %{state | api_client: api_client}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, %{api_client: api_client} = state) do
    api_client |> Client.stop()
    {:ok, %{state | api_client: nil}}
  end

  @impl true
  def handle_caps(:input, %FLAC{} = caps, _ctx, state) do
    cfg =
      RecognitionConfig.new(
        audio_channel_count: caps.channels,
        encoding: :FLAC,
        language_code: state.language_code,
        sample_rate_hertz: caps.sample_rate
      )

    str_cfg =
      StreamingRecognitionConfig.new(
        config: cfg,
        interim_results: state.interim_results
      )

    request = StreamingRecognizeRequest.new(streaming_request: {:streaming_config, str_cfg})

    state.api_client |> Client.send_request(request)

    {:ok, state}
  end

  @impl true
  def handle_write(:input, %Buffer{payload: payload}, _ctx, %{api_client: api_client} = state) do
    Client.send_request(
      api_client,
      StreamingRecognizeRequest.new(streaming_request: {:audio_content, payload})
    )

    # TODO: Calculate frames time and reconnect before reaching maximum recognition length
    # NOTE: You have to remember that old client cannot be killed before receiving all responses
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_event(:input, %EndOfStream{}, ctx, %{api_client: api_client} = state) do
    request = StreamingRecognizeRequest.new(streaming_request: {:audio_content, ""})
    api_client |> Client.send_request(request, end_stream: true)
    info("End of Stream")

    super(:input, %EndOfStream{}, ctx, state)
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_other(%StreamingRecognizeResponse{} = response, _ctx, state) do
    {{:ok, notify: response}, state}
  end
end
