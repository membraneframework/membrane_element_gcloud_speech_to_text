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

  test "peek_by_samples" do
    sq =
      SamplesQueue.new(limit: 150)
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)
      |> SamplesQueue.push("d", 40)

    assert sq |> SamplesQueue.peek_by_samples(0) == []
    assert sq |> SamplesQueue.peek_by_samples(39) == []
    assert sq |> SamplesQueue.peek_by_samples(40) == [{40, "d"}]
    assert sq |> SamplesQueue.peek_by_samples(54) == [{40, "d"}]
    assert sq |> SamplesQueue.peek_by_samples(55) == [{15, "c"}, {40, "d"}]
    assert sq |> SamplesQueue.peek_by_samples(135) == [{50, "a"}, {30, "b"}, {15, "c"}, {40, "d"}]
    assert sq |> SamplesQueue.peek_by_samples(200) == [{50, "a"}, {30, "b"}, {15, "c"}, {40, "d"}]
  end

  test "drop_old_samples" do
    sq =
      SamplesQueue.new(limit: 150)
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)
      |> SamplesQueue.push("d", 40)

    assert {0, new_sq} = sq |> SamplesQueue.drop_old_samples(49)
    assert Enum.to_list(new_sq.q) == [{50, "a"}, {30, "b"}, {15, "c"}, {40, "d"}]
    assert new_sq.total == 135

    assert {50, new_sq} = sq |> SamplesQueue.drop_old_samples(50)
    assert Enum.to_list(new_sq.q) == [{30, "b"}, {15, "c"}, {40, "d"}]
    assert new_sq.total == 85

    assert {50, new_sq} = sq |> SamplesQueue.drop_old_samples(51)
    assert Enum.to_list(new_sq.q) == [{30, "b"}, {15, "c"}, {40, "d"}]
    assert new_sq.total == 85

    assert {135, new_sq} = sq |> SamplesQueue.drop_old_samples(135)
    assert Enum.to_list(new_sq.q) == []
    assert new_sq.total == 0

    assert {135, new_sq} = sq |> SamplesQueue.drop_old_samples(140)
    assert Enum.to_list(new_sq.q) == []
    assert new_sq.total == 0
  end

  test "payloads/1" do
    sq = SamplesQueue.new()
    assert sq |> SamplesQueue.payloads() == []

    sq =
      sq
      |> SamplesQueue.push("a", 50)
      |> SamplesQueue.push("b", 30)
      |> SamplesQueue.push("c", 15)

    assert sq |> SamplesQueue.payloads() == ["a", "b", "c"]
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

    test "drop_old_samples", %{empty: empty} do
      assert empty |> SamplesQueue.drop_old_samples(20) == {0, empty}
    end

    test "payloads", %{empty: empty} do
      assert empty |> SamplesQueue.payloads() == []
    end

    test "flush", %{empty: empty} do
      assert {[], new_queue} = empty |> SamplesQueue.flush()
      assert new_queue == empty
    end
  end
end
