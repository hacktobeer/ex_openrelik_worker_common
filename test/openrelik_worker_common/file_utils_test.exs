defmodule OpenrelikWorkerCommon.FileUtilsTest do
  use ExUnit.Case, async: true

  alias OpenrelikWorkerCommon.FileUtils
  alias OpenrelikWorkerCommon.FileUtils.OutputFile
  alias OpenrelikWorkerCommon.FileUtils.TemporaryDirectory

  @tag :tmp_dir
  test "count_file_lines counts lines in a file", %{tmp_dir: tmp_dir} do
    mock_file_content = """
    Line1
            Line2
            Line3
    """

    file = Path.join(tmp_dir, "file.txt")
    File.write!(file, mock_file_content)
    lines = FileUtils.count_file_lines(file)
    assert lines == 3
    File.rm!(file)
  end

  test "create_output_file" do
    Process.put(:openrelik_uuid_generator, fn -> "123456789" end)

    try do
      # Test with only an output_path.
      result = FileUtils.create_output_file("output_path/")
      assert result.display_name == "123456789"
      assert result.path == "output_path/123456789"

      # Test with an extra file_name.
      result = FileUtils.create_output_file("output_path/", display_name: "test.txt")
      assert result.display_name == "test.txt"
      assert result.path == "output_path/123456789.txt"

      # Test with an extra explicit file_extension.
      result =
        FileUtils.create_output_file("output_path/",
          display_name: "test.txt",
          extension: "test"
        )

      assert result.display_name == "test.txt.test"
      assert result.path == "output_path/123456789.test"

      # Test with an extra source_file_id OutputFile instance.
      source_file_id = FileUtils.create_output_file("output_path/")

      result =
        FileUtils.create_output_file("output_path/",
          source_file_id: source_file_id
        )

      assert result.source_file_id.uuid == source_file_id.uuid
    after
      Process.delete(:openrelik_uuid_generator)
    end
  end

  test "outputfile_to_dict" do
    Process.put(:openrelik_uuid_generator, fn -> "123456789" end)

    try do
      parent_outputfile = FileUtils.create_output_file("output_path/")

      outputfile =
        FileUtils.create_output_file("output_path/",
          source_file_id: parent_outputfile
        )

      result = OutputFile.to_dict(outputfile)

      expected = %{
        "uuid" => "123456789",
        "display_name" => "123456789",
        "extension" => "",
        "data_type" => nil,
        "path" => "output_path/123456789",
        "original_path" => nil,
        "source_file_id" => parent_outputfile,
        "register_in_db" => true
      }

      assert result == expected
    after
      Process.delete(:openrelik_uuid_generator)
    end
  end

  test "create_output_file register_in_db default is true" do
    result = FileUtils.create_output_file("output_path/")
    assert result.register_in_db == true
    assert OutputFile.to_dict(result)["register_in_db"] == true
  end

  test "create_output_file register_in_db=false is honored and serialized" do
    result = FileUtils.create_output_file("output_path/", register_in_db: false)
    assert result.register_in_db == false
    assert OutputFile.to_dict(result)["register_in_db"] == false
  end

  test "build_file_tree" do
    test_paths = [
      ["/etc/xxx/sshd_config", "/etc/xxx/sshd_config"],
      ["/etc/xxx_version", "/etc/xxx_version"],
      ["/etc/xxx/ssh_config", "/etc/xxx/ssh_config"],
      ["/etc/../xxx/config", "/xxx/config"],
      ["/etc/../../../../ssh/sshd_config", "/ssh/sshd_config"]
    ]

    output_path = TemporaryDirectory.create()

    try do
      files =
        Enum.map(test_paths, fn [orig_path, _expected_path] ->
          file =
            FileUtils.create_output_file(output_path.name,
              original_path: orig_path
            )

          File.write!(file.path, "")
          file
        end)

      file_tree_root = FileUtils.build_file_tree(output_path.name, files)

      Enum.each(test_paths, fn [_orig, expected] ->
        expected_file = Path.join(file_tree_root.name, FileUtils.get_relative_path(expected))
        assert File.regular?(expected_file)
      end)

      FileUtils.delete_file_tree(file_tree_root)

      # Test with a non OutputFile instance as files array element
      invalid_files = [OutputFile, "not-an-OutputFile"]
      assert FileUtils.build_file_tree(output_path, invalid_files) == nil

      # Test with an empty files array
      assert FileUtils.build_file_tree(output_path, []) == nil
    after
      TemporaryDirectory.cleanup(output_path)
    end
  end

  test "delete_file_tree" do
    assert_raise ArgumentError, "Root path is not a TemporaryDirectory object!", fn ->
      FileUtils.delete_file_tree("not-a-temp-directory-object")
    end

    tmpdir = TemporaryDirectory.create()
    filepath = Path.join(tmpdir.name, "testfile")
    File.write!(filepath, "")

    FileUtils.delete_file_tree(tmpdir)
    refute File.regular?(filepath)
  end

  test "get_relative_path" do
    relative_path = FileUtils.get_relative_path("/xxx/yyy/test.txt")
    assert relative_path == "xxx/yyy/test.txt"
  end

  test "valid_disk_image_extensions" do
    assert FileUtils.is_disk_image(%{"display_name" => "myimage.img"})
    assert FileUtils.is_disk_image(%{"display_name" => "vm.qcow3"})
    assert FileUtils.is_disk_image(%{"display_name" => "another.qcow2"})
    assert FileUtils.is_disk_image(%{"display_name" => "test.qcow"})
    assert FileUtils.is_disk_image(%{"display_name" => "backup.disk.qcow2"})
    assert FileUtils.is_disk_image(%{"display_name" => "data.RAW"})
    assert FileUtils.is_disk_image(%{"display_name" => "disk.DD"})
    assert FileUtils.is_disk_image(%{"display_name" => "evidence.E01"})
    assert FileUtils.is_disk_image(%{"display_name" => "evidence.EX01"})
  end

  test "non_disk_image_extensions" do
    refute FileUtils.is_disk_image(%{"display_name" => "document.txt"})
    refute FileUtils.is_disk_image(%{"display_name" => "report.pdf"})
    refute FileUtils.is_disk_image(%{"display_name" => "my_disk_image_no_ext"})
  end

  test "missing_display_name raises RuntimeError" do
    assert_raise RuntimeError, ~r/inputfile parameter malformed, no display_name found/, fn ->
      FileUtils.is_disk_image(%{"other_key" => "some_value"})
    end

    assert_raise RuntimeError, ~r/inputfile parameter malformed, no display_name found/, fn ->
      FileUtils.is_disk_image(%{})
    end
  end
end
