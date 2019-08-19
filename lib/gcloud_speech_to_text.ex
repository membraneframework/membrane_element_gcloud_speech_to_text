defmodule Membrane.Element.GCloud.SpeechToText do
  use Membrane.Element.Base.Sink
  use Membrane.Log, tags: :membrane_element_gcloud_stt

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Event.EndOfStream
  alias Membrane.Time
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
              ],
              streaming_time_limit: [
                type: :time,
                default: 200 |> Time.seconds(),
                description: """
                Determines how much audio can be sent to recognition API in one
                client session. After this time, a new client session is created
                while the old one is kept alive for some time to receive recognition
                results.

                Bear in mind that `streaming_time_limit` + `results_await_time` must
                be smaller than recognition time limit for Google Streaming API
                (currently 5 minutes)
                """
              ],
              results_await_time: [
                type: :time,
                default: 90 |> Time.seconds(),
                description: """
                The amount of time a client that stopped streaming is kept alive
                awaiting results from recognition API.
                """
              ]

  # TODO: maybe add more options

  @impl true
  def handle_init(opts) do
    state =
      opts
      |> Map.merge(%{
        client: nil,
        old_client: nil,
        init_time: nil,
        time: 0,
        samples: 0,
        restarts: 0
      })

    {:ok, state}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    state = start_client(state)
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    :ok = state.client |> Client.stop()
    {:ok, %{state | client: nil}}
  end

  @impl true
  def handle_caps(:input, %FLAC{} = caps, _ctx, state) do
    :ok = state.client |> client_start_stream(caps, state)

    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.to_milliseconds()
    )

    {:ok, %{state | init_time: Time.os_time()}}
  end

  @impl true
  def handle_write(:input, %Buffer{payload: payload, metadata: metadata}, ctx, state) do
    caps = ctx.pads.input.caps
    state = update_time(metadata, caps, state)

    demand_time =
      (state.init_time + state.time - Time.os_time()) |> max(0) |> Time.to_milliseconds()

    Process.send_after(self(), :demand_frame, demand_time)

    :ok =
      Client.send_request(
        state.client,
        StreamingRecognizeRequest.new(streaming_request: {:audio_content, payload})
      )

    {:ok, state}
  end

  @impl true
  def handle_event(:input, %EndOfStream{}, ctx, state) do
    info("End of Stream")
    :ok = state.client |> Client.end_stream()
    super(:input, %EndOfStream{}, ctx, %{state | old_client: nil})
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_other(:demand_frame, _ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_other(%StreamingRecognizeResponse{} = response, _ctx, state) do
    unless response.results |> Enum.empty?() do
      delay = state.time - (response.results |> Enum.map(& &1.result_end_time) |> Enum.max())

      info(
        "[#{inspect(state.client)}] Recognize response delay: #{delay |> Time.to_seconds()} seconds"
      )
    end

    {{:ok, notify: response}, state}
  end

  @impl true
  def handle_other(:start_new_client, ctx, %{client: old_client} = state) do
    :ok = old_client |> Client.end_stream()
    state = start_client(state)
    :ok = state.client |> client_start_stream(ctx.pads.input.caps, state)

    Process.send_after(
      self(),
      {:stop_old_client, old_client},
      state.results_await_time |> Time.to_milliseconds()
    )

    {:ok, state}
  end

  @impl true
  def handle_other({:stop_old_client, old_client}, _ctx, state) do
    old_client |> Client.stop()
    info("Stopping old client: #{inspect(old_client)}")
    {:ok, state}
  end

  defp start_client(state) do
    {:ok, client} = Client.start_link(start_time: state.time)
    info("Started new client: #{inspect(client)}")
    %{state | client: client}
  end

  defp update_time(%FLAC.FrameMetadata{} = metadata, %FLAC{} = caps, state) do
    samples = state.samples + metadata.samples
    time = (samples * Time.second(1)) |> div(caps.sample_rate)
    %{state | samples: samples, time: time}
  end

  defp update_time(_metadata, _caps, state) do
    state
  end

  defp client_start_stream(client, caps, state) do
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
    :ok = client |> Client.send_request(request)
  end
end
