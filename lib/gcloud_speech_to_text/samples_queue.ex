defmodule Membrane.Element.GCloud.SpeechToText.SamplesQueue do
  @moduledoc false

  alias Membrane.Payload

  @type samples_num :: non_neg_integer()

  defstruct q: Qex.new(), total: 0, limit: :infinity

  @opaque t :: %__MODULE__{
            q: Qex.t({samples_num(), Payload.t()}),
            total: samples_num(),
            limit: :infinity | samples_num()
          }

  @doc """
  Creates a new SamplesQueue. Allows do provide `:limit` option that
  determine maximal amount of samples stored in a queue.
  """
  @spec new(Keyword.t()) :: t()
  def new(opts \\ []) do
    args = opts |> Keyword.take([:limit])
    struct!(__MODULE__, args)
  end

  @doc """
  Returns total number of samples in payloads stored in a queue.
  """
  @spec samples(t()) :: samples_num()
  def samples(%__MODULE__{total: samples}) do
    samples
  end

  @doc """
  Puts the payload in a queue with a number of samples it contains.

  If the total number of samples stored in this queue would rise above
  the defined `:limit`, the oldest payloads are dropped.

  If the number of samples in the pushed payload is greater than `:limit`, the queue will become empty!
  """
  @spec push(t(), Payload.t(), samples_num()) :: t()
  def push(%__MODULE__{q: q, total: total_samples} = timed_queue, payload, samples) do
    q = q |> Qex.push({samples, payload})
    total_samples = total_samples + samples

    %{timed_queue | q: q, total: total_samples}
    |> pop_until_limit()
  end

  defp pop_until_limit(%__MODULE__{total: samples, limit: limit} = tq)
       when samples <= limit do
    tq
  end

  defp pop_until_limit(%__MODULE__{total: total_samples, limit: limit} = tq)
       when total_samples > limit do
    {{samples, _}, q} = Qex.pop!(tq.q)
    %{tq | q: q, total: total_samples - samples} |> pop_until_limit()
  end

  @doc """
  Pops payloads from the queue with a total number of samples greater than the provided number.

  Returns `{{:empty, [payloads]}, timed_queue` if there wasn't enough data stored in queue to provide the requested number of samples, `{{:values, [payloads]}, timed_queue}` otherwise.
  """
  @spec pop_by_samples(t(), samples_num()) :: {{:empty | :values, [Payload.t()]}, t()}
  def pop_by_samples(%__MODULE__{} = timed_queue, samples) do
    do_pop_by_samples(timed_queue, samples)
  end

  defp do_pop_by_samples(timed_queue, samples, acc \\ [])

  defp do_pop_by_samples(%__MODULE__{} = timed_queue, samples, acc) when samples <= 0 do
    {{:values, acc |> Enum.reverse()}, timed_queue}
  end

  defp do_pop_by_samples(%__MODULE__{q: q} = timed_queue, samples_to_pop, acc) do
    {popped, q} = q |> Qex.pop()
    timed_queue = timed_queue |> Map.put(:q, q)

    case popped do
      :empty ->
        {{:empty, acc |> Enum.reverse()}, timed_queue}

      {:value, {samples, payload}} ->
        timed_queue
        |> Map.update!(:total, &(&1 - samples))
        |> do_pop_by_samples(samples_to_pop - samples, [payload | acc])
    end
  end

  @doc """
  Returns a list of payloads stored in a queue
  """
  @spec to_list(t()) :: [Payload.t()]
  def to_list(%__MODULE__{q: q}) do
    q |> Enum.to_list() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns a list of payloads stored in a queue and makes the queue empty.
  """
  @spec flush(t()) :: {[Payload.t()], t()}
  def flush(%__MODULE__{} = tq) do
    payloads = tq |> to_list()
    {payloads, %{tq | q: Qex.new(), total: 0}}
  end
end
