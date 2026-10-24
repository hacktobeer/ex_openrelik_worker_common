# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule OpenrelikWorkerCommon.TaskUtils do
  @moduledoc """
  Helper functions for tasks (`openrelik_worker_common.task_utils`).

  Provides Base64/JSON serialization of task results, input file resolution from upstream
  piped results (`get_input_files/3`), and glob-based file compatibility filtering
  (`filter_compatible_files/2`).
  """

  alias OpenrelikWorkerCommon.FileUtils.OutputFile

  @doc """
  Encodes a map (dictionary) to a Base64-encoded JSON string.
  """
  @spec encode_dict_to_base64(map()) :: String.t()
  def encode_dict_to_base64(dict_to_encode) when is_map(dict_to_encode) do
    dict_to_encode
    |> normalize_for_json()
    |> JSON.encode!()
    |> Base.encode64()
  end

  @doc """
  Decodes a Base64-encoded JSON string into an Elixir map.
  """
  @spec decode_base64_to_dict(String.t()) :: map()
  def decode_base64_to_dict(encoded_result) when is_binary(encoded_result) do
    encoded_result
    |> Base.decode64!()
    |> JSON.decode!()
  end

  @doc """
  Prepares the input files for a task.

  Determines the appropriate input files by checking for results from a previous task
  (`pipe_result` as a single Base64-encoded string or a list of Base64-encoded strings)
  and then applies any specified file filtering (`filter`).
  """
  @spec get_input_files(String.t() | [String.t()] | nil, list() | nil, map() | nil) ::
          list() | term()
  def get_input_files(pipe_result, input_files \\ [], filter \\ nil) do
    pipe_results =
      cond do
        is_list(pipe_result) -> pipe_result
        is_binary(pipe_result) -> [pipe_result]
        true -> []
      end

    resolved_files =
      cond do
        length(pipe_results) == 1 ->
          pipe_results
          |> hd()
          |> decode_base64_to_dict()
          |> Map.get("output_files", [])

        pipe_results != [] ->
          Enum.flat_map(pipe_results, fn encoded_result ->
            encoded_result
            |> decode_base64_to_dict()
            |> Map.get("output_files", [])
          end)

        true ->
          input_files
      end

    if is_map(filter) and map_size(filter) > 0 do
      filter_compatible_files(resolved_files || [], filter)
    else
      if is_map(filter) do
        filter_compatible_files(resolved_files || [], filter)
      else
        resolved_files
      end
    end
  end

  @doc """
  Creates a task result dictionary and encodes it to a Base64 string.

  Can be called with a keyword list or map:

      create_task_result(
        output_files: output_files,
        workflow_id: workflow_id,
        task_files: [],
        command: command,
        meta: meta,
        file_reports: [],
        task_report: nil
      )

  or with positional arguments matching Python's signature:

      create_task_result(
        output_files,
        workflow_id,
        task_files \\\\ [],
        command \\\\ nil,
        meta \\\\ nil,
        file_reports \\\\ [],
        task_report \\\\ nil
      )
  """
  @spec create_task_result(keyword() | map()) :: String.t()
  def create_task_result(opts) when is_list(opts) or is_map(opts) do
    opts_map =
      Map.new(opts, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {to_string(k), v}
      end)

    result = %{
      "output_files" => Map.get(opts_map, "output_files", []),
      "workflow_id" => Map.get(opts_map, "workflow_id"),
      "task_files" => Map.get(opts_map, "task_files", []),
      "command" => Map.get(opts_map, "command", nil),
      "meta" => Map.get(opts_map, "meta", nil),
      "file_reports" => Map.get(opts_map, "file_reports", []),
      "task_report" => Map.get(opts_map, "task_report", nil)
    }

    encode_dict_to_base64(result)
  end

  @spec create_task_result(list(), String.t() | integer() | nil) :: String.t()
  def create_task_result(output_files, workflow_id) when is_list(output_files) do
    create_task_result(output_files: output_files, workflow_id: workflow_id)
  end

  @spec create_task_result(list(), String.t() | integer() | nil, keyword() | map() | list()) ::
          String.t()
  def create_task_result(output_files, workflow_id, opts_or_task_files)
      when is_list(output_files) do
    if Keyword.keyword?(opts_or_task_files) and opts_or_task_files != [] do
      opts_or_task_files
      |> Enum.into(%{})
      |> Map.put(:output_files, output_files)
      |> Map.put(:workflow_id, workflow_id)
      |> create_task_result()
    else
      case opts_or_task_files do
        map when is_map(map) ->
          map
          |> Map.put("output_files", output_files)
          |> Map.put("workflow_id", workflow_id)
          |> create_task_result()

        task_files when is_list(task_files) ->
          create_task_result(
            output_files: output_files,
            workflow_id: workflow_id,
            task_files: task_files
          )
      end
    end
  end

  @spec create_task_result(
          list(),
          String.t() | integer() | nil,
          list(),
          String.t() | nil,
          map() | nil,
          list(),
          map() | nil
        ) :: String.t()
  def create_task_result(
        output_files,
        workflow_id,
        task_files,
        command,
        meta \\ nil,
        file_reports \\ [],
        task_report \\ nil
      )
      when is_list(output_files) and is_list(task_files) do
    create_task_result(
      output_files: output_files,
      workflow_id: workflow_id,
      task_files: task_files,
      command: command,
      meta: meta,
      file_reports: file_reports,
      task_report: task_report
    )
  end

  @doc """
  Filters a list of file dictionaries based on compatibility with `filter_dict`,
  supporting glob (`fnmatch`) matching on `"data_types"`, `"mime_types"`, and `"filenames"`.
  """
  @spec filter_compatible_files([map()], map()) :: [map()]
  def filter_compatible_files(input_files, filter_dict)
      when is_list(input_files) and is_map(filter_dict) do
    data_type_patterns = get_field(filter_dict, "data_types") || []
    mime_type_patterns = get_field(filter_dict, "mime_types") || []
    filename_patterns = get_field(filter_dict, "filenames") || []

    Enum.filter(input_files, fn file_data ->
      data_type = get_field(file_data, "data_type")
      mime_type = get_field(file_data, "mime_type")
      display_name = get_field(file_data, "display_name")

      cond do
        not is_nil(data_type) and matches_any_pattern?(data_type, data_type_patterns) ->
          true

        not is_nil(mime_type) and matches_any_pattern?(mime_type, mime_type_patterns) ->
          true

        not is_nil(display_name) and matches_any_pattern?(display_name, filename_patterns) ->
          true

        true ->
          false
      end
    end)
  end

  @doc """
  Matches a string against a Unix shell-style wildcard pattern (`fnmatch.fnmatch`).
  """
  @spec fnmatch?(String.t(), String.t()) :: boolean()
  def fnmatch?(value, pattern) when is_binary(value) and is_binary(pattern) do
    regex_source =
      pattern
      |> String.graphemes()
      |> Enum.map_join("", fn
        "*" -> ".*"
        "?" -> "."
        c -> Regex.escape(c)
      end)

    case Regex.compile("^" <> regex_source <> "$", "s") do
      {:ok, regex} -> Regex.match?(regex, value)
      _ -> value == pattern
    end
  end

  @doc """
  Fetches a field from a map by string key or atom key.
  """
  @spec get_field(map(), String.t()) :: term()
  def get_field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, val} ->
        val

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end

  defp matches_any_pattern?(value, patterns) when is_binary(value) and is_list(patterns) do
    Enum.any?(patterns, &fnmatch?(to_string(value), to_string(&1)))
  end

  defp matches_any_pattern?(_value, _patterns), do: false

  defp normalize_for_json(%OutputFile{} = file) do
    file |> OutputFile.to_dict() |> normalize_for_json()
  end

  defp normalize_for_json(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), normalize_for_json(v)} end)
  end

  defp normalize_for_json(list) when is_list(list) do
    Enum.map(list, &normalize_for_json/1)
  end

  defp normalize_for_json(other), do: other
end
