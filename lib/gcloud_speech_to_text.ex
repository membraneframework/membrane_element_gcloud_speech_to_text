defmodule Membrane.Element.GCloud.SpeechToText do
  @moduledoc """
  An element providing speech recognition via Google Cloud Speech To Text service
  using Streaming API.

  The element has to handle a connection time limit (currently 5 minutes). It does that
  by spawning multiple streaming clients - the streaming is stopped after `streaming_time_limit` (see `t:t/0`) and a new client that starts streaming is spawned. The old one is kept alive for `results_await_time` and will receive recognition results for the streamed audio.

  This means that first results from the new client might arrive before the last result
  from an old client.

  Bear in mind that `streaming_time_limit` + `results_await_time` must
  be smaller than recognition time limit for Google Streaming API
  (currently 5 minutes)
  """

  use Membrane.Element.Base.Sink
  use Membrane.Log, tags: :membrane_element_gcloud_stt

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.FLAC
  alias Membrane.Event.EndOfStream
  alias Membrane.Time
  alias GCloud.SpeechAPI.Streaming.Client

  alias Membrane.Element.GCloud.SpeechToText.SamplesQueue

  alias Google.Cloud.Speech.V1.{
    RecognitionConfig,
    SpeechContext,
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
              word_time_offsets: [
                type: :boolean,
                default: false,
                description: """
                If `true`, the top result includes a list of words and the start and end time offsets (timestamps) for those words.
                """
              ],
              speech_contexts: [
                type: :list,
                spec: [%SpeechContext{}],
                default: [],
                description: """
                A list of speech recognition contexts. See [the docs](https://cloud.google.com/speech-to-text/docs/reference/rpc/google.cloud.speech.v1#google.cloud.speech.v1.RecognitionConfig)
                for more info.
                """
              ],
              model: [
                type: :atom,
                spec: :default | :video | :phone_call | :command_and_search,
                default: :default,
                description: """
                Model used for speech recognition. Bear in mind that `:video` model
                is a premium model that costs more than the standard rate.
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
              ],
              reconnection_overlap_time: [
                type: :time,
                default: 2 |> Time.seconds(),
                description: """
                Duration of audio re-sent in a new client session after reconnection
                """
              ]

  @impl true
  def handle_init(opts) do
    state =
      opts
      |> Map.update!(:model, &Atom.to_string/1)
      |> Map.merge(%{
        client: nil,
        client_monitor: nil,
        old_client: nil,
        init_time: nil,
        samples: 0,
        overlap_queue: nil
      })

    {:ok, state}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    state = start_client(state, nil)
    {:ok, state}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: :input}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    :ok = state.client |> Client.stop()
    {:ok, %{state | client: nil, samples: 0}}
  end

  @impl true
  def handle_caps(:input, %FLAC{} = caps, _ctx, state) do
    samples_limit = state.reconnection_overlap_time |> time_to_samples(caps)
    queue = SamplesQueue.new(limit: samples_limit)
    state = %{state | init_time: Time.os_time(), overlap_queue: queue}

    :ok = state.client |> client_start_stream(caps, state)

    {:ok, state}
  end

  @impl true
  def handle_write(:input, %Buffer{payload: payload, metadata: metadata}, ctx, state) do
    caps = ctx.pads.input.caps
    buffer_samples = metadata |> Map.get(:samples, 0)
    state = %{state | samples: state.samples + buffer_samples}
    streamed_audio_time = samples_to_time(state.samples, caps)

    demand_time =
      (state.init_time + streamed_audio_time - Time.os_time()) |> max(0) |> Time.to_milliseconds()

    Process.send_after(self(), :demand_frame, demand_time)

    q = state.overlap_queue |> SamplesQueue.push(payload, buffer_samples)

    :ok =
      Client.send_request(
        state.client,
        StreamingRecognizeRequest.new(streaming_request: {:audio_content, payload})
      )

    {:ok, %{state | overlap_queue: q}}
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
  def handle_other(%StreamingRecognizeResponse{} = response, ctx, state) do
    caps = ctx.pads.input.caps
    streamed_audio_time = samples_to_time(state.samples, caps)
    log_prefix = "[#{inspect(state.client)}] [#{streamed_audio_time |> Time.to_milliseconds()}]"

    unless response.results |> Enum.empty?() do
      received_end_time =
        response.results
        |> Enum.map(&(&1.result_end_time |> Time.nanosecond()))
        |> Enum.max()

      delay = streamed_audio_time - received_end_time

      info("#{log_prefix} Recognize response delay: #{delay |> Time.to_milliseconds()} ms")
    end

    if response.error != nil do
      warn("#{log_prefix}: #{inspect(response.error)}")

      {:ok, state}
    else
      {{:ok, notify: response}, state}
    end
  end

  @impl true
  def handle_other(:start_new_client, %{pads: %{input: %{end_of_stream?: true}}}, state) do
    {:ok, state}
  end

  @impl true
  def handle_other(:start_new_client, ctx, %{client: old_client} = state) do
    :ok = old_client |> Client.end_stream()
    state.client_monitor |> Process.demonitor()
    start_from_sample = state.samples - SamplesQueue.samples(state.overlap_queue)
    state = start_client(state, ctx.pads.input.caps, start_from_sample)
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
    if Process.alive?(old_client) do
      old_client |> Client.stop()
      info("Stopped old client: #{inspect(old_client)}")
    end

    {:ok, state}
  end

  @impl true
  def handle_other({:DOWN, _ref, :process, pid, reason}, ctx, %{client: pid} = state) do
    warn("Client #{inspect(pid)} down with reason: #{inspect(reason)}")
    caps = ctx.pads.input.caps
    state = start_client(state, caps)
    :ok = state.client |> client_start_stream(caps, state)
    # TODO: audio re-upload
    {:ok, state}
  end

  @impl true
  def handle_other({:DOWN, _ref, :process, pid, reason}, _ctx, state) do
    info("Old client #{inspect(pid)} down with reason #{inspect(reason)}")
    {:ok, state}
  end

  defp start_client(state, caps) do
    start_client(state, caps, state.samples)
  end

  defp start_client(state, caps, start_from_sample) do
    start_time =
      if caps == nil do
        0
      else
        samples_to_time(start_from_sample, caps)
      end

    accuracy = Time.milliseconds(100)

    # It seems Google Speech is using low accuracy when providing time offsets
    # for the recognized words. In order to keep them aligned between client
    # sessions, we need to round the offset
    rounded_start_time = start_time |> Kernel./(accuracy) |> round() |> Kernel.*(accuracy)
    {:ok, client} = Client.start(start_time: rounded_start_time, monitor_target: true)
    monitor = Process.monitor(client)
    info("[#{start_time}] Started new client: #{inspect(client)}")
    %{state | client: client, client_monitor: monitor}
  end

  defp samples_to_time(samples, %FLAC{} = caps) do
    (samples * Time.second(1)) |> div(caps.sample_rate)
  end

  defp time_to_samples(time, %FLAC{} = caps) do
    (time * caps.sample_rate)
    |> div(1 |> Time.second())
  end

  defp client_start_stream(client, caps, state) do
    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.to_milliseconds()
    )

    cfg =
      RecognitionConfig.new(
        encoding: :FLAC,
        sample_rate_hertz: caps.sample_rate,
        audio_channel_count: caps.channels,
        language_code: state.language_code,
        speech_contexts: state.speech_contexts,
        enable_word_time_offsets: state.word_time_offsets,
        model: state.model
      )

    str_cfg =
      StreamingRecognitionConfig.new(
        config: cfg,
        interim_results: state.interim_results
      )

    request = StreamingRecognizeRequest.new(streaming_request: {:streaming_config, str_cfg})
    :ok = client |> Client.send_request(request)

    state.overlap_queue
    |> SamplesQueue.to_list()
    |> Enum.each(
      &Client.send_request(
        state.client,
        StreamingRecognizeRequest.new(streaming_request: {:audio_content, &1})
      )
    )
  end
end
