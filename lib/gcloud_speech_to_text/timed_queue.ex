defmodule Membrane.Element.GCloud.SpeechToText.TimedQueue do
  @moduledoc ""

  alias Membrane.{Payload, Time}

  defstruct q: Qex.new(), total_duration: 0, duration_limit: :infinity
  @opaque t :: %__MODULE__{q: Qex.t({Time.t(), Payload.t()}), total_duration: Time.t()}

  @doc """
  Creates a new TimedQueue. Allows do provide `:duration_limit` option that
  determine maximal duration of all payloads stored in a queue.
  """
  @spec new(Keyword.t()) :: t()
  def new(opts \\ []) do
    args = opts |> Keyword.take([:duration_limit])
    struct!(__MODULE__, args)
  end

  @doc """
  Puts the payload in a queue, along with info about its duration.

  If the total duration of payload stored in this queue would rise above
  the defined `duration_limit` the oldest payloads are dropped.

  If the duration of pushed payload is greater than `duration_limit`, the queue will become empty!
  """
  @spec push(t(), Membrane.Payload.t(), Time.t()) :: t()
  def push(%__MODULE__{q: q, total_duration: total_duration} = timed_queue, payload, duration) do
    q = q |> Qex.push({duration, payload})
    total_duration = total_duration + duration

    %{timed_queue | q: q, total_duration: total_duration}
    |> pop_until_limit()
  end

  defp pop_until_limit(%__MODULE__{total_duration: duration, duration_limit: limit} = tq)
       when duration <= limit do
    tq
  end

  defp pop_until_limit(%__MODULE__{total_duration: total_duration, duration_limit: limit} = tq)
       when total_duration > limit do
    {{duration, _}, q} = Qex.pop!(tq.q)
    %{tq | q: q, total_duration: total_duration - duration} |> pop_until_limit()
  end

  @doc """
  Pops payloads with duration sum greater than provided time from the queue.

  Returns `{{:empty, [payloads]}, timed_queue` if there wasn't enough data stored in queue to provide the requested duration, `{{:values, [payloads]}, timed_queue}` otherwise.
  """
  @spec pop_by_time(t(), Time.t()) :: {{:empty | :values, [Payload.t()]}, t()}
  def pop_by_time(%__MODULE__{} = timed_queue, time) do
    do_pop_by_time(timed_queue, time)
  end

  defp do_pop_by_time(timed_queue, time, acc \\ [])

  defp do_pop_by_time(%__MODULE__{} = timed_queue, time, acc) when time <= 0 do
    {{:values, acc |> Enum.reverse()}, timed_queue}
  end

  defp do_pop_by_time(%__MODULE__{q: q} = timed_queue, time, acc) do
    {popped, q} = q |> Qex.pop()
    timed_queue = timed_queue |> Map.put(:q, q)

    case popped do
      :empty ->
        {{:empty, acc |> Enum.reverse()}, timed_queue}

      {:value, {duration, payload}} ->
        timed_queue
        |> Map.update!(:total_duration, &(&1 - duration))
        |> do_pop_by_time(time - duration, [payload | acc])
    end
  end
end
