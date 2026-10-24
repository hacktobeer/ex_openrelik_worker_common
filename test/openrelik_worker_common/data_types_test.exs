defmodule OpenrelikWorkerCommon.DataTypesTest do
  use ExUnit.Case, async: true

  alias OpenrelikWorkerCommon.DataTypes.DataType
  alias OpenrelikWorkerCommon.TaskUtils

  test "datatype string comparison" do
    assert DataType.diskimage_qcow() == "diskimage:qcow"
    assert DataType.diskimage_raw() == "diskimage:raw"
    assert DataType.binary() == "binary"
  end

  test "datatype enum validation and conversion" do
    assert DataType.valid?(DataType.diskimage_qcow())
    assert DataType.valid?(:DISKIMAGE_QCOW)
    assert DataType.to_string(:DISKIMAGE_QCOW) == "diskimage:qcow"
    assert DataType.to_string(:DISKIMAGE_RAW) == "diskimage:raw"
    assert DataType.to_string(:BINARY) == "binary"
    assert DataType.values() == ["diskimage:qcow", "diskimage:raw", "binary"]
  end

  test "datatype glob filtering" do
    input_files = [
      %{
        "name" => "testfile.qcow",
        "data_type" => "container_explorer:#{DataType.diskimage_qcow()}"
      },
      %{
        "name" => "testfile.bin",
        "data_type" => "hayabusa:#{DataType.binary()}"
      }
    ]

    compatible = TaskUtils.filter_compatible_files(input_files, %{"data_types" => ["*"]})
    assert length(compatible) == 2

    compatible =
      TaskUtils.filter_compatible_files(input_files, %{"data_types" => ["container_explorer:*"]})

    assert length(compatible) == 1

    compatible =
      TaskUtils.filter_compatible_files(input_files, %{"data_types" => ["*:diskimage:*"]})

    assert length(compatible) == 1

    compatible =
      TaskUtils.filter_compatible_files(input_files, %{"data_types" => ["*:binary"]})

    assert length(compatible) == 1

    compatible =
      TaskUtils.filter_compatible_files(input_files, %{
        "data_types" => ["*:#{DataType.diskimage_qcow()}"]
      })

    assert length(compatible) == 1
  end
end
