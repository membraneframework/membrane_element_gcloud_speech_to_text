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
  Drops payloads from the queue with a total number of samples lesser or equal to the provided number.

  In other words, marks the provided number of samples as disposable and drops the payloads
  that contain only disposable samples.

  Returns a tuple with the number of dropped samples and updated queue.
  """
  @spec drop_by_samples(t(), samples_num()) :: {samples_num(), t()}
  def drop_by_samples(%__MODULE__{} = timed_queue, samples) do
    do_pop_by_samples(timed_queue, samples)
  end

  defp do_pop_by_samples(%__MODULE__{q: q} = timed_queue, samples_to_drop, acc \\ 0) do
    {popped, new_q} = q |> Qex.pop()

    case popped do
      :empty ->
        {acc, timed_queue}

      {:value, {samples, _payload}} when samples_to_drop < samples ->
        {acc, timed_queue}

      {:value, {samples, _payload}} ->
        timed_queue
        |> Map.update!(:total, &(&1 - samples))
        |> Map.put(:q, new_q)
        |> do_pop_by_samples(samples_to_drop - samples, acc + samples)
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
