defmodule OpenrelikWorkerCommon.ArchiveUtilsTest do
  use ExUnit.Case, async: true

  alias OpenrelikWorkerCommon.ArchiveUtils

  @file_filter ["*.txt", "*.evtx"]

  setup %{tmp_dir: tmp_dir} do
    log_file = Path.join(tmp_dir, "log.txt")
    {:ok, output_folder: tmp_dir, log_file: log_file}
  end

  @tag :tmp_dir
  test "extract_archive tgz", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    assert cmd =~ "*.txt"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive tgz no filter", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    refute cmd =~ "--wildcards"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive zip", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "7z x"
    assert cmd =~ "*.txt"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive tar ignores password", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.tar.gz", "display_name" => "archive.tar.gz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        archive_password: "Openrelik123!",
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    refute cmd =~ "-pOpenrelik123!"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive zip includes password", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        archive_password: "Openrelik123!",
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "7z x"
    assert cmd =~ "*.txt"
    assert cmd =~ "-pOpenrelik123!"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive zip no filter", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "7z x"
    refute cmd =~ "-r"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive error", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    assert_raise RuntimeError, "7zip or tar execution error.", fn ->
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 1 end
      )
    end
  end

  @tag :tmp_dir
  test "extract_archive 7z not found", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    assert_raise RuntimeError, "7z executable not found!", fn ->
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        which_fn: fn _ -> nil end
      )
    end
  end

  @tag :tmp_dir
  test "extract_archive mkdir error", %{output_folder: output_folder, log_file: log_file} do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    assert_raise File.Error, fn ->
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        which_fn: fn _ -> true end,
        mkdir_fn: fn path ->
          raise File.Error, reason: :eacces, action: "make directory", path: path
        end
      )
    end
  end

  @tag :tmp_dir
  test "extract_archive zip ignore_prompts true vs false", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd_true, export_true} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        ignore_prompts: true,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd_true =~ "7z x"
    assert cmd_true =~ " -y"
    assert export_true =~ output_folder

    {cmd_false, export_false} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        ignore_prompts: false,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd_false =~ "7z x"
    refute cmd_false =~ " -y"
    assert export_false =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive tgz ignore_prompts ignored", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: @file_filter,
        ignore_prompts: true,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    refute cmd =~ " -y"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "malformed input_file raises RuntimeError", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    assert_raise RuntimeError, "input_file parameter malformed", fn ->
      ArchiveUtils.extract_archive(%{}, output_folder, log_file, @file_filter)
    end
  end

  @tag :tmp_dir
  test "extract_archive tgz exclusion filter", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_exclusion_filter: ["*.log", "tmp/*"],
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    assert cmd =~ "--exclude=*.log"
    assert cmd =~ "--exclude=tmp/*"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive tgz no exclusion filter", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    refute cmd =~ "--exclude="
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive zip exclusion filter", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_exclusion_filter: ["*.log", "secret/*"],
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "7z x"
    assert cmd =~ "-xr!*.log"
    assert cmd =~ "-xr!secret/*"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive zip no exclusion filter", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "7z x"
    refute cmd =~ "-xr!"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive tgz filter and exclusion filter", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.tgz", "display_name" => "archive.tgz"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: ["*.evtx"],
        file_exclusion_filter: ["*.log"],
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "tar -vxzf"
    assert cmd =~ "*.evtx"
    assert cmd =~ "--exclude=*.log"
    assert export_folder =~ output_folder
  end

  @tag :tmp_dir
  test "extract_archive zip filter and exclusion filter", %{
    output_folder: output_folder,
    log_file: log_file
  } do
    input_file = %{"path" => "/path/to/archive.zip", "display_name" => "archive.zip"}

    {cmd, export_folder} =
      ArchiveUtils.extract_archive(input_file, output_folder, log_file,
        file_filter: ["*.evtx"],
        file_exclusion_filter: ["*.log"],
        which_fn: fn _ -> true end,
        cmd_runner: fn _cmd, _log -> 0 end
      )

    assert cmd =~ "7z x"
    assert cmd =~ "*.evtx"
    assert cmd =~ "-xr!*.log"
    assert export_folder =~ output_folder
  end
end
