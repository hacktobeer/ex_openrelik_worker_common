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

defmodule OpenrelikWorkerCommon do
  @moduledoc """
  Elixir port of Python's `openrelik_worker_common` library.

  Provides shared helper modules for OpenRelik forensic workers:
  * `OpenrelikWorkerCommon.DataTypes` (`data_types.py`) - Standard OpenRelik data types (`diskimage:qcow`, `diskimage:raw`, `binary`).
  * `OpenrelikWorkerCommon.TaskUtils` (`task_utils.py`) - Task input resolution (`get_input_files/3`), Base64/JSON result encoding (`create_task_result/1..7`), and glob-based file filtering (`filter_compatible_files/2`).
  * `OpenrelikWorkerCommon.FileUtils` (`file_utils.py`) - `OutputFile` struct, `create_output_file/2`, `count_file_lines/1`, `build_file_tree/2`, `delete_file_tree/1`, `get_relative_path/1`, and `is_disk_image/1`.
  * `OpenrelikWorkerCommon.Reporting` (`reporting.py`) - `Report`, `MarkdownDocument`, `MarkdownDocumentSection`, `MarkdownTable`, `MarkdownFormatter`, `Priority`, and `serialize_file_report/3`.
  * `OpenrelikWorkerCommon.ArchiveUtils` (`archive_utils.py`) - Archive extraction via `tar` and `7z` (`extract_archive/3..7`).
  * `OpenrelikWorkerCommon.PasswordUtils` (`password_utils.py`) - Password hash cracking via `hashcat` and `john` (`bruteforce_password_hashes/4..7`).
  * `OpenrelikWorkerCommon.MountUtils` (`mount_utils.py`) - `BlockDevice` mapping and mounting for raw, QCOW2/3, and EWF (`.E01`/`.EX01`) forensic disk images with Redis NBD device locking.
  """

  alias OpenrelikWorkerCommon.ArchiveUtils
  alias OpenrelikWorkerCommon.FileUtils
  alias OpenrelikWorkerCommon.PasswordUtils
  alias OpenrelikWorkerCommon.Reporting
  alias OpenrelikWorkerCommon.TaskUtils

  defdelegate create_output_file(output_base_path, opts \\ []), to: FileUtils
  defdelegate count_file_lines(file_path), to: FileUtils
  defdelegate get_relative_path(path), to: FileUtils
  defdelegate build_file_tree(output_path, files), to: FileUtils
  defdelegate delete_file_tree(root_path), to: FileUtils
  defdelegate is_disk_image(inputfile), to: FileUtils

  defdelegate encode_dict_to_base64(dict_to_encode), to: TaskUtils
  defdelegate get_input_files(pipe_result, input_files \\ [], filter \\ nil), to: TaskUtils
  defdelegate create_task_result(opts), to: TaskUtils
  defdelegate filter_compatible_files(input_files, filter_dict), to: TaskUtils

  defdelegate extract_archive(
                input_file,
                output_folder,
                log_file,
                file_filter_or_opts \\ [],
                archive_password \\ nil,
                ignore_prompts \\ true,
                file_exclusion_filter \\ []
              ),
              to: ArchiveUtils

  defdelegate bruteforce_password_hashes(
                password_hashes,
                tmp_dir,
                password_list_file_path,
                password_rules_file_path,
                timeout_or_opts \\ 300,
                extra_args \\ "",
                opts \\ []
              ),
              to: PasswordUtils

  defdelegate serialize_file_report(input_file, report_file, report), to: Reporting
end
