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

  @spec from_list([{samples_num(), Payload.t()}], Keyword.t()) :: t()
  def from_list(content, opts \\ []) do
    args = opts |> Keyword.take([:limit])

    total =
      content
      |> Enum.reduce(0, fn {samples, _payload}, acc ->
        acc + samples
      end)

    struct!(__MODULE__, args ++ [q: Qex.new(content), total: total])
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
  @spec drop_old_samples(t(), samples_num()) :: {samples_num(), t()}
  def drop_old_samples(%__MODULE__{} = timed_queue, samples) do
    do_drop_old_samples(timed_queue, samples)
  end

  defp do_drop_old_samples(%__MODULE__{q: q} = timed_queue, samples_to_drop, acc \\ 0) do
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
        |> do_drop_old_samples(samples_to_drop - samples, acc + samples)
    end
  end

  @doc """
  Returns the most recent payloads stored in queue containing at least provided number of samples.
  """
  @spec peek_by_samples(t(), samples_num()) :: [Payload.t()]
  def peek_by_samples(%__MODULE__{q: q}, samples) do
    do_peek(q, samples, [])
  end

  defp do_peek(_q, samples, acc) when samples <= 0 do
    acc
  end

  defp do_peek(q, samples, acc) do
    {popped, new_q} = q |> Qex.pop_back()

    case popped do
      :empty ->
        acc

      {:value, {popped_samples, _payload}} when popped_samples > samples ->
        acc

      {:value, {popped_samples, _payload} = entry} ->
        do_peek(new_q, samples - popped_samples, [entry | acc])
    end
  end

  @doc """
  Returns a list of payloads stored in a queue
  """
  @spec payloads(t()) :: [Payload.t()]
  def payloads(%__MODULE__{q: q}) do
    q |> Enum.to_list() |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Returns a list of payloads stored in a queue and makes the queue empty.
  """
  @spec flush(t()) :: {[Payload.t()], t()}
  def flush(%__MODULE__{} = tq) do
    payloads = tq |> payloads()
    {payloads, %{tq | q: Qex.new(), total: 0}}
  end
end
