defmodule Membrane.Element.GCloud.SpeechToText.TimedQueueTest do
  use ExUnit.Case, async: true

  alias Membrane.Element.GCloud.SpeechToText.TimedQueue

  test "new without arguments" do
    result = TimedQueue.new()
    assert result.q |> Enum.to_list() == []
    assert result.total_duration == 0
    assert result.duration_limit == :infinity
  end

  test "new with options" do
    result = TimedQueue.new(duration_limit: 100)
    assert result.q |> Enum.to_list() == []
    assert result.total_duration == 0
    assert result.duration_limit == 100
  end

  test "push to empty queue" do
    result =
      TimedQueue.new()
      |> TimedQueue.push("a", 50)

    assert %TimedQueue{} = result
    assert Enum.to_list(result.q) == [{50, "a"}]
    assert result.total_duration == 50
  end

  test "push beyond duration_limit" do
    result =
      TimedQueue.new(duration_limit: 100)
      |> TimedQueue.push("a", 50)
      |> TimedQueue.push("b", 30)
      |> TimedQueue.push("c", 15)
      |> TimedQueue.push("d", 40)

    assert %TimedQueue{} = result
    assert Enum.to_list(result.q) == [{30, "b"}, {15, "c"}, {40, "d"}]
    assert result.total_duration == 85
    assert result.duration_limit == 100

    result = result |> TimedQueue.push("e", 15)
    assert %TimedQueue{} = result
    assert Enum.to_list(result.q) == [{30, "b"}, {15, "c"}, {40, "d"}, {15, "e"}]
    assert result.total_duration == 100
    assert result.duration_limit == 100

    result = result |> TimedQueue.push("f", 1)
    assert %TimedQueue{} = result
    assert Enum.to_list(result.q) == [{15, "c"}, {40, "d"}, {15, "e"}, {1, "f"}]
    assert result.total_duration == 71
    assert result.duration_limit == 100

    result = result |> TimedQueue.push("g", 100)
    assert %TimedQueue{} = result
    assert Enum.to_list(result.q) == [{100, "g"}]
    assert result.total_duration == 100
    assert result.duration_limit == 100

    result = result |> TimedQueue.push("h", 101)
    assert %TimedQueue{} = result
    assert Enum.to_list(result.q) == []
    assert result.total_duration == 0
    assert result.duration_limit == 100
  end

  test "pop_by_time" do
    tq =
      TimedQueue.new(duration_limit: 150)
      |> TimedQueue.push("a", 50)
      |> TimedQueue.push("b", 30)
      |> TimedQueue.push("c", 15)
      |> TimedQueue.push("d", 40)

    assert {{:values, res}, new_tq} = tq |> TimedQueue.pop_by_time(50)
    assert res == ["a"]
    assert Enum.to_list(new_tq.q) == [{30, "b"}, {15, "c"}, {40, "d"}]
    assert new_tq.total_duration == 85

    assert {{:values, res}, new_tq} = tq |> TimedQueue.pop_by_time(51)
    assert res == ["a", "b"]
    assert Enum.to_list(new_tq.q) == [{15, "c"}, {40, "d"}]
    assert new_tq.total_duration == 55

    assert {{:values, res}, new_tq} = tq |> TimedQueue.pop_by_time(135)
    assert res == ["a", "b", "c", "d"]
    assert Enum.to_list(new_tq.q) == []
    assert new_tq.total_duration == 0

    assert {{:empty, res}, new_tq} = tq |> TimedQueue.pop_by_time(140)
    assert res == ["a", "b", "c", "d"]
    assert Enum.to_list(new_tq.q) == []
    assert new_tq.total_duration == 0
  end
end
