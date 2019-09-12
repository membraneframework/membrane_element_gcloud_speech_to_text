defmodule Membrane.Element.GCloud.SpeechToText.IntegrationTest do
  use ExUnit.Case

  alias Google.Cloud.Speech.V1.{
    StreamingRecognizeResponse,
    StreamingRecognitionResult,
    SpeechRecognitionAlternative,
    WordInfo
  }

  alias Membrane.Time

  @moduletag :external

  @fixture_path "../fixtures/sample.flac" |> Path.expand(__DIR__)
  @fixture_duration 7_270 |> Time.milliseconds() |> Time.to_nanoseconds()

  test "recognition pipeline provides transcription of short file" do
    assert {:ok, pid} = RecognitionPipeline.start_link([@fixture_path, self(), []])
    assert :ok = RecognitionPipeline.play(pid)

    assert_receive :end_of_upload, 10_000

    assert_receive %StreamingRecognizeResponse{} = response, 10_000
    assert response.error == nil
    assert [%StreamingRecognitionResult{} = res] = response.results

    assert res.is_final == true
    assert res.result_end_time == 7_270_000_000
    assert [%SpeechRecognitionAlternative{} = alt] = res.alternatives

    assert alt.confidence > 0.95

    assert alt.transcript ==
             "Adventure 1 a scandal in Bohemia from the Adventures of Sherlock Holmes by Sir Arthur Conan Doyle"

    first_word = alt.words |> hd()
    last_word = alt.words |> Enum.reverse() |> hd()

    assert first_word == %WordInfo{
             start_time: 100_000_000,
             end_time: 1_400_000_000,
             word: "Adventure"
           }

    assert last_word == %WordInfo{
             start_time: 6_900_000_000,
             end_time: 7_200_000_000,
             word: "Doyle"
           }
  end

  test "recognition pipeline uses overlap when reconnecting" do
    streaming_time_limit = 6 |> Time.seconds()

    element_opts = [
      streaming_time_limit: streaming_time_limit,
      reconnection_overlap_time: 2 |> Time.seconds()
    ]

    assert {:ok, pid} = RecognitionPipeline.start_link([@fixture_path, self(), element_opts])

    assert :ok = RecognitionPipeline.play(pid)

    assert_receive :end_of_upload, 10_000

    assert_receive %StreamingRecognizeResponse{} = response, 10_000
    assert response.error == nil
    assert [%StreamingRecognitionResult{} = res] = response.results
    assert res.is_final == true
    delta = 150 |> Time.milliseconds() |> Time.to_nanoseconds()
    assert_in_delta res.result_end_time, streaming_time_limit |> Time.to_nanoseconds(), delta
    assert [%SpeechRecognitionAlternative{} = alt] = res.alternatives

    assert alt.transcript ==
             "Adventure 1 a scandal in Bohemia from the Adventures of Sherlock Holmes"

    sherlock_word = alt.words |> Enum.find(fn %{word: word} -> word == "Sherlock" end)

    assert %WordInfo{
             start_time: start_time,
             end_time: end_time,
             word: "Sherlock"
           } = sherlock_word

    assert_in_delta start_time, 4_900_000_000, delta
    assert_in_delta end_time, 5_200_000_000, delta

    assert_receive %StreamingRecognizeResponse{} = response, 10_000
    assert response.error == nil
    assert [%StreamingRecognitionResult{} = res] = response.results
    assert res.is_final == true
    assert_in_delta res.result_end_time, @fixture_duration |> Time.to_nanoseconds(), delta
    assert [%SpeechRecognitionAlternative{} = alt] = res.alternatives

    assert alt.transcript =~ "of Sherlock Holmes by Sir Arthur Conan Doyle"
    sherlock_word = alt.words |> Enum.find(fn %{word: word} -> word == "Sherlock" end)

    assert %WordInfo{
             start_time: start_time,
             end_time: end_time,
             word: "Sherlock"
           } = sherlock_word

    assert_in_delta start_time, 4_900_000_000, delta
    assert_in_delta end_time, 5_200_000_000, delta
  end
end
