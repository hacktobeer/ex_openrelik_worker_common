defmodule OpenrelikWorkerCommon.MountUtilsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias OpenrelikWorkerCommon.MountUtils.BlockDevice

  @ewf_image_path "/mock/evidence.E01"

  defp new_fake_redis do
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    %{
      agent: agent,
      acquire: fn name, token, _timeout ->
        Agent.get_and_update(agent, fn state ->
          if Map.has_key?(state, name) do
            {false, state}
          else
            {true, Map.put(state, name, token)}
          end
        end)
      end,
      release: fn name, token ->
        Agent.update(agent, fn state ->
          if Map.get(state, name) == token do
            Map.delete(state, name)
          else
            state
          end
        end)
      end,
      get: fn name ->
        Agent.get(agent, &Map.get(&1, name))
      end
    }
  end

  test "BlkInfoError on invalid JSON and non-zero exit code" do
    bd_invalid_json =
      BlockDevice.new("./test_data/image_vfat.img",
        required_tools_available_fn: fn -> true end,
        losetup_fn: fn -> "/dev/loop0" end,
        cmd_runner: fn _cmd ->
          %{returncode: 0, stdout: "this is not valid JSON", stderr: ""}
        end
      )

    assert_raise RuntimeError, ~r/Error parsing lsblk json output/, fn ->
      BlockDevice.setup(bd_invalid_json)
    end

    bd_lsblk_err =
      BlockDevice.new("./test_data/image_vfat.img",
        required_tools_available_fn: fn -> true end,
        losetup_fn: fn -> "/dev/loop0" end,
        cmd_runner: fn
          ["sudo", "lsblk" | _] ->
            %{returncode: 1, stdout: nil, stderr: "device not found /dev/loop0"}

          ["sudo", "losetup", "--detach" | _] ->
            %{returncode: 0, stdout: "", stderr: ""}
        end
      )

    assert_raise RuntimeError, "Error lsblk: device not found /dev/loop0 None", fn ->
      BlockDevice.setup(bd_lsblk_err)
    end
  end

  test "GetFreeNbDevice acquires and releases sequential NBD locks" do
    fake_redis = new_fake_redis()

    opts = [
      required_tools_available_fn: fn -> true end,
      required_modules_loaded_fn: fn -> :ok end,
      redis_from_url_fn: fn _url -> fake_redis end,
      get_hostname_fn: fn -> "random_host_name" end,
      is_important_partition_fn: fn _ -> true end,
      sleep_fn: fn _ -> :ok end,
      cmd_runner: fn
        ["sudo", "qemu-nbd" | _] ->
          %{returncode: 0, stdout: "", stderr: ""}

        ["sudo", "fdisk" | _] ->
          %{returncode: 0, stdout: "", stderr: ""}

        ["sudo", "lsblk" | _] ->
          %{returncode: 0, stdout: ~s({"blockdevices": [{"name": "nbd0"}]}), stderr: ""}
      end
    ]

    bd =
      "./test_data/image_with_partitions.qcow2"
      |> BlockDevice.new(opts)
      |> BlockDevice.setup()

    assert bd.blkdevice == "/dev/nbd0"
    assert bd.redis_lock != nil
    assert bd.redis_lock.name == "random_host_name-/dev/nbd0"
    assert fake_redis.get.("random_host_name-/dev/nbd0") == bd.redis_lock.token

    bd2 =
      "./test_data/image_with_partitions.qcow2"
      |> BlockDevice.new(opts)
      |> BlockDevice.setup()

    assert bd2.blkdevice == "/dev/nbd1"
    assert bd2.redis_lock != nil
    assert bd2.redis_lock.name == "random_host_name-/dev/nbd1"
    assert fake_redis.get.("random_host_name-/dev/nbd1") == bd2.redis_lock.token

    OpenrelikWorkerCommon.MountUtils.RedisLock.release(bd.redis_lock)
    assert fake_redis.get.("random_host_name-/dev/nbd0") == nil

    OpenrelikWorkerCommon.MountUtils.RedisLock.release(bd2.redis_lock)
    assert fake_redis.get.("random_host_name-/dev/nbd1") == nil
  end

  test "GetFreeNbDeviceNoDevicesAvailable raises when all NBD devices are locked" do
    fake_redis = new_fake_redis()

    for device_number <- 0..BlockDevice.max_nbd_devices() do
      devname = "/dev/nbd#{device_number}"

      fake_redis.acquire.(
        "random_host_name-#{devname}",
        "locked",
        BlockDevice.lock_timeout_seconds()
      )
    end

    bd =
      BlockDevice.new("./test_data/image_with_partitions.qcow2",
        required_tools_available_fn: fn -> true end,
        required_modules_loaded_fn: fn -> :ok end,
        redis_from_url_fn: fn _url -> fake_redis end,
        get_hostname_fn: fn -> "random_host_name" end
      )

    assert_raise RuntimeError, "Error getting free NBD device: All NBD devices locked!", fn ->
      BlockDevice.setup(bd)
    end
  end

  test "GetHostNameSocket and GetHostNameENV" do
    bd_socket =
      BlockDevice.new("./test_data/image_vfat.img",
        env_get_fn: fn _ -> nil end,
        gethostname_fn: fn -> "myhostname" end
      )

    assert BlockDevice.get_hostname(bd_socket) == "myhostname"

    bd_env =
      BlockDevice.new("./test_data/image_vfat.img",
        env_get_fn: fn "NODENAME" -> "mynodename" end
      )

    assert BlockDevice.get_hostname(bd_env) == "mynodename"
  end

  test "LoSetupFail raises when image_path does not exist" do
    assert_raise RuntimeError, "image_path does not exist: imagedoesnotexist", fn ->
      "imagedoesnotexist"
      |> BlockDevice.new()
      |> BlockDevice.setup()
    end
  end

  test "MountWithQCOW2Error raises when qemu-nbd fails" do
    bd =
      BlockDevice.new("./test_data/nonexistent_qcow2_image.qcow2",
        path_exists_fn: fn _ -> true end,
        required_tools_available_fn: fn -> true end,
        required_modules_loaded_fn: fn -> :ok end,
        redis_from_url_fn: fn _ -> new_fake_redis() end,
        get_free_nbd_device_fn: fn -> "/dev/nbd0" end,
        cmd_runner: fn _ ->
          %{returncode: 1, stdout: "not a qcow file", stderr: nil}
        end
      )

    assert_raise RuntimeError, "Error running qemu-nbd: None not a qcow file", fn ->
      BlockDevice.setup(bd)
    end
  end

  test "EwfSetupUsesLoopDeviceWithoutNbdModuleCheck" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        path_exists_fn: fn _ -> true end,
        required_tools_available_fn: fn -> true end,
        required_modules_loaded_fn: fn ->
          send(test_pid, :modules_called)
          :ok
        end,
        ewfmount_fn: fn ->
          send(test_pid, :ewfmount_called)
          "/mnt/openrelik-ewf-test/ewf1"
        end,
        losetup_fn: fn ->
          send(test_pid, :losetup_called)
          "/dev/loop0"
        end,
        blkinfo_fn: fn -> %{"blockdevices" => []} end,
        parse_partitions_fn: fn -> [] end
      )
      |> BlockDevice.setup()

    assert_received :ewfmount_called
    refute_received :modules_called
    assert_received :losetup_called
    assert bd.original_image_path == @ewf_image_path
    assert bd.image_path == "/mnt/openrelik-ewf-test/ewf1"
    assert bd.blkdevice == "/dev/loop0"
  end

  test "EwfSetupCleansUpEwfMountOnFailure" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        path_exists_fn: fn _ -> true end,
        required_tools_available_fn: fn -> true end,
        ewfmount_fn: fn bd_state ->
          {%{bd_state | ewf_mount_path: "/mnt/openrelik-ewf-test"},
           "/mnt/openrelik-ewf-test/ewf1"}
        end,
        losetup_fn: fn -> raise RuntimeError, "losetup failed" end,
        ewfumount_fn: fn ->
          send(test_pid, :ewfumount_called)
        end
      )

    assert_raise RuntimeError, "losetup failed", fn ->
      BlockDevice.setup(bd)
    end

    assert_received :ewfumount_called
  end

  test "EwfSetupCleansUpBlockDeviceAndEwfMountOnFailure" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        path_exists_fn: fn _ -> true end,
        required_tools_available_fn: fn -> true end,
        ewfmount_fn: fn bd_state ->
          {%{bd_state | ewf_mount_path: "/mnt/openrelik-ewf-test"},
           "/mnt/openrelik-ewf-test/ewf1"}
        end,
        losetup_fn: fn -> "/dev/loop0" end,
        blkinfo_fn: fn -> raise RuntimeError, "lsblk failed" end,
        parse_partitions_fn: fn ->
          send(test_pid, :parse_partitions_called)
          []
        end,
        detach_device_fn: fn ->
          send(test_pid, :detach_device_called)
        end,
        ewfumount_fn: fn ->
          send(test_pid, :ewfumount_called)
        end
      )

    assert_raise RuntimeError, "lsblk failed", fn ->
      BlockDevice.setup(bd)
    end

    assert_received :detach_device_called
    assert_received :ewfumount_called
    refute_received :parse_partitions_called
  end

  test "EwfSetupReportsOriginalErrorWhenCleanupFails" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        path_exists_fn: fn _ -> true end,
        required_tools_available_fn: fn -> true end,
        ewfmount_fn: fn bd_state ->
          {%{bd_state | ewf_mount_path: "/mnt/openrelik-ewf-test"},
           "/mnt/openrelik-ewf-test/ewf1"}
        end,
        losetup_fn: fn -> raise RuntimeError, "losetup failed" end,
        ewfumount_fn: fn ->
          send(test_pid, :ewfumount_called)
          raise RuntimeError, "cleanup failed"
        end
      )

    log =
      capture_log(fn ->
        assert_raise RuntimeError, "losetup failed", fn ->
          BlockDevice.setup(bd)
        end
      end)

    assert log =~ "Error cleaning up EWF mount after setup failure: cleanup failed"
    assert_received :ewfumount_called
  end

  test "EwfMountUsesMountroot" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        mountroot: "/custom-mnt",
        which_fn: fn "ewfmount" -> "/usr/bin/ewfmount" end,
        mkdtemp_fn: fn prefix, dir ->
          send(test_pid, {:mkdtemp, prefix, dir})
          "/custom-mnt/openrelik-ewf-test"
        end,
        cmd_runner: fn _ -> %{returncode: 0, stdout: "", stderr: ""} end,
        path_exists_fn: fn _ -> true end
      )

    raw_image_path = BlockDevice.ewfmount(bd)
    assert_received {:mkdtemp, "openrelik-ewf-", "/custom-mnt"}
    assert raw_image_path == "/custom-mnt/openrelik-ewf-test/ewf1"
  end

  test "EwfUmountKeepsMountPathOnFailure" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        which_fn: fn _ -> "/usr/bin/tool" end,
        sleep_fn: fn secs -> send(test_pid, {:sleep, secs}) end,
        rmtree_fn: fn path -> send(test_pid, {:rmtree, path}) end,
        cmd_runner: fn _ -> %{returncode: 1, stdout: "", stderr: "target is busy"} end
      )

    bd = %{bd | ewf_mount_path: "/mnt/openrelik-ewf-test"}

    assert_raise RuntimeError, ~r/Error unmounting EWF image mount/, fn ->
      BlockDevice.ewfumount(bd)
    end

    assert bd.ewf_mount_path == "/mnt/openrelik-ewf-test"
    assert_received {:sleep, 0.2}
    refute_received {:rmtree, _}
  end

  test "QcowSetupChecksNbdModule" do
    test_pid = self()

    bd =
      BlockDevice.new("./test_data/image_with_partitions.qcow2",
        path_exists_fn: fn _ -> true end,
        required_tools_available_fn: fn -> true end,
        required_modules_loaded_fn: fn ->
          send(test_pid, :modules_called)
          :ok
        end,
        redis_from_url_fn: fn _ -> new_fake_redis() end,
        nbdsetup_fn: fn ->
          send(test_pid, :nbdsetup_called)
          "/dev/nbd0"
        end,
        blkinfo_fn: fn -> %{"blockdevices" => []} end,
        parse_partitions_fn: fn -> [] end
      )
      |> BlockDevice.setup()

    assert_received :modules_called
    assert_received :nbdsetup_called
    assert bd.blkdevice == "/dev/nbd0"
  end

  test "UmountCleansUpEwfMount" do
    test_pid = self()

    bd =
      BlockDevice.new(@ewf_image_path,
        umount_all_fn: fn -> send(test_pid, :umount_all) end,
        detach_device_fn: fn -> send(test_pid, :detach_device) end,
        ewfumount_fn: fn -> send(test_pid, :ewfumount) end
      )

    bd = %{bd | blkdevice: "/dev/loop0", ewf_mount_path: "/mnt/openrelik-ewf-test"}
    _bd = BlockDevice.umount(bd)

    assert_received :umount_all
    assert_received :detach_device
    assert_received :ewfumount
  end

  test "MountWithNonExistingPartition raises RuntimeError" do
    bd = %BlockDevice{
      BlockDevice.new("./test_data/image_with_partitions.img")
      | blkdevice: "/dev/loop0",
        partitions: ["/dev/loop0p1", "/dev/loop0p2"]
    }

    assert_raise RuntimeError,
                 "Error running mount: partition name /dev/loop0p999 not found",
                 fn ->
                   BlockDevice.mount(bd, "/dev/loop0p999")
                 end
  end

  test "MountNothingTodo raises RuntimeError when blkid fails on nonexistent device" do
    bd =
      BlockDevice.new("./test_data/image_with_partitions.img",
        cmd_runner: fn ["sudo", "blkid" | _] ->
          %{returncode: 2, stdout: "", stderr: ""}
        end
      )

    bd = %{bd | blkdevice: "/dev/doesnotexist", partitions: []}

    assert_raise RuntimeError, "Error running blkid on /dev/doesnotexist:  ", fn ->
      BlockDevice.mount(bd)
    end
  end

  test "ParsePartitions and ParsePartitionsEmpty" do
    bd_empty = %BlockDevice{
      BlockDevice.new("./test_data/image_vfat.img",
        is_important_partition_fn: fn _ -> true end
      )
      | blkdeviceinfo: %{
          "blockdevices" => [
            %{"name" => "loop0", "size" => 1_048_576, "type" => "loop"}
          ]
        }
    }

    assert BlockDevice.parse_partitions(bd_empty) == []

    bd_parts = %BlockDevice{
      BlockDevice.new("./test_data/image_with_partitions.img",
        is_important_partition_fn: fn _ -> true end
      )
      | blkdeviceinfo: %{
          "blockdevices" => [
            %{
              "name" => "loop0",
              "size" => 10_485_760,
              "children" => [
                %{"name" => "loop0p1", "size" => 5_242_880},
                %{"name" => "loop0p2", "size" => 5_242_880}
              ]
            }
          ]
        }
    }

    assert BlockDevice.parse_partitions(bd_parts) == ["/dev/loop0p1", "/dev/loop0p2"]
  end

  test "DetachDevice raises RuntimeError on failure" do
    bd =
      BlockDevice.new("./test_data/image_vfat.img",
        cmd_runner: fn _ ->
          %{returncode: 1, stdout: "Device does not exist", stderr: ""}
        end
      )

    bd = %{bd | blkdevice: "/dev/nbd0"}

    assert_raise RuntimeError, "Error detaching block device:  Device does not exist", fn ->
      BlockDevice.detach_device(bd)
    end
  end

  test "UmountFail raises RuntimeError" do
    bd =
      BlockDevice.new("./test_data/image_vfat.img",
        cmd_runner: fn _ ->
          %{returncode: 1, stdout: "", stderr: "umount failed."}
        end
      )

    bd = %{bd | mountpoints: ["/mnt/folder"]}

    assert_raise RuntimeError, "Error running umount on /mnt/folder: umount failed. ", fn ->
      BlockDevice.umount_all(bd)
    end
  end

  test "IsImportantPartition" do
    partition = %{"name" => "loop0p1", "size" => 1_000_000_000}

    bd_ext4 =
      BlockDevice.new("./test_data/image_vfat.img",
        get_fstype_fn: fn _ -> "ext4" end
      )

    assert BlockDevice.is_important_partition(bd_ext4, partition) == true

    bd_unsupported =
      BlockDevice.new("./test_data/image_vfat.img",
        get_fstype_fn: fn _ -> "typenotsupported" end
      )

    assert BlockDevice.is_important_partition(bd_unsupported, partition) == false
  end

  test "RequiredToolsAvailable all, none, and some tools available" do
    bd_all = BlockDevice.new("./test_data/image_vfat.img", which_fn: fn _ -> "/path/to/tool" end)
    assert BlockDevice.required_tools_available(bd_all) == true

    bd_none = BlockDevice.new("./test_data/image_vfat.img", which_fn: fn _ -> nil end)

    assert_raise RuntimeError,
                 "Missing required tools: lsblk blkid mount qemu-nbd sudo fdisk ntfsinfo. Make sure you have the fdisk, qemu-utils and ntfs-3g packages installed!",
                 fn ->
                   BlockDevice.required_tools_available(bd_none)
                 end

    {:ok, agent} =
      Agent.start_link(fn ->
        [
          "/path/to/lsblk",
          nil,
          "/path/to/mount",
          nil,
          nil,
          "/path/to/partprobe",
          "/path/to/ntfsinfo"
        ]
      end)

    bd_some =
      BlockDevice.new("./test_data/image_vfat.img",
        which_fn: fn _ ->
          Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
        end
      )

    assert_raise RuntimeError,
                 "Missing required tools: blkid qemu-nbd sudo. Make sure you have the fdisk, qemu-utils and ntfs-3g packages installed!",
                 fn ->
                   BlockDevice.required_tools_available(bd_some)
                 end
  end

  test "GetMountPath default, max, and error" do
    bd_short =
      BlockDevice.new("./test_data/image_vfat.img",
        max_mountpath_size: 10,
        mountroot: "/mnt"
      )

    mountpath = BlockDevice.get_mount_path(bd_short)
    assert String.length(mountpath) == 10

    bd_max = BlockDevice.new("./test_data/image_vfat.img", mountroot: "/mnt")
    mountpath_max = BlockDevice.get_mount_path(bd_max)
    assert String.length(mountpath_max) == 37

    bd_err =
      BlockDevice.new("./test_data/image_vfat.img",
        max_mountpath_size: 5,
        mountroot: "/mnt"
      )

    assert_raise RuntimeError,
                 "Error generating mount path: the max_mount_path size (5) is too short, please choose a larger maximum mountpath size, minimum is self.mountroot + 1",
                 fn ->
                   BlockDevice.get_mount_path(bd_err)
                 end
  end

  test "IsImportantPartitionNone logs warning when fs type is empty" do
    bd =
      BlockDevice.new("./test_data/image_vfat.img",
        cmd_runner: fn _ -> %{returncode: 0, stdout: "", stderr: ""} end
      )

    partition = %{"name" => "test_partition_name", "size" => 1_000_000_000}

    log =
      capture_log(fn ->
        assert BlockDevice.is_important_partition(bd, partition) == false
      end)

    assert log =~ "Ignoring partition /dev/test_partition_name as fs type not available!"
  end
end
