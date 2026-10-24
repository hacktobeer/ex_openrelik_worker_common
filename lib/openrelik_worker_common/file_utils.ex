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

defmodule OpenrelikWorkerCommon.FileUtils.TemporaryDirectory do
  @moduledoc """
  Represents a temporary directory on disk, equivalent to Python's `tempfile.TemporaryDirectory`.
  """

  @type t :: %__MODULE__{
          name: String.t()
        }

  @enforce_keys [:name]
  defstruct [:name]

  @doc """
  Creates a new temporary directory inside `base_dir` (or `System.tmp_dir!()` if `nil`).
  """
  @spec create(String.t() | nil, String.t()) :: t()
  def create(base_dir \\ nil, prefix \\ "tmp") do
    parent = base_dir || System.tmp_dir!()
    random_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    dir_path = Path.join(parent, "#{prefix}#{random_suffix}")
    File.mkdir_p!(dir_path)
    %__MODULE__{name: dir_path}
  end

  @doc """
  Recursively removes the temporary directory and its contents.
  """
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{name: name}) when is_binary(name) do
    File.rm_rf!(name)
    :ok
  end

  defimpl String.Chars do
    def to_string(%{name: name}), do: name
  end
end

defmodule OpenrelikWorkerCommon.FileUtils.OutputFile do
  @moduledoc """
  Represents an output file created by an OpenRelik worker task
  (Elixir port of `openrelik_worker_common.file_utils.OutputFile`).

  ## Fields
  * `:uuid` - Unique identifier (`uuid4` hex) for the file.
  * `:display_name` - Display name for the file.
  * `:extension` - Extension of the file.
  * `:data_type` - Data type of the file.
  * `:path` - The full path to the file on disk.
  * `:original_path` - The full original path to the file.
  * `:source_file_id` - The source file ID or parent `OutputFile` this file belongs to.
  * `:register_in_db` - When `false`, the mediator skips DB registration, hashing,
    and file reports for this file. Defaults to `true`.
  """

  @type t :: %__MODULE__{
          uuid: String.t(),
          display_name: String.t(),
          extension: String.t() | nil,
          data_type: String.t() | nil,
          path: String.t(),
          original_path: String.t() | nil,
          source_file_id: integer() | String.t() | t() | map() | nil,
          register_in_db: boolean()
        }

  @enforce_keys [:uuid, :display_name, :path]
  defstruct uuid: nil,
            display_name: nil,
            extension: nil,
            data_type: nil,
            path: nil,
            original_path: nil,
            source_file_id: nil,
            register_in_db: true

  @doc """
  Initializes an `%OutputFile{}` struct.

  Accepts keyword options or a map, or positional arguments matching Python's
  `OutputFile(uuid, output_path, display_name, ...)`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    map =
      Map.new(attrs, fn
        {k, v} when is_atom(k) -> {k, v}
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
      end)

    path = Map.get(map, :path) || Map.get(map, :output_path)

    %__MODULE__{
      uuid: Map.fetch!(map, :uuid),
      display_name: Map.fetch!(map, :display_name),
      extension: Map.get(map, :extension),
      data_type: Map.get(map, :data_type),
      path: path,
      original_path: Map.get(map, :original_path),
      source_file_id: Map.get(map, :source_file_id),
      register_in_db: Map.get(map, :register_in_db, true)
    }
  end

  @spec new(String.t(), String.t(), String.t(), keyword() | map()) :: t()
  def new(uuid, output_path, display_name, opts \\ [])
      when is_binary(uuid) and is_binary(output_path) and is_binary(display_name) do
    opts
    |> Enum.into(%{})
    |> Map.merge(%{uuid: uuid, output_path: output_path, display_name: display_name})
    |> new()
  end

  @doc """
  Returns a dictionary (string-keyed map) representation of the `OutputFile` struct.
  This is what the mediator server receives and uses to create a File in the database.
  """
  @spec to_dict(t()) :: %{String.t() => term()}
  def to_dict(%__MODULE__{} = file) do
    %{
      "uuid" => file.uuid,
      "display_name" => file.display_name,
      "extension" => file.extension,
      "data_type" => file.data_type,
      "path" => file.path,
      "original_path" => file.original_path,
      "source_file_id" => file.source_file_id,
      "register_in_db" => file.register_in_db
    }
  end
end

defmodule OpenrelikWorkerCommon.FileUtils do
  @moduledoc """
  File helper functions for OpenRelik workers
  (Elixir port of `openrelik_worker_common.file_utils`).
  """

  alias OpenrelikWorkerCommon.FileUtils.OutputFile
  alias OpenrelikWorkerCommon.FileUtils.TemporaryDirectory

  @disk_image_extensions [
    ".img",
    ".raw",
    ".dd",
    ".qcow3",
    ".qcow2",
    ".qcow",
    ".e01",
    ".ex01"
  ]

  @doc """
  Creates and returns an `%OutputFile{}` struct.

  ## Parameters
  * `output_base_path` - The path to the output directory.
  * `opts` - Keyword list or map of optional parameters:
    * `:display_name` - The name of the output file (optional, defaults to generated UUID).
    * `:extension` - File extension (optional).
    * `:data_type` - The data type of the output file (optional).
    * `:original_path` - The original path of the file (optional).
    * `:source_file_id` - The `OutputFile` or ID this file belongs to (optional).
    * `:register_in_db` - Whether the mediator should create a DB row for this file (default `true`).
    * `:uuid` - Optional override for the generated UUIDv4 hex string.
    * `:uuid_generator` - Optional `0`-arity function returning a UUID hex string (for testing).
  """
  @spec create_output_file(String.t(), keyword() | map()) :: OutputFile.t()
  def create_output_file(output_base_path, opts \\ []) when is_binary(output_base_path) do
    opts_map =
      Map.new(opts, fn
        {k, v} when is_atom(k) -> {k, v}
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
      end)

    uuid =
      cond do
        is_binary(Map.get(opts_map, :uuid)) and Map.get(opts_map, :uuid) != "" ->
          Map.get(opts_map, :uuid)

        is_function(Map.get(opts_map, :uuid_generator), 0) ->
          Map.get(opts_map, :uuid_generator).()

        is_function(Process.get(:openrelik_uuid_generator), 0) ->
          Process.get(:openrelik_uuid_generator).()

        true ->
          uuid4_hex()
      end

    raw_display_name = Map.get(opts_map, :display_name)

    display_name =
      if is_binary(raw_display_name) and raw_display_name != "" do
        raw_display_name
      else
        uuid
      end

    raw_extension = Map.get(opts_map, :extension)

    display_name =
      if is_binary(raw_extension) and raw_extension != "" do
        clean_ext = String.trim_leading(raw_extension, ".")
        "#{display_name}.#{clean_ext}"
      else
        display_name
      end

    {_root, extracted_extension} = splitext(display_name)

    output_filename = "#{uuid}#{extracted_extension}"

    output_path =
      if output_base_path == "" do
        output_filename
      else
        Path.join(output_base_path, output_filename)
      end

    OutputFile.new(
      uuid: uuid,
      output_path: output_path,
      display_name: display_name,
      extension: extracted_extension,
      data_type: Map.get(opts_map, :data_type),
      original_path: Map.get(opts_map, :original_path),
      source_file_id: Map.get(opts_map, :source_file_id),
      register_in_db: Map.get(opts_map, :register_in_db, true)
    )
  end

  @doc """
  Counts the number of lines in a file using `wc -l`.
  """
  @spec count_file_lines(Path.t()) :: non_neg_integer()
  def count_file_lines(file_path) do
    path_str = to_string(file_path)

    case System.cmd("wc", ["-l", path_str], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split()
        |> List.first("0")
        |> String.to_integer()

      {output, status} ->
        raise RuntimeError, "wc -l failed with exit status #{status}: #{String.trim(output)}"
    end
  end

  @doc """
  Converts a full path to a relative path without the root anchor.
  """
  @spec get_relative_path(Path.t()) :: String.t()
  def get_relative_path(path) do
    path_str = to_string(path)

    case Path.split(path_str) do
      ["/" | rest] -> Path.join(rest)
      parts -> Path.join(parts)
    end
  end

  @doc """
  Creates the original file tree structure from a list of `%OutputFile{}` structs.

  Returns a `%TemporaryDirectory{}` representing the root path of the file tree, or `nil`
  if `files` is empty or contains non-`%OutputFile{}` elements.
  """
  @spec build_file_tree(Path.t(), list()) :: TemporaryDirectory.t() | nil
  def build_file_tree(output_path, files) do
    output_dir =
      case output_path do
        %TemporaryDirectory{name: name} -> name
        other -> to_string(other)
      end

    if not is_list(files) or files == [] or not Enum.all?(files, &match?(%OutputFile{}, &1)) do
      nil
    else
      tree_root = TemporaryDirectory.create(output_dir, "tmp")

      Enum.each(files, fn %OutputFile{} = file ->
        normalized_path = normalize_posix_path(file.original_path || "")
        original_filename = Path.basename(normalized_path)
        original_folder = Path.dirname(normalized_path)
        relative_original_folder = get_relative_path(original_folder)

        tmp_full_path =
          if relative_original_folder in ["", "."] do
            tree_root.name
          else
            Path.join(tree_root.name, relative_original_folder)
          end

        if not String.contains?(tmp_full_path, tree_root.name) do
          raise RuntimeError,
                "Folder #{tmp_full_path} not in OpenRelik output_path: #{output_dir}"
        end

        File.mkdir_p!(tmp_full_path)

        target_link_path = Path.join(tmp_full_path, original_filename)

        case File.ln(file.path, target_link_path) do
          :ok ->
            :ok

          {:error, :eexist} ->
            :ok

          {:error, reason} ->
            raise RuntimeError,
                  "Failed to create hard link from #{file.path} to #{target_link_path}: #{inspect(reason)}"
        end
      end)

      tree_root
    end
  end

  @doc """
  Deletes a temporary file tree folder structure created by `build_file_tree/2`.

  Raises `ArgumentError` if `root_path` is not a `%TemporaryDirectory{}` struct.
  """
  @spec delete_file_tree(TemporaryDirectory.t()) :: :ok
  def delete_file_tree(%TemporaryDirectory{} = root_path) do
    TemporaryDirectory.cleanup(root_path)
    :ok
  end

  def delete_file_tree(_invalid) do
    raise ArgumentError, "Root path is not a TemporaryDirectory object!"
  end

  @doc """
  Checks if `inputfile` is a disk image based on its `"display_name"` extension.

  Raises `RuntimeError` if `"display_name"` is not present in `inputfile`.
  """
  @spec is_disk_image(map()) :: boolean()
  def is_disk_image(inputfile) when is_map(inputfile) do
    display_name =
      cond do
        Map.has_key?(inputfile, "display_name") -> Map.get(inputfile, "display_name")
        Map.has_key?(inputfile, :display_name) -> Map.get(inputfile, :display_name)
        true -> :missing
      end

    if display_name == :missing do
      raise RuntimeError, "inputfile parameter malformed, no display_name found"
    end

    input_filename = to_string(display_name)
    {_root, file_extension} = splitext(input_filename)

    String.downcase(file_extension) in @disk_image_extensions
  end

  @doc """
  Generates a 32-character lowercase hexadecimal UUIDv4 string (`uuid4().hex`).
  """
  @spec uuid4_hex() :: String.t()
  def uuid4_hex do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>> |> Base.encode16(case: :lower)
  end

  @doc false
  @spec normalize_posix_path(String.t()) :: String.t()
  def normalize_posix_path(""), do: "."

  def normalize_posix_path(path) when is_binary(path) do
    absolute? = String.starts_with?(path, "/")
    parts = String.split(path, "/", trim: true)

    resolved =
      Enum.reduce(parts, [], fn
        ".", acc ->
          acc

        "..", [] ->
          if absolute?, do: [], else: [".."]

        "..", [".." | _] = acc ->
          [".." | acc]

        "..", [_ | rest] ->
          rest

        segment, acc ->
          [segment | acc]
      end)
      |> Enum.reverse()

    joined = Enum.join(resolved, "/")

    cond do
      absolute? -> "/" <> joined
      joined == "" -> "."
      true -> joined
    end
  end

  # Mirrors Python's `os.path.splitext(path)` behavior
  @doc false
  @spec splitext(String.t()) :: {String.t(), String.t()}
  def splitext(path) when is_binary(path) do
    base = Path.basename(path)
    trimmed_leading_dots = String.trim_leading(base, ".")

    if trimmed_leading_dots == "" or not String.contains?(trimmed_leading_dots, ".") do
      {path, ""}
    else
      case :binary.matches(base, ".") do
        [] ->
          {path, ""}

        matches ->
          {last_dot_idx, 1} = List.last(matches)
          dir_prefix_len = byte_size(path) - byte_size(base)
          split_idx = dir_prefix_len + last_dot_idx
          <<root::binary-size(^split_idx), ext::binary>> = path
          {root, ext}
      end
    end
  end
end
