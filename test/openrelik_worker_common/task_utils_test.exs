defmodule OpenrelikWorkerCommon.TaskUtilsTest do
  use ExUnit.Case, async: true

  alias OpenrelikWorkerCommon.FileUtils
  alias OpenrelikWorkerCommon.TaskUtils

  @input_files [
    %{
      "data_type" => "image/jpeg",
      "mime_type" => "image/jpeg",
      "display_name" => "image.jpg",
      "extension" => "jpg"
    },
    %{
      "data_type" => "text/plain",
      "mime_type" => "text/plain",
      "display_name" => "document.txt",
      "extension" => "txt"
    }
  ]

  test "encode_dict_to_base64" do
    result = TaskUtils.encode_dict_to_base64(%{"a" => "b"})
    assert TaskUtils.decode_base64_to_dict(result) == %{"a" => "b"}
  end

  test "get_input_files for input_files" do
    input_file = [FileUtils.create_output_file("test/test")]
    result = TaskUtils.get_input_files(nil, input_file)
    assert result == input_file
  end

  test "get_input_files for single pipe_result" do
    pipe_input = "eyJvdXRwdXRfZmlsZXMiOiAiL3Rlc3QvdGVzdCJ9"
    result = TaskUtils.get_input_files(pipe_input, nil)
    assert result == "/test/test"
  end

  test "get_input_files aggregates output files across multiple pipe results" do
    first = TaskUtils.encode_dict_to_base64(%{"output_files" => [%{"path" => "/a"}]})
    second = TaskUtils.encode_dict_to_base64(%{"output_files" => [%{"path" => "/b"}]})

    result = TaskUtils.get_input_files([first, second], nil)
    assert result == [%{"path" => "/a"}, %{"path" => "/b"}]
  end

  test "create_task_result" do
    output_files = ["a", "b"]
    workflow_id = "1234456789"
    command = "/bin/command"
    meta = %{"key" => "value"}

    expected = %{
      "output_files" => output_files,
      "workflow_id" => workflow_id,
      "task_files" => [],
      "command" => command,
      "meta" => meta,
      "file_reports" => [],
      "task_report" => nil
    }

    result =
      TaskUtils.create_task_result(
        output_files: output_files,
        workflow_id: workflow_id,
        task_files: [],
        command: command,
        meta: meta,
        file_reports: [],
        task_report: nil
      )

    assert result == TaskUtils.encode_dict_to_base64(expected)
    assert TaskUtils.decode_base64_to_dict(result) == expected

    # Positional invocation
    pos_result =
      TaskUtils.create_task_result(output_files, workflow_id, [], command, meta, [], nil)

    assert pos_result == result
  end

  test "filter_compatible_files data_type match" do
    filter_dict = %{"data_types" => ["image/*"]}

    expected_result = [
      %{
        "data_type" => "image/jpeg",
        "mime_type" => "image/jpeg",
        "display_name" => "image.jpg",
        "extension" => "jpg"
      }
    ]

    assert TaskUtils.filter_compatible_files(@input_files, filter_dict) == expected_result
  end

  test "filter_compatible_files mime_type match" do
    filter_dict = %{"mime_types" => ["text/*"]}

    expected_result = [
      %{
        "data_type" => "text/plain",
        "mime_type" => "text/plain",
        "display_name" => "document.txt",
        "extension" => "txt"
      }
    ]

    assert TaskUtils.filter_compatible_files(@input_files, filter_dict) == expected_result
  end

  test "filter_compatible_files filename match" do
    filter_dict = %{"filenames" => ["image.*"]}

    expected_result = [
      %{
        "data_type" => "image/jpeg",
        "mime_type" => "image/jpeg",
        "display_name" => "image.jpg",
        "extension" => "jpg"
      }
    ]

    assert TaskUtils.filter_compatible_files(@input_files, filter_dict) == expected_result
  end

  test "filter_compatible_files no match, empty input, and empty filter" do
    assert TaskUtils.filter_compatible_files(@input_files, %{"data_types" => ["video/*"]}) == []
    assert TaskUtils.filter_compatible_files([], %{"data_types" => ["image/*"]}) == []
    assert TaskUtils.filter_compatible_files(@input_files, %{}) == []
  end
end
