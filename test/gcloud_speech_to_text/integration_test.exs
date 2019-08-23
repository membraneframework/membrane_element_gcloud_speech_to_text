defmodule Membrane.Element.GCloud.SpeechToText.IntegrationTest do
  use ExUnit.Case

  alias Google.Cloud.Speech.V1.{
    StreamingRecognizeResponse,
    StreamingRecognitionResult,
    SpeechRecognitionAlternative,
    WordInfo
  }

  @moduletag :external

  @fixture_path "../fixtures/sample.flac" |> Path.expand(__DIR__)

  test "recognition pipeline provides transcription of short file" do
    assert {:ok, pid} = RecognitionPipeline.start_link([@fixture_path, self()])
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
             end_time: 1_000_000_000,
             word: "Adventure"
           }

    assert last_word == %WordInfo{
             start_time: 6_500_000_000,
             end_time: 7_100_000_000,
             word: "Doyle"
           }
  end
end
