defmodule Membrane.Element.GCloud.SpeechToText.SamplesQueueTest do
  use ExUnit.Case, async: true

  alias Membrane.Element.GCloud.SpeechToText.SamplesQueue

  test "new without arguments" do
    result = SamplesQueue.new()
    assert result.q |> Enum.to_list() == []
    assert result.total == 0
    assert result.limit == :infinity
  end

  test "new with options" do
    result = SamplesQueue.new(limit: 100)
    assert result.q |> Enum.to_list() == []
    assert result.total == 0
    assert result.limit == 100
  end

  test "push beyond limit" do
    result =
      SamplesQueue.new(limit: 100)
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)
      |> SamplesQueue.push("d", 40)

    assert %SamplesQueue{} = result
    assert Enum.to_list(result.q) == [{30, "b"}, {15, "c"}, {40, "d"}]
    assert result.total == 85
    assert result.limit == 100

    result = result |> SamplesQueue.push("e", 15)
    assert %SamplesQueue{} = result
    assert Enum.to_list(result.q) == [{30, "b"}, {15, "c"}, {40, "d"}, {15, "e"}]
    assert result.total == 100
    assert result.limit == 100

    result = result |> SamplesQueue.push("f", 1)
    assert %SamplesQueue{} = result
    assert Enum.to_list(result.q) == [{15, "c"}, {40, "d"}, {15, "e"}, {1, "f"}]
    assert result.total == 71
    assert result.limit == 100

    result = result |> SamplesQueue.push("g", 100)
    assert %SamplesQueue{} = result
    assert Enum.to_list(result.q) == [{100, "g"}]
    assert result.total == 100
    assert result.limit == 100

    result = result |> SamplesQueue.push("h", 101)
    assert %SamplesQueue{} = result
    assert Enum.to_list(result.q) == []
    assert result.total == 0
    assert result.limit == 100
  end

  test "pop_by_samples" do
    sq =
      SamplesQueue.new(limit: 150)
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)
      |> SamplesQueue.push("d", 40)

    assert {{:values, res}, new_sq} = sq |> SamplesQueue.pop_by_samples(50)
    assert res == ["a"]
    assert Enum.to_list(new_sq.q) == [{30, "b"}, {15, "c"}, {40, "d"}]
    assert new_sq.total == 85

    assert {{:values, res}, new_sq} = sq |> SamplesQueue.pop_by_samples(51)
    assert res == ["a", "b"]
    assert Enum.to_list(new_sq.q) == [{15, "c"}, {40, "d"}]
    assert new_sq.total == 55

    assert {{:values, res}, new_sq} = sq |> SamplesQueue.pop_by_samples(135)
    assert res == ["a", "b", "c", "d"]
    assert Enum.to_list(new_sq.q) == []
    assert new_sq.total == 0

    assert {{:empty, res}, new_sq} = sq |> SamplesQueue.pop_by_samples(140)
    assert res == ["a", "b", "c", "d"]
    assert Enum.to_list(new_sq.q) == []
    assert new_sq.total == 0
  end

  test "to_list" do
    sq = SamplesQueue.new()
    assert sq |> SamplesQueue.to_list() == []

    sq =
      sq
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)

    assert sq |> SamplesQueue.to_list() == ["a", "b", "c"]
  end

  test "flush" do
    empty = SamplesQueue.new(limit: 150)

    assert {[], new_queue} = empty |> SamplesQueue.flush()
    assert new_queue == empty

    sq =
      empty
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)

    assert {payload, new_queue} = sq |> SamplesQueue.flush()
    assert payload == ["a", "b", "c"]
    assert new_queue == empty
  end

  describe "empty queue: " do
    setup do
      [empty: SamplesQueue.new(limit: 150)]
    end

    test "push", %{empty: empty} do
      result = empty |> SamplesQueue.push("a", 50)

      assert %SamplesQueue{} = result
      assert Enum.to_list(result.q) == [{50, "a"}]
      assert result.total == 50
    end

    test "pop", %{empty: empty} do
      assert empty |> SamplesQueue.pop_by_samples(20) == {{:empty, []}, empty}
    end

    test "to_list", %{empty: empty} do
      assert empty |> SamplesQueue.to_list() == []
    end

    test "flush", %{empty: empty} do
      assert {[], new_queue} = empty |> SamplesQueue.flush()
      assert new_queue == empty
    end
  end
end
