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

  use Membrane.Sink
  require Membrane.Logger

  alias __MODULE__.SamplesQueue
  alias GCloud.SpeechAPI.Streaming.Client
  alias Membrane.FLAC

  alias Google.Cloud.Speech.V1.{
    RecognitionConfig,
    SpeechContext,
    StreamingRecognitionConfig,
    StreamingRecognizeRequest,
    StreamingRecognizeResponse
  }

  alias Membrane.Time

  def_input_pad :input,
    accepted_format: FLAC,
    flow_control: :manual,
    demand_unit: :buffers

  def_options language_code: [
                spec: String.t(),
                default: "en-US",
                description: """
                The language of the supplied audio.
                See [Language Support](https://cloud.google.com/speech-to-text/docs/languages)
                for a list of supported languages codes.
                """
              ],
              interim_results: [
                spec: boolean(),
                default: false,
                description: """
                If set to true, the interim results may be returned by recognition API.
                See [Google API docs](https://cloud.google.com/speech-to-text/docs/reference/rpc/google.cloud.speech.v1#google.cloud.speech.v1.StreamingRecognitionConfig)
                for more info.
                """
              ],
              word_time_offsets: [
                spec: boolean(),
                default: false,
                description: """
                If `true`, the top result includes a list of words and the start and end time offsets (timestamps) for those words.
                """
              ],
              speech_contexts: [
                spec: [%SpeechContext{}],
                default: [],
                description: """
                A list of speech recognition contexts. See [the docs](https://cloud.google.com/speech-to-text/docs/reference/rpc/google.cloud.speech.v1#google.cloud.speech.v1.RecognitionConfig)
                for more info.
                """
              ],
              model: [
                spec: :default | :video | :phone_call | :command_and_search,
                default: :default,
                description: """
                Model used for speech recognition. Bear in mind that `:video` model
                is a premium model that costs more than the standard rate.
                """
              ],
              streaming_time_limit: [
                spec: Time.t(),
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
                spec: Time.t(),
                default: 90 |> Time.seconds(),
                description: """
                The amount of time a client that stopped streaming is kept alive
                awaiting results from recognition API.
                """
              ],
              reconnection_overlap_time: [
                spec: Time.t(),
                default: 2 |> Time.seconds(),
                description: """
                Duration of audio re-sent in a new client session after reconnection
                """
              ]

  @demand_frames 5
  @timer_name :demand_timer

  @impl true
  def handle_init(_ctx, opts) do
    state =
      opts
      |> Map.update!(:model, &Atom.to_string/1)
      |> Map.merge(%{
        client: nil,
        old_client: nil,
        init_time: nil,
        samples: 0,
        timer_started: false
      })

    {[], state}
  end

  @impl true
  def handle_setup(_ctx, state) do
    client = start_client()
    {[], %{state | client: client}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[demand: {:input, @demand_frames}], state}
  end

  @impl true
  def handle_terminate_request(_ctx, state) do
    if state.client do
      state.client.monitor |> Process.demonitor([:flush])
      :ok = state.client.pid |> Client.stop()
    end

    if state.old_client do
      state.old_client.monitor |> Process.demonitor([:flush])
      :ok = state.old_client.pid |> Client.stop()
    end

    {[terminate: :normal], %{state | client: nil, old_client: nil, samples: 0}}
  end

  @impl true
  def handle_stream_format(:input, %FLAC{} = stream_format, _ctx, state) do
    state = %{state | init_time: Time.monotonic_time()}

    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.as_milliseconds()
    )

    :ok = state.client |> client_start_stream(stream_format, state)

    # Usually max and min are the same (fixed-blocksize)
    avg_samples_num = round((stream_format.min_block_size + stream_format.max_block_size) / 2)
    demand_interval = samples_to_time(avg_samples_num, stream_format) * @demand_frames

    {[start_timer: {@timer_name, demand_interval}], %{state | timer_started: true}}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    audio_content = buffer.payload
    samples = Map.get(buffer.metadata, :samples, 0)
    state = %{state | samples: state.samples + samples}

    state =
      update_in(state.client.backup_queue, &SamplesQueue.push(&1, audio_content, samples))

    :ok =
      Client.send_request(
        state.client.pid,
        StreamingRecognizeRequest.new(streaming_request: {:audio_content, audio_content})
      )

    {[], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    Membrane.Logger.info("End of Stream")
    :ok = state.client.pid |> Client.end_stream()

    if state.timer_started do
      {[stop_timer: @timer_name], %{state | timer_started: false}}
    else
      {[], state}
    end
  end

  @impl true
  def handle_tick(:demand_timer, %{playback_state: :playing} = ctx, state) do
    stream_format = ctx.pads.input.stream_format
    streamed_audio_time = samples_to_time(state.samples, stream_format)
    time_to_demand = (Time.monotonic_time() - (state.init_time + streamed_audio_time)) |> max(0)
    samples_to_demand = time_to_samples(time_to_demand, stream_format)

    frames_to_demand =
      if stream_format.min_block_size != nil and stream_format.min_block_size > 0 do
        avg_samples_num = round((stream_format.min_block_size + stream_format.max_block_size) / 2)
        ceil(samples_to_demand / avg_samples_num)
      else
        @demand_frames
      end

    {[demand: {:input, frames_to_demand}], state}
  end

  def handle_tick(:demand_timer, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_info({from, %StreamingRecognizeResponse{} = response}, ctx, state) do
    stream_format = ctx.pads.input.stream_format
    streamed_audio_time = samples_to_time(state.samples, stream_format)
    log_prefix = "[#{inspect(from)}] [#{streamed_audio_time |> Time.as_milliseconds()}]"

    state =
      if response.results |> Enum.empty?() do
        state
      else
        received_end_time =
          response.results
          |> Enum.map(&(&1.result_end_time |> Time.nanoseconds()))
          |> Enum.max()

        delay = streamed_audio_time - received_end_time

        Membrane.Logger.info(
          "#{log_prefix} Recognize response delay: #{delay |> Time.as_milliseconds()} ms"
        )

        update_client_queue(state, from, stream_format, received_end_time)
      end

    if response.error != nil do
      Membrane.Logger.warning("#{log_prefix}: #{inspect(response.error)}")

      {[], state}
    else
      {[notify_parent: response], state}
    end
  end

  @impl true
  def handle_info(:start_new_client, %{pads: %{input: %{end_of_stream?: true}}}, state) do
    {[], state}
  end

  @impl true
  def handle_info(:start_new_client, %{pads: %{input: %{stream_format: nil}}}, state) do
    # Streaming haven't started, just reschedule client swap
    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.as_milliseconds()
    )

    {[], state}
  end

  @impl true
  def handle_info(:start_new_client, ctx, %{client: old_client} = state) do
    :ok = old_client.pid |> Client.end_stream()
    stream_format = ctx.pads.input.stream_format
    overlap_samples = state.reconnection_overlap_time |> time_to_samples(stream_format)
    start_from_sample = (state.samples - overlap_samples) |> max(0)

    new_queue =
      old_client.backup_queue
      |> SamplesQueue.peek_by_samples(overlap_samples)
      |> SamplesQueue.from_list()

    client = start_client(stream_format, start_from_sample, new_queue)
    state = %{state | client: client}

    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.as_milliseconds()
    )

    Process.send_after(
      self(),
      {:stop_old_client, old_client.pid, old_client.monitor},
      state.results_await_time |> Time.as_milliseconds()
    )

    :ok = client_start_stream(client, stream_format, state)

    {[], %{state | old_client: old_client}}
  end

  @impl true
  def handle_info({:stop_old_client, pid, monitor}, _ctx, state) do
    if Process.alive?(pid) do
      monitor |> Process.demonitor([:flush])
      pid |> Client.stop()

      Membrane.Logger.info(
        "Stopped client: #{inspect(pid)}, " <>
          "current old_client: #{inspect(state.old_client && state.old_client.pid)}"
      )

      state =
        if state.old_client != nil and state.old_client.pid == pid do
          %{state | old_client: nil}
        else
          state
        end

      {[], state}
    else
      {[], state}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        ctx,
        %{client: %{pid: pid} = dead_client} = state
      ) do
    Membrane.Logger.warning("Client #{inspect(pid)} down with reason: #{inspect(reason)}")
    stream_format = ctx.pads.input.stream_format

    client = start_client(stream_format, dead_client.queue_start, dead_client.backup_queue)

    state = %{state | client: client}

    unless stream_format == nil do
      :ok = client_start_stream(client, stream_format, state)
    end

    {[], state}
  end

  @impl true
  def handle_info(
        {:DOWN, _ref, :process, pid, reason},
        ctx,
        %{old_client: %{pid: pid} = dead_client} = state
      ) do
    Membrane.Logger.info("Old client #{inspect(pid)} down with reason #{inspect(reason)}")
    stream_format = ctx.pads.input.stream_format

    limit = Time.second() |> time_to_samples(stream_format)
    unrecognized_samples = dead_client.backup_queue |> SamplesQueue.samples()

    if unrecognized_samples > limit do
      Membrane.Logger.info(
        "Restarting old client #{inspect(pid)} from #{inspect(dead_client.queue_start)}}"
      )

      client = start_client(stream_format, dead_client.queue_start, dead_client.backup_queue)

      state = %{state | old_client: client}

      :ok = client_start_stream(client, stream_format, state)
      :ok = client.pid |> Client.end_stream()

      Process.send_after(
        self(),
        {:stop_old_client, client.pid, client.monitor},
        state.results_await_time |> Time.as_milliseconds()
      )

      {[], state}
    else
      # We're close enough to the end, don't restart the client
      Membrane.Logger.info(
        "Not restarting old client #{inspect(pid)}, it (most likely) received all transcriptions"
      )

      {[], %{state | old_client: nil}}
    end
  end

  defp start_client() do
    do_start_client(0)
  end

  defp start_client(stream_format, start_sample, queue) do
    start_time =
      case stream_format do
        nil -> 0
        %FLAC{} -> samples_to_time(start_sample, stream_format)
      end

    do_start_client(start_time, queue, start_sample)
  end

  defp do_start_client(start_time, queue \\ SamplesQueue.new(), queue_start \\ 0) do
    # It seems Google Speech is using low accuracy when providing time offsets
    # for the recognized words. In order to keep them aligned between client
    # sessions, we need to round the offset
    accuracy = Time.milliseconds(100)
    rounded_start_time = start_time |> Kernel./(accuracy) |> round() |> Kernel.*(accuracy)

    {:ok, client_pid} =
      Client.start(start_time: rounded_start_time, monitor_target: true, include_sender: true)

    monitor = Process.monitor(client_pid)

    Membrane.Logger.info(
      "Started new client: #{inspect(client_pid)}, " <>
        "start_time: #{start_time |> Time.as_milliseconds()}"
    )

    %{
      pid: client_pid,
      queue_start: queue_start,
      backup_queue: queue,
      monitor: monitor
    }
  end

  defp samples_to_time(samples, %FLAC{} = stream_format) do
    (samples * Time.second()) |> div(stream_format.sample_rate)
  end

  defp time_to_samples(time, %FLAC{} = stream_format) do
    (time * stream_format.sample_rate)
    |> div(Time.second())
  end

  defp client_start_stream(client, stream_format, state) do
    cfg =
      RecognitionConfig.new(
        encoding: :FLAC,
        sample_rate_hertz: stream_format.sample_rate,
        audio_channel_count: stream_format.channels,
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

    cfg_request = StreamingRecognizeRequest.new(streaming_request: {:streaming_config, str_cfg})

    payload =
      client.backup_queue
      |> SamplesQueue.payloads()
      |> Enum.join()

    requests =
      if byte_size(payload) > 0 do
        [cfg_request, StreamingRecognizeRequest.new(streaming_request: {:audio_content, payload})]
      else
        [cfg_request]
      end

    Client.send_requests(client.pid, requests)
  end

  defp update_client_queue(state, from, stream_format, received_end_time) do
    cond do
      state.client != nil and state.client.pid == from ->
        %{state | client: do_update_client_queue(state.client, stream_format, received_end_time)}

      state.old_client != nil and state.old_client.pid == from ->
        %{
          state
          | old_client: do_update_client_queue(state.old_client, stream_format, received_end_time)
        }

      true ->
        raise "This should not happen, #{inspect(__MODULE__)} is bugged!"
    end
  end

  defp do_update_client_queue(
         %{backup_queue: queue, queue_start: start} = client,
         stream_format,
         end_time
       ) do
    start_time = start |> samples_to_time(stream_format)
    samples_to_drop = (end_time - start_time) |> time_to_samples(stream_format)
    {dropped_samples, backup_queue} = queue |> SamplesQueue.drop_old_samples(samples_to_drop)
    %{client | backup_queue: backup_queue, queue_start: start + dropped_samples}
  end
end
