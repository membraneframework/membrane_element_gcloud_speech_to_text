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
  use Membrane.Log, tags: :membrane_element_gcloud_stt

  alias Membrane.Buffer
  alias Membrane.Caps.Audio.FLAC
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

  @demand_frames 5

  @impl true
  def handle_init(opts) do
    state =
      opts
      |> Map.update!(:model, &Atom.to_string/1)
      |> Map.merge(%{
        client: nil,
        old_client: nil,
        init_time: nil,
        samples: 0
      })

    {:ok, state}
  end

  @impl true
  def handle_stopped_to_prepared(_ctx, state) do
    client = start_client()
    {:ok, %{state | client: client}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    {{:ok, demand: {:input, @demand_frames}}, state}
  end

  @impl true
  def handle_playing_to_prepared(ctx, state) do
    actions =
      if ctx.pads.input.end_of_stream? do
        []
      else
        [stop_timer: :demand_timer]
      end

    {{:ok, actions}, state}
  end

  @impl true
  def handle_prepared_to_stopped(_ctx, state) do
    if state.client do
      state.client.monitor |> Process.demonitor([:flush])
      :ok = state.client.pid |> Client.stop()
    end

    if state.old_client do
      state.old_client.monitor |> Process.demonitor([:flush])
      :ok = state.old_client.pid |> Client.stop()
    end

    {:ok, %{state | client: nil, old_client: nil, samples: 0}}
  end

  @impl true
  def handle_caps(:input, %FLAC{} = caps, _ctx, state) do
    state = %{state | init_time: Time.monotonic_time()}

    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.to_milliseconds()
    )

    :ok = state.client |> client_start_stream(caps, state)

    # Usually max and min are the same (fixed-blocksize)
    avg_samples_num = round((caps.min_block_size + caps.max_block_size) / 2)
    demand_interval = samples_to_time(avg_samples_num, caps) * @demand_frames

    {{:ok, start_timer: {:demand_timer, demand_interval}}, state}
  end

  @impl true
  def handle_write_list(:input, buffer_list, _ctx, state) do
    {payloads, buffers_samples} =
      buffer_list
      |> Enum.map_reduce(0, fn %Buffer{payload: payload, metadata: metadata}, acc ->
        samples = metadata |> Map.get(:samples, 0)
        {payload, acc + samples}
      end)

    audio_content = Enum.join(payloads)

    state = %{state | samples: state.samples + buffers_samples}

    state =
      update_in(state.client.backup_queue, &SamplesQueue.push(&1, audio_content, buffers_samples))

    :ok =
      Client.send_request(
        state.client.pid,
        StreamingRecognizeRequest.new(streaming_request: {:audio_content, audio_content})
      )

    {:ok, state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    info("End of Stream")
    :ok = state.client.pid |> Client.end_stream()
    {{:ok, stop_timer: :demand_timer}, state}
  end

  @impl true
  def handle_tick(:demand_timer, %{playback_state: :playing} = ctx, state) do
    caps = ctx.pads.input.caps
    streamed_audio_time = samples_to_time(state.samples, caps)
    time_to_demand = (Time.monotonic_time() - (state.init_time + streamed_audio_time)) |> max(0)
    samples_to_demand = time_to_samples(time_to_demand, caps)

    frames_to_demand =
      if caps.min_block_size != nil and caps.min_block_size > 0 do
        avg_samples_num = round((caps.min_block_size + caps.max_block_size) / 2)
        ceil(samples_to_demand / avg_samples_num)
      else
        @demand_frames
      end

    {{:ok, demand: {:input, frames_to_demand}}, state}
  end

  def handle_tick(:demand_timer, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_other({from, %StreamingRecognizeResponse{} = response}, ctx, state) do
    caps = ctx.pads.input.caps
    streamed_audio_time = samples_to_time(state.samples, caps)
    log_prefix = "[#{inspect(from)}] [#{streamed_audio_time |> Time.to_milliseconds()}]"

    state =
      if response.results |> Enum.empty?() do
        state
      else
        received_end_time =
          response.results
          |> Enum.map(&(&1.result_end_time |> Time.nanosecond()))
          |> Enum.max()

        delay = streamed_audio_time - received_end_time

        info("#{log_prefix} Recognize response delay: #{delay |> Time.to_milliseconds()} ms")

        update_client_queue(state, from, caps, received_end_time)
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
  def handle_other(:start_new_client, %{pads: %{input: %{caps: nil}}}, state) do
    # Streaming haven't started, just reschedule client swap
    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.to_milliseconds()
    )

    {:ok, state}
  end

  @impl true
  def handle_other(:start_new_client, ctx, %{client: old_client} = state) do
    :ok = old_client.pid |> Client.end_stream()
    caps = ctx.pads.input.caps
    overlap_samples = state.reconnection_overlap_time |> time_to_samples(caps)
    start_from_sample = (state.samples - overlap_samples) |> max(0)

    new_queue =
      old_client.backup_queue
      |> SamplesQueue.peek_by_samples(overlap_samples)
      |> SamplesQueue.from_list()

    client = start_client(caps, start_from_sample, new_queue)
    state = %{state | client: client}

    Process.send_after(
      self(),
      :start_new_client,
      state.streaming_time_limit |> Time.to_milliseconds()
    )

    Process.send_after(
      self(),
      {:stop_old_client, old_client.pid, old_client.monitor},
      state.results_await_time |> Time.to_milliseconds()
    )

    :ok = client_start_stream(client, caps, state)

    {:ok, %{state | old_client: old_client}}
  end

  @impl true
  def handle_other({:stop_old_client, pid, monitor}, _ctx, state) do
    if Process.alive?(pid) do
      monitor |> Process.demonitor([:flush])
      pid |> Client.stop()

      info(
        "Stopped client: #{inspect(pid)}, " <>
          "current old_client: #{inspect(state.old_client && state.old_client.pid)}"
      )

      state =
        if state.old_client != nil and state.old_client.pid == pid do
          %{state | old_client: nil}
        else
          state
        end

      {:ok, state}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_other(
        {:DOWN, _ref, :process, pid, reason},
        ctx,
        %{client: %{pid: pid} = dead_client} = state
      ) do
    warn("Client #{inspect(pid)} down with reason: #{inspect(reason)}")
    caps = ctx.pads.input.caps

    client = start_client(caps, dead_client.queue_start, dead_client.backup_queue)

    state = %{state | client: client}

    unless caps == nil do
      :ok = client_start_stream(client, caps, state)
    end

    {:ok, state}
  end

  @impl true
  def handle_other(
        {:DOWN, _ref, :process, pid, reason},
        ctx,
        %{old_client: %{pid: pid} = dead_client} = state
      ) do
    info("Old client #{inspect(pid)} down with reason #{inspect(reason)}")
    caps = ctx.pads.input.caps

    limit = 1 |> Time.second() |> time_to_samples(caps)
    unrecognized_samples = dead_client.backup_queue |> SamplesQueue.samples()

    if unrecognized_samples > limit do
      info("Restarting old client #{inspect(pid)} from #{inspect(dead_client.queue_start)}}")
      client = start_client(caps, dead_client.queue_start, dead_client.backup_queue)

      state = %{state | old_client: client}

      :ok = client_start_stream(client, caps, state)
      :ok = client.pid |> Client.end_stream()

      Process.send_after(
        self(),
        {:stop_old_client, client.pid, client.monitor},
        state.results_await_time |> Time.to_milliseconds()
      )

      {:ok, state}
    else
      # We're close enough to the end, don't restart the client
      info(
        "Not restarting old client #{inspect(pid)}, it (most likely) received all transcriptions"
      )

      {:ok, %{state | old_client: nil}}
    end
  end

  defp start_client() do
    do_start_client(0)
  end

  defp start_client(caps, start_sample, queue) do
    start_time =
      case caps do
        nil -> 0
        %FLAC{} -> samples_to_time(start_sample, caps)
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

    info(
      "Started new client: #{inspect(client_pid)}, " <>
        "start_time: #{start_time |> Time.to_milliseconds()}"
    )

    %{
      pid: client_pid,
      queue_start: queue_start,
      backup_queue: queue,
      monitor: monitor
    }
  end

  defp samples_to_time(samples, %FLAC{} = caps) do
    (samples * Time.second(1)) |> div(caps.sample_rate)
  end

  defp time_to_samples(time, %FLAC{} = caps) do
    (time * caps.sample_rate)
    |> div(1 |> Time.second())
  end

  defp client_start_stream(client, caps, state) do
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
    :ok = client.pid |> Client.send_request(request)

    payload =
      client.backup_queue
      |> SamplesQueue.payloads()
      |> Enum.join()

    Client.send_request(
      client.pid,
      StreamingRecognizeRequest.new(streaming_request: {:audio_content, payload})
    )
  end

  defp update_client_queue(state, from, caps, received_end_time) do
    cond do
      state.client != nil and state.client.pid == from ->
        %{state | client: do_update_client_queue(state.client, caps, received_end_time)}

      state.old_client != nil and state.old_client.pid == from ->
        %{state | old_client: do_update_client_queue(state.old_client, caps, received_end_time)}

      true ->
        raise "This should not happen, #{inspect(__MODULE__)} is bugged!"
    end
  end

  defp do_update_client_queue(%{backup_queue: queue, queue_start: start} = client, caps, end_time) do
    start_time = start |> samples_to_time(caps)
    samples_to_drop = (end_time - start_time) |> time_to_samples(caps)
    {dropped_samples, backup_queue} = queue |> SamplesQueue.drop_old_samples(samples_to_drop)
    %{client | backup_queue: backup_queue, queue_start: start + dropped_samples}
  end
end
