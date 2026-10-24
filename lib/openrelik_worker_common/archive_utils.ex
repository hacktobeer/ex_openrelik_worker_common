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

defmodule OpenrelikWorkerCommon.ArchiveUtils do
  @moduledoc """
  Helper functions for extracting archives (`openrelik_worker_common.archive_utils`).
  """

  alias OpenrelikWorkerCommon.FileUtils

  @doc """
  Unpacks an archive using `tar` (for `.tgz` and `.tar.gz`) or `7z` (for all other archive formats).

  ## Parameters
  * `input_file` - Input file map containing `"path"` and `"display_name"`.
  * `output_folder` - OpenRelik output folder path.
  * `log_file` - Path to write command stdout/stderr logs.
  * `opts` - Optional keyword list (or positional arguments via `extract_archive/4..7`):
    * `:file_filter` - List of file patterns to extract (default `[]`).
    * `:archive_password` - Password of the input archive (default `nil`).
    * `:ignore_prompts` - Whether to ignore prompts during extraction (default `true`).
    * `:file_exclusion_filter` - List of file patterns to exclude (default `[]`).
    * `:which_fn` - Optional `(String.t() -> String.t() | boolean() | nil)` override for `System.find_executable/1`.
    * `:cmd_runner` - Optional `(command_list, log_file -> integer())` override for command execution.
    * `:mkdir_fn` - Optional `(String.t() -> :ok)` override for directory creation.

  ## Returns
  `{command_string, export_folder}` where `command_string` is the executed command string
  and `export_folder` is the root folder path to the unpacked archive.
  """
  @spec extract_archive(
          map(),
          String.t(),
          String.t(),
          list() | keyword(),
          String.t() | nil,
          boolean(),
          list()
        ) :: {String.t(), String.t()}
  def extract_archive(
        input_file,
        output_folder,
        log_file,
        file_filter_or_opts \\ [],
        archive_password \\ nil,
        ignore_prompts \\ true,
        file_exclusion_filter \\ []
      )
      when is_map(input_file) and is_binary(output_folder) and is_binary(log_file) do
    {file_filter, archive_password, ignore_prompts, file_exclusion_filter, extra_opts} =
      if Keyword.keyword?(file_filter_or_opts) and file_filter_or_opts != [] do
        {
          Keyword.get(file_filter_or_opts, :file_filter, []),
          Keyword.get(file_filter_or_opts, :archive_password, archive_password),
          Keyword.get(file_filter_or_opts, :ignore_prompts, ignore_prompts),
          Keyword.get(file_filter_or_opts, :file_exclusion_filter, file_exclusion_filter),
          file_filter_or_opts
        }
      else
        {
          file_filter_or_opts || [],
          archive_password,
          ignore_prompts,
          file_exclusion_filter || [],
          []
        }
      end

    input_path = get_key(input_file, "path")
    input_filename = get_key(input_file, "display_name")

    if is_nil(input_path) or is_nil(input_filename) do
      raise RuntimeError, "input_file parameter malformed"
    end

    which_fn =
      Keyword.get(extra_opts, :which_fn) ||
        Process.get(:openrelik_which_fn) ||
        (&System.find_executable/1)

    if not truthy_executable?(which_fn.("7z")) do
      raise RuntimeError, "7z executable not found!"
    end

    export_folder = Path.join(output_folder, FileUtils.uuid4_hex())

    mkdir_fn =
      Keyword.get(extra_opts, :mkdir_fn) ||
        Process.get(:openrelik_mkdir_fn) ||
        (&File.mkdir_p!/1)

    mkdir_fn.(export_folder)

    command =
      if String.ends_with?(input_filename, [".tgz", ".tar.gz"]) do
        base = ["tar", "-vxzf", input_path, "-C", "#{export_folder}"]

        with_filter =
          if file_filter != [] do
            base ++
              ["--recursion", "--no-anchored"] ++
              Enum.flat_map(file_filter, fn pattern ->
                ["--wildcards", String.trim(to_string(pattern))]
              end)
          else
            base
          end

        if file_exclusion_filter != [] do
          with_filter ++
            Enum.map(file_exclusion_filter, fn pattern ->
              "--exclude=#{String.trim(to_string(pattern))}"
            end)
        else
          with_filter
        end
      else
        base = ["7z", "x", input_path, "-o#{export_folder}"]
        base = if ignore_prompts, do: base ++ ["-y"], else: base

        base =
          if not is_nil(archive_password) do
            base ++ ["-p#{archive_password}"]
          else
            base
          end

        base =
          if file_exclusion_filter != [] do
            base ++
              Enum.map(file_exclusion_filter, fn pattern ->
                "-xr!#{String.trim(to_string(pattern))}"
              end)
          else
            base
          end

        if file_filter != [] do
          base ++ ["-r"] ++ Enum.map(file_filter, &String.trim(to_string(&1)))
        else
          base
        end
      end

    command_string = Enum.join(command, " ")

    cmd_runner =
      Keyword.get(extra_opts, :cmd_runner) ||
        Process.get(:openrelik_archive_cmd_runner) ||
        (&default_run_command/2)

    ret = cmd_runner.(command, log_file)

    if ret != 0 do
      raise RuntimeError, "7zip or tar execution error."
    end

    {command_string, export_folder}
  end

  defp default_run_command([executable | args], log_file) do
    File.mkdir_p!(Path.dirname(log_file))

    try do
      {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
      File.write!(log_file, output)
      status
    rescue
      _ -> 1
    end
  end

  defp truthy_executable?(nil), do: false
  defp truthy_executable?(false), do: false
  defp truthy_executable?(_), do: true

  defp get_key(map, key) do
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
end
