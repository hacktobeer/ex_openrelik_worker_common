# Copyright 2025 Google LLC
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

defmodule OpenrelikWorkerCommon.MountUtils.RedisLock do
  @moduledoc """
  Distributed Redis lock for NBD device coordination across containers/nodes,
  matching Python `redis.lock.Lock` (`name`, `timeout`, `token`, `acquire/1`, `release/1`).
  """

  alias OpenrelikWorkerCommon.FileUtils

  @type t :: %__MODULE__{
          name: String.t(),
          timeout: pos_integer(),
          token: String.t(),
          client: term()
        }

  @enforce_keys [:name, :timeout, :token, :client]
  defstruct [:name, :timeout, :token, :client]

  @release_lua_script """
  if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
  else
    return 0
  end
  """

  @doc "Creates a new `RedisLock` struct."
  @spec new(term(), String.t(), pos_integer()) :: t()
  def new(client, name, timeout) when is_binary(name) and is_integer(timeout) do
    %__MODULE__{
      name: name,
      timeout: timeout,
      token: FileUtils.uuid4_hex(),
      client: client
    }
  end

  @doc "Attempts to acquire the Redis lock non-blockingly (`SET name token NX EX timeout`)."
  @spec acquire(t()) :: boolean()
  def acquire(%__MODULE__{name: name, timeout: timeout, token: token, client: client}) do
    case client do
      %{acquire: acquire_fn} when is_function(acquire_fn, 3) ->
        acquire_fn.(name, token, timeout)

      pid when is_pid(pid) or is_atom(pid) ->
        case Redix.command(pid, ["SET", name, token, "NX", "EX", to_string(timeout)]) do
          {:ok, "OK"} -> true
          _ -> false
        end
    end
  end

  @doc "Releases the Redis lock if still owned by `token`."
  @spec release(t()) :: :ok
  def release(%__MODULE__{name: name, token: token, client: client}) do
    case client do
      %{release: release_fn} when is_function(release_fn, 2) ->
        release_fn.(name, token)
        :ok

      pid when is_pid(pid) or is_atom(pid) ->
        _ = Redix.command(pid, ["EVAL", @release_lua_script, "1", name, token])
        :ok
    end
  end
end

defmodule OpenrelikWorkerCommon.MountUtils.BlockDevice do
  @moduledoc """
  Provides functionality to map a disk image file to block devices (`loop` or `nbd`)
  and mount them (`openrelik_worker_common.mount_utils.BlockDevice`).

  The default minimum partition size that gets mounted is 100 MB (`104_857_600` bytes).
  """

  require Logger

  alias OpenrelikWorkerCommon.FileUtils
  alias OpenrelikWorkerCommon.MountUtils.RedisLock

  @min_partition_size_bytes 100 * 1024 * 1024
  @max_nbd_devices 10
  @lock_timeout_seconds 6 * 60 * 60
  @max_mountpath_size 500

  @supported_fstypes [
    "dos",
    "xfs",
    "ext2",
    "ext3",
    "ext4",
    "ntfs",
    "vfat",
    "btrfs"
  ]

  @supported_qcowtypes ["qcow3", "qcow2", "qcow"]
  @supported_ewftypes ["e01", "ex01"]
  @required_tools ["lsblk", "blkid", "mount", "qemu-nbd", "sudo", "fdisk", "ntfsinfo"]

  @type cmd_result :: %{
          returncode: integer(),
          stdout: String.t() | nil,
          stderr: String.t() | nil
        }

  @type t :: %__MODULE__{
          original_image_path: String.t(),
          image_path: String.t(),
          min_partition_size: non_neg_integer(),
          blkdevice: String.t() | nil,
          blkdeviceinfo: map() | nil,
          partitions: [String.t()],
          mountpoints: [String.t()],
          mountroot: String.t(),
          max_mountpath_size: pos_integer(),
          supported_fstypes: [String.t()],
          supported_qcowtypes: [String.t()],
          supported_ewftypes: [String.t()],
          ewf_mount_path: String.t() | nil,
          redis_url: String.t(),
          redis_client: term(),
          redis_lock: RedisLock.t() | nil,
          opts: keyword()
        }

  defstruct original_image_path: nil,
            image_path: nil,
            min_partition_size: @min_partition_size_bytes,
            blkdevice: nil,
            blkdeviceinfo: nil,
            partitions: [],
            mountpoints: [],
            mountroot: "/mnt",
            max_mountpath_size: @max_mountpath_size,
            supported_fstypes: @supported_fstypes,
            supported_qcowtypes: @supported_qcowtypes,
            supported_ewftypes: @supported_ewftypes,
            ewf_mount_path: nil,
            redis_url: "redis://localhost:6379/0",
            redis_client: nil,
            redis_lock: nil,
            opts: []

  @doc "Default minimum partition size in bytes (100 MB)."
  @spec min_partition_size_bytes() :: pos_integer()
  def min_partition_size_bytes, do: @min_partition_size_bytes

  @doc "Default maximum NBD device index (`10`)."
  @spec max_nbd_devices() :: pos_integer()
  def max_nbd_devices, do: @max_nbd_devices

  @doc "Default Redis lock timeout in seconds (`21600`, 6 hours)."
  @spec lock_timeout_seconds() :: pos_integer()
  def lock_timeout_seconds, do: @lock_timeout_seconds

  @doc "Default maximum mount path character length (`500`)."
  @spec max_mountpath_size() :: pos_integer()
  def max_mountpath_size, do: @max_mountpath_size

  @doc """
  Initializes a `%BlockDevice{}` struct.

  ## Options
  * `:min_partition_size` - Minimum partition size in bytes (default `104_857_600`).
  * `:max_mountpath_size` - Maximum root mount path length (default `500`).
  * `:mountroot` - Root directory for mount points (default `"/mnt"`).
  * `:redis_url` - Redis URL override (default `System.get_env("REDIS_URL") || "redis://localhost:6379/0"`).
  * `:redis_client` - Optional pre-configured Redis client or mock client map.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(image_path, opts \\ []) when is_binary(image_path) and is_list(opts) do
    min_partition_size = Keyword.get(opts, :min_partition_size, @min_partition_size_bytes)
    max_mountpath_size = Keyword.get(opts, :max_mountpath_size, @max_mountpath_size)
    mountroot = Keyword.get(opts, :mountroot, "/mnt")

    redis_url =
      Keyword.get(opts, :redis_url) || System.get_env("REDIS_URL") || "redis://localhost:6379/0"

    redis_client = Keyword.get(opts, :redis_client)

    %__MODULE__{
      original_image_path: image_path,
      image_path: image_path,
      min_partition_size: min_partition_size,
      max_mountpath_size: max_mountpath_size,
      mountroot: mountroot,
      redis_url: redis_url,
      redis_client: redis_client,
      opts: opts
    }
  end

  @doc """
  Sets up the `BlockDevice` instance: checks if the image exists, verifies required tools,
  configures the block device (`ewfmount`, `qemu-nbd`, or `losetup`), queries `lsblk`,
  and scans available partitions.

  If an error occurs during setup, any partially attached block device, EWF mount, or
  Redis lock is automatically cleaned up before re-raising the original `RuntimeError`.
  """
  @spec setup(t()) :: t()
  def setup(%__MODULE__{} = bd) do
    Logger.info(
      "Minimum partition size #{bd.min_partition_size} Bytes, partitions smaller will be ignored!"
    )

    if not path_exists?(bd, bd.image_path) do
      raise RuntimeError, "image_path does not exist: #{bd.image_path}"
    end

    _ = required_tools_available(bd)

    ext = image_extension(bd.image_path)

    do_setup_with_cleanup(bd, ext)
  end

  defp do_setup_with_cleanup(bd, ext) do
    state_ref = make_ref()
    Process.put(state_ref, bd)

    try do
      bd =
        if ext in bd.supported_ewftypes do
          {bd_after_ewf, raw_path} = ewfmount_with_state(bd)
          updated = %{bd_after_ewf | image_path: raw_path}
          Process.put(state_ref, updated)
          updated
        else
          bd
        end

      ext = image_extension(bd.image_path)

      bd =
        if ext in bd.supported_qcowtypes do
          :ok = required_modules_loaded(bd)
          bd = ensure_redis_client(bd)
          Process.put(state_ref, bd)
          {bd_after_nbd, blkdev} = nbdsetup_with_state(bd)
          updated = %{bd_after_nbd | blkdevice: blkdev}
          Process.put(state_ref, updated)
          updated
        else
          blkdev = losetup(bd)
          updated = %{bd | blkdevice: blkdev}
          Process.put(state_ref, updated)
          updated
        end

      info = blkinfo(bd)
      bd = %{bd | blkdeviceinfo: info}
      Process.put(state_ref, bd)

      partitions = parse_partitions(bd)
      %{bd | partitions: partitions}
    rescue
      e ->
        current_bd = Process.get(state_ref, bd)
        cleanup_failed_setup(current_bd)
        reraise e, __STACKTRACE__
    after
      Process.delete(state_ref)
    end
  end

  defp cleanup_failed_setup(%__MODULE__{} = bd) do
    if bd.blkdevice do
      try do
        _ = detach_device(bd)
      rescue
        cleanup_error in RuntimeError ->
          Logger.error(
            "Error detaching block device after setup failure: #{Exception.message(cleanup_error)}"
          )
      end
    end

    if bd.ewf_mount_path do
      try do
        _ = ewfumount(bd)
      rescue
        cleanup_error in RuntimeError ->
          Logger.error(
            "Error cleaning up EWF mount after setup failure: #{Exception.message(cleanup_error)}"
          )
      end
    end

    if bd.redis_lock do
      try do
        RedisLock.release(bd.redis_lock)
      rescue
        cleanup_error ->
          Logger.error(
            "Error releasing Redis lock after setup failure: #{Exception.message(cleanup_error)}"
          )
      end
    end
  end

  @doc """
  Maps `bd.image_path` to a loopback device using `losetup`.
  """
  @spec losetup(t()) :: String.t()
  def losetup(%__MODULE__{} = bd) do
    case get_override(bd, :losetup_fn) do
      fun when is_function(fun, 1) ->
        fun.(bd)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        losetup_command = [
          "sudo",
          "losetup",
          "--find",
          "--partscan",
          "--show",
          "--read-only",
          bd.image_path
        ]

        process = run_cmd(bd, losetup_command)

        if process.returncode == 0 do
          blkdevice = String.trim(process.stdout || "")
          Logger.info("losetup: success creating #{blkdevice} for #{bd.image_path}")
          blkdevice
        else
          Logger.error(
            "losetup: failed creating blockdevice for #{bd.image_path}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
          )

          raise RuntimeError, "Error: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end
    end
  end

  @doc """
  Returns the hostname from the `NODENAME` environment variable or OS hostname.
  """
  @spec get_hostname(t() | nil) :: String.t()
  def get_hostname(bd \\ nil) do
    case get_override(bd, :get_hostname_fn) do
      fun when is_function(fun, 0) ->
        fun.()

      fun when is_function(fun, 1) ->
        fun.(bd)

      _ ->
        env_fn = get_override(bd, :env_get_fn) || (&System.get_env/1)
        hostname = env_fn.("NODENAME")

        if is_binary(hostname) and hostname != "" do
          hostname
        else
          socket_fn =
            get_override(bd, :gethostname_fn) ||
              fn ->
                {:ok, host} = :inet.gethostname()
                List.to_string(host)
              end

          socket_fn.()
        end
    end
  end

  @doc """
  Finds and locks a free NBD device (`/dev/nbd0`..`/dev/nbd10`) in Redis until unlocked or timeout.

  Returns `{updated_bd, devname}` (or `devname` when called via `_get_free_nbd_device` override).
  """
  @spec get_free_nbd_device(t()) :: {t(), String.t()}
  def get_free_nbd_device(%__MODULE__{} = bd) do
    case get_override(bd, :get_free_nbd_device_fn) do
      fun when is_function(fun, 1) ->
        case fun.(bd) do
          {%__MODULE__{} = updated_bd, devname} -> {updated_bd, devname}
          devname when is_binary(devname) -> {%{bd | blkdevice: devname}, devname}
        end

      fun when is_function(fun, 0) ->
        devname = fun.()
        {%{bd | blkdevice: devname}, devname}

      _ ->
        bd = ensure_redis_client(bd)
        hostname = get_hostname(bd)

        result =
          Enum.find_value(0..@max_nbd_devices, fn device_number ->
            devname = "/dev/nbd#{device_number}"
            lock_name = "#{hostname}-#{devname}"
            lock = RedisLock.new(bd.redis_client, lock_name, @lock_timeout_seconds)

            if RedisLock.acquire(lock) do
              Logger.info("Redis lock succesfully set: #{lock.name} for #{hostname}-#{devname}")
              {%{bd | redis_lock: lock, blkdevice: devname}, devname}
            else
              nil
            end
          end)

        case result do
          {%__MODULE__{} = updated_bd, devname} ->
            {updated_bd, devname}

          nil ->
            raise RuntimeError, "Error getting free NBD device: All NBD devices locked!"
        end
    end
  end

  @doc """
  Maps a QCOW image file to an NBD device using `qemu-nbd` and probes partitions with `fdisk`.
  """
  @spec nbdsetup(t()) :: String.t()
  def nbdsetup(%__MODULE__{} = bd) do
    {_updated_bd, blkdevice} = nbdsetup_with_state(bd)
    blkdevice
  end

  @doc false
  @spec nbdsetup_with_state(t()) :: {t(), String.t()}
  def nbdsetup_with_state(%__MODULE__{} = bd) do
    case get_override(bd, :nbdsetup_fn) do
      fun when is_function(fun, 1) ->
        case fun.(bd) do
          {%__MODULE__{} = updated_bd, dev} -> {updated_bd, dev}
          dev when is_binary(dev) -> {%{bd | blkdevice: dev}, dev}
        end

      fun when is_function(fun, 0) ->
        dev = fun.()
        {%{bd | blkdevice: dev}, dev}

      _ ->
        {bd, blkdevice} = get_free_nbd_device(bd)
        bd = %{bd | blkdevice: blkdevice}

        nbdsetup_command = [
          "sudo",
          "qemu-nbd",
          "--read-only",
          "--connect",
          blkdevice,
          bd.image_path
        ]

        process = run_cmd(bd, nbdsetup_command)

        if process.returncode == 0 do
          Logger.info("qemu-nbd: success creating #{blkdevice} for #{bd.image_path}")
        else
          Logger.error(
            "qemu-nbd: failed creating #{blkdevice} for #{bd.image_path}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
          )

          raise RuntimeError,
                "Error running qemu-nbd: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end

        sleep(bd, 0.2)

        fdisk_command = [
          "sudo",
          "fdisk",
          "-l",
          String.trim(blkdevice)
        ]

        fdisk_process = run_cmd(bd, fdisk_command)

        if fdisk_process.returncode == 0 do
          Logger.info("fdisk: success probing #{blkdevice} for #{bd.image_path}")
        else
          Logger.error(
            "fdisk: failed probing #{blkdevice} for #{bd.image_path}: #{fmt_out(fdisk_process.stderr)} #{fmt_out(fdisk_process.stdout)}"
          )

          raise RuntimeError,
                "Error fdisk: failed probing: #{fmt_out(fdisk_process.stderr)} #{fmt_out(fdisk_process.stdout)}"
        end

        {bd, blkdevice}
    end
  end

  @doc """
  Mounts an EWF image (`.E01` / `.EX01`) using `ewfmount` and returns `{updated_bd, raw_image_path}`.
  """
  @spec ewfmount(t()) :: String.t()
  def ewfmount(%__MODULE__{} = bd) do
    {_updated_bd, raw_image_path} = ewfmount_with_state(bd)
    raw_image_path
  end

  @doc false
  @spec ewfmount_with_state(t()) :: {t(), String.t()}
  def ewfmount_with_state(%__MODULE__{} = bd) do
    case get_override(bd, :ewfmount_fn) do
      fun when is_function(fun, 1) ->
        case fun.(bd) do
          {%__MODULE__{} = updated_bd, raw_path} -> {updated_bd, raw_path}
          raw_path when is_binary(raw_path) -> {bd, raw_path}
        end

      fun when is_function(fun, 0) ->
        {bd, fun.()}

      _ ->
        if not truthy_executable?(which(bd, "ewfmount")) do
          raise RuntimeError,
                "Missing required tool: ewfmount. Make sure ewf-tools is installed!"
        end

        ewf_mount_path = mkdtemp(bd, "openrelik-ewf-", bd.mountroot)
        bd = %{bd | ewf_mount_path: ewf_mount_path}

        process = run_cmd(bd, ["ewfmount", bd.image_path, ewf_mount_path])

        if process.returncode != 0 do
          rmtree(bd, ewf_mount_path)

          raise RuntimeError,
                "ewfmount failed for #{bd.image_path}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end

        raw_image_path = Path.join(ewf_mount_path, "ewf1")

        if not path_exists?(bd, raw_image_path) do
          _ = ewfumount(bd)
          raise RuntimeError, "ewfmount did not expose expected raw image: #{raw_image_path}"
        end

        Logger.info("ewfmount: success mounting #{bd.image_path}")
        {bd, raw_image_path}
    end
  end

  @doc """
  Unmounts an EWF FUSE mount and removes its mount directory.
  """
  @spec ewfumount(t()) :: t()
  def ewfumount(%__MODULE__{ewf_mount_path: nil} = bd), do: bd

  def ewfumount(%__MODULE__{ewf_mount_path: mount_path} = bd) when is_binary(mount_path) do
    case get_override(bd, :ewfumount_fn) do
      fun when is_function(fun, 1) ->
        case fun.(bd) do
          %__MODULE__{} = updated_bd -> updated_bd
          _ -> %{bd | ewf_mount_path: nil}
        end

      fun when is_function(fun, 0) ->
        fun.()
        %{bd | ewf_mount_path: nil}

      _ ->
        unmount_commands = [
          ["fusermount3", "-u", mount_path],
          ["fusermount3", "-u", "-z", mount_path],
          ["fusermount", "-u", mount_path],
          ["fusermount", "-u", "-z", mount_path],
          ["sudo", "umount", mount_path],
          ["sudo", "umount", "-l", mount_path]
        ]

        sleep(bd, 0.2)

        result =
          Enum.reduce_while(unmount_commands, {:error, ""}, fn [tool | _] = command,
                                                               {:error, last_err} ->
            if not truthy_executable?(which(bd, tool)) do
              {:cont, {:error, last_err}}
            else
              process = run_cmd(bd, command)

              if process.returncode == 0 do
                Logger.info("ewfmount: success unmounting #{mount_path}")
                rmtree(bd, mount_path)
                {:halt, {:ok, %{bd | ewf_mount_path: nil}}}
              else
                {:cont, {:error, "#{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"}}
              end
            end
          end)

        case result do
          {:ok, updated_bd} ->
            updated_bd

          {:error, last_error} ->
            raise RuntimeError, "Error unmounting EWF image mount #{mount_path}: #{last_error}"
        end
    end
  end

  @doc """
  Checks if the `nbd` kernel module is loaded or if `/dev/nbd*` devices exist.
  """
  @spec required_modules_loaded(t() | nil) :: :ok
  def required_modules_loaded(bd \\ nil) do
    case get_override(bd, :required_modules_loaded_fn) do
      fun when is_function(fun, 1) ->
        fun.(bd)
        :ok

      fun when is_function(fun, 0) ->
        fun.()
        :ok

      _ ->
        glob_fn = get_override(bd, :glob_fn) || (&Path.wildcard/1)
        nbd_devices = glob_fn.("/dev/nbd*")

        if nbd_devices != [] do
          Logger.info(
            "Found #{length(nbd_devices)} existing nbd device(s). Skipping kernel module check."
          )

          :ok
        else
          for module <- ["nbd"] do
            process =
              run_cmd(bd, ["/usr/bin/grep", "-E", "^#{module}\\s", "/proc/modules"])

            if process.returncode != 0 do
              raise RuntimeError,
                    "Required kernel module #{module} is not loaded. Load it with '/sbin/modprobe #{module}' on the Host."
            end
          end

          :ok
        end
    end
  end

  @doc """
  Checks if required CLI tools (`lsblk`, `blkid`, `mount`, `qemu-nbd`, `sudo`, `fdisk`, `ntfsinfo`)
  are available on `PATH`.
  """
  @spec required_tools_available(t() | nil) :: boolean()
  def required_tools_available(bd \\ nil) do
    case get_override(bd, :required_tools_available_fn) do
      fun when is_function(fun, 1) ->
        fun.(bd)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        missing_tools =
          Enum.filter(@required_tools, fn tool ->
            not truthy_executable?(which(bd, tool))
          end)

        if missing_tools != [] do
          raise RuntimeError,
                "Missing required tools: #{Enum.join(missing_tools, " ")}. Make sure you have the fdisk, qemu-utils and ntfs-3g packages installed!"
        end

        true
    end
  end

  @doc """
  Extracts device and partition information using `lsblk -ba -J`.
  """
  @spec blkinfo(t()) :: map()
  def blkinfo(%__MODULE__{} = bd) do
    case get_override(bd, :blkinfo_fn) do
      fun when is_function(fun, 1) ->
        fun.(bd)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        lsblk_command = ["sudo", "lsblk", "-ba", "-J", bd.blkdevice]
        process = run_cmd(bd, lsblk_command)

        if process.returncode == 0 do
          lsblk_json_output = String.trim(process.stdout || "")

          case JSON.decode(lsblk_json_output) do
            {:ok, blkdeviceinfo} when is_map(blkdeviceinfo) ->
              Logger.info("Success parsing lsblk info: #{inspect(blkdeviceinfo)}")
              blkdeviceinfo

            {:error, reason} ->
              Logger.error("Error parsing lsblk json output: #{lsblk_json_output}")

              raise RuntimeError,
                    "Error parsing lsblk json output: #{lsblk_json_output}: #{inspect(reason)}"
          end
        else
          Logger.error(
            "Error running lsblk on #{bd.blkdevice}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
          )

          raise RuntimeError,
                "Error lsblk: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end
    end
  end

  @doc """
  Parses partition information from `bd.blkdeviceinfo`.
  """
  @spec parse_partitions(t()) :: [String.t()]
  def parse_partitions(%__MODULE__{} = bd) do
    case get_override(bd, :parse_partitions_fn) do
      fun when is_function(fun, 1) ->
        fun.(bd)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        info = bd.blkdeviceinfo || %{}

        if not Map.has_key?(info, "blockdevices") do
          raise RuntimeError, "_parse_partitions: self.blkdeviceinfo malformed"
        end

        blockdevices = Map.get(info, "blockdevices") || []

        if blockdevices == [] do
          Logger.warning("_parse_partitions: blkdeviceinfo.blockdevices had 0 length")
          []
        else
          first_bd = hd(blockdevices)
          children = Map.get(first_bd, "children")

          if not is_list(children) do
            []
          else
            Enum.reduce(children, [], fn child, acc ->
              name = Map.get(child, "name") || Map.get(child, :name)
              partition = "/dev/#{name}"

              if is_important_partition(bd, child) do
                acc ++ [partition]
              else
                acc
              end
            end)
          end
        end
    end
  end

  @doc """
  Returns `true` if `devname` points to a block device containing a supported filesystem type.
  """
  @spec is_supported_fs(t(), String.t()) :: boolean()
  def is_supported_fs(%__MODULE__{} = bd, devname) when is_binary(devname) do
    fs_type = get_fstype(bd, devname)

    cond do
      fs_type == "" ->
        Logger.warning("Ignoring partition #{devname} as fs type not available!")
        false

      fs_type not in bd.supported_fstypes ->
        Logger.warning("Ignoring partition #{devname} as fs type #{fs_type} not supported!")
        false

      true ->
        true
    end
  end

  @doc """
  Decides if a partition should be processed (`size >= min_partition_size` and supported fs type).
  """
  @spec is_important_partition(t(), map()) :: boolean()
  def is_important_partition(%__MODULE__{} = bd, partition) when is_map(partition) do
    case get_override(bd, :is_important_partition_fn) do
      fun when is_function(fun, 2) ->
        fun.(bd, partition)

      fun when is_function(fun, 1) ->
        fun.(partition)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        size = Map.get(partition, "size") || Map.get(partition, :size) || 0
        name = Map.get(partition, "name") || Map.get(partition, :name)

        if size < bd.min_partition_size do
          Logger.info("Ignoring partion #{name} as size < #{bd.min_partition_size}")
          false
        else
          is_supported_fs(bd, "/dev/#{name}")
        end
    end
  end

  @doc """
  Analyses the file system type of a block device or partition using `blkid`.
  """
  @spec get_fstype(t(), String.t()) :: String.t()
  def get_fstype(%__MODULE__{} = bd, devname) when is_binary(devname) do
    case get_override(bd, :get_fstype_fn) do
      fun when is_function(fun, 2) ->
        fun.(bd, devname)

      fun when is_function(fun, 1) ->
        fun.(devname)

      fun when is_function(fun, 0) ->
        fun.()

      _ ->
        blkid_command = ["sudo", "blkid", "-s", "TYPE", "-o", "value", "#{devname}"]
        process = run_cmd(bd, blkid_command)

        if process.returncode == 0 do
          String.trim(process.stdout || "")
        else
          Logger.error(
            "Error running blkid on #{devname}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
          )

          raise RuntimeError,
                "Error running blkid on #{devname}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end
    end
  end

  @doc """
  Selects partitions to mount.
  """
  @spec select_partitions_to_mount(t(), String.t()) :: [String.t()]
  def select_partitions_to_mount(%__MODULE__{} = bd, partition_name \\ "") do
    partitions =
      case bd.partitions do
        list when is_list(list) -> list
        _ -> []
      end

    if partition_name != "" and partition_name not in partitions do
      Logger.error("Error running mount: partition name #{partition_name} not found")
      raise RuntimeError, "Error running mount: partition name #{partition_name} not found"
    end

    cond do
      partition_name != "" ->
        [partition_name]

      partitions == [] ->
        if is_supported_fs(bd, bd.blkdevice) do
          [bd.blkdevice]
        else
          []
        end

      true ->
        partitions
    end
  end

  @doc """
  Generates a mount path under `bd.mountroot` respecting `bd.max_mountpath_size`.
  """
  @spec get_mount_path(t()) :: String.t()
  def get_mount_path(%__MODULE__{} = bd) do
    mountroot_len = String.length(bd.mountroot)

    if bd.max_mountpath_size <= mountroot_len + 1 do
      raise RuntimeError,
            "Error generating mount path: the max_mount_path size (#{bd.max_mountpath_size}) is too short, please choose a larger maximum mountpath size, minimum is self.mountroot + 1"
    end

    max_uuid_size = bd.max_mountpath_size - mountroot_len - 1
    uuid_path_part = String.slice(FileUtils.uuid4_hex(), 0, max_uuid_size)
    "#{bd.mountroot}/#{uuid_path_part}"
  end

  @doc """
  Mounts a disk or one or more partitions on a mountpoint.

  Returns `{updated_bd, mountpoints}`.
  """
  @spec mount(t(), String.t() | keyword()) :: {t(), [String.t()]}
  def mount(%__MODULE__{} = bd, partition_name_or_opts \\ "") do
    partition_name =
      cond do
        is_binary(partition_name_or_opts) ->
          partition_name_or_opts

        is_list(partition_name_or_opts) ->
          Keyword.get(partition_name_or_opts, :partition_name, "")

        true ->
          ""
      end

    to_mount = select_partitions_to_mount(bd, partition_name)

    mounted =
      Enum.map(to_mount, fn mounttarget ->
        Logger.info("Trying to mount #{mounttarget}")
        fstype = get_fstype(bd, mounttarget)

        mount_opts =
          cond do
            fstype == "xfs" -> ["-o", "ro,norecovery"]
            fstype in ["ext2", "ext3", "ext4"] -> ["-o", "ro,noload"]
            true -> ["-o", "ro"]
          end

        mount_folder = get_mount_path(bd)
        makedirs(bd, mount_folder)

        mount_command = ["sudo", "mount"] ++ mount_opts ++ [mounttarget, mount_folder]
        process = run_cmd(bd, mount_command)

        if process.returncode == 0 do
          Logger.info("Mounted #{mounttarget} to #{mount_folder}")
          mount_folder
        else
          Logger.error(
            "Error running mount on #{mounttarget}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
          )

          raise RuntimeError,
                "Error running mount on #{mounttarget}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end
      end)

    new_mountpoints = bd.mountpoints ++ mounted
    {%{bd | mountpoints: new_mountpoints}, new_mountpoints}
  end

  @doc """
  Unmounts all registered `mountpoints` and removes their directories.
  """
  @spec umount_all(t()) :: t()
  def umount_all(%__MODULE__{} = bd) do
    case get_override(bd, :umount_all_fn) do
      fun when is_function(fun, 1) ->
        case fun.(bd) do
          %__MODULE__{} = updated -> updated
          _ -> %{bd | mountpoints: []}
        end

      fun when is_function(fun, 0) ->
        fun.()
        %{bd | mountpoints: []}

      _ ->
        Enum.each(bd.mountpoints, fn mountpoint ->
          umount_command = ["sudo", "umount", "#{mountpoint}"]
          process = run_cmd(bd, umount_command)

          if process.returncode == 0 do
            Logger.info("umount #{mountpoint} success")
            rmdir(bd, mountpoint)
          else
            Logger.error(
              "Error running umount on #{mountpoint}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
            )

            raise RuntimeError,
                  "Error running umount on #{mountpoint}: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
          end
        end)

        %{bd | mountpoints: []}
    end
  end

  @doc """
  Detaches the block device (`qemu-nbd --disconnect` for NBD devices or `losetup --detach` for loop devices).
  """
  @spec detach_device(t()) :: t()
  def detach_device(%__MODULE__{} = bd) do
    case get_override(bd, :detach_device_fn) do
      fun when is_function(fun, 1) ->
        case fun.(bd) do
          %__MODULE__{} = updated -> updated
          _ -> %{bd | blkdevice: nil}
        end

      fun when is_function(fun, 0) ->
        fun.()
        %{bd | blkdevice: nil}

      _ ->
        command =
          if String.contains?(bd.blkdevice || "", "nbd") do
            ["sudo", "qemu-nbd", "--disconnect", bd.blkdevice]
          else
            ["sudo", "losetup", "--detach", bd.blkdevice]
          end

        process = run_cmd(bd, command)

        if process.returncode == 0 do
          Logger.info("Detached #{bd.blkdevice} succes!")
          %{bd | blkdevice: nil}
        else
          Logger.error("Detached #{bd.blkdevice} failed!")

          raise RuntimeError,
                "Error detaching block device: #{fmt_out(process.stderr)} #{fmt_out(process.stdout)}"
        end
    end
  end

  @doc """
  Unmounts all mounted file systems, detaches the block device, unmounts any EWF FUSE mount,
  and releases any Redis lock.
  """
  @spec umount(t()) :: t()
  def umount(%__MODULE__{} = bd) do
    bd = umount_all(bd)

    bd =
      if bd.blkdevice do
        detach_device(bd)
      else
        bd
      end

    bd =
      if bd.ewf_mount_path do
        ewfumount(bd)
      else
        bd
      end

    if bd.redis_lock do
      RedisLock.release(bd.redis_lock)
      Logger.info("Redis lock released: #{bd.redis_lock.name}")
      %{bd | redis_lock: nil}
    else
      bd
    end
  end

  # Internal helpers and dependency injection hooks

  defp ensure_redis_client(%__MODULE__{redis_client: client} = bd) when not is_nil(client),
    do: bd

  defp ensure_redis_client(%__MODULE__{} = bd) do
    case get_override(bd, :redis_from_url_fn) do
      fun when is_function(fun, 1) ->
        %{bd | redis_client: fun.(bd.redis_url)}

      _ ->
        {:ok, conn} = Redix.start_link(bd.redis_url)
        %{bd | redis_client: conn}
    end
  end

  defp image_extension(path) do
    path
    |> Path.extname()
    |> String.trim_leading(".")
    |> String.downcase()
  end

  defp path_exists?(bd, path) do
    exists_fn = get_override(bd, :path_exists_fn) || (&File.exists?/1)
    exists_fn.(path)
  end

  defp which(bd, tool) do
    which_fn = get_override(bd, :which_fn) || (&System.find_executable/1)
    which_fn.(tool)
  end

  defp mkdtemp(bd, prefix, dir) do
    case get_override(bd, :mkdtemp_fn) do
      fun when is_function(fun, 2) ->
        fun.(prefix, dir)

      fun when is_function(fun, 1) ->
        fun.(prefix: prefix, dir: dir)

      _ ->
        File.mkdir_p!(dir)
        rand = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
        tmp_path = Path.join(dir, "#{prefix}#{rand}")
        File.mkdir_p!(tmp_path)
        tmp_path
    end
  end

  defp rmtree(bd, path) do
    case get_override(bd, :rmtree_fn) do
      fun when is_function(fun, 1) ->
        fun.(path)

      _ ->
        File.rm_rf(path)
    end
  end

  defp makedirs(bd, path) do
    case get_override(bd, :makedirs_fn) do
      fun when is_function(fun, 1) ->
        fun.(path)

      _ ->
        File.mkdir_p!(path)
    end
  end

  defp rmdir(bd, path) do
    case get_override(bd, :rmdir_fn) do
      fun when is_function(fun, 1) ->
        fun.(path)

      _ ->
        File.rmdir!(path)
    end
  end

  defp sleep(bd, seconds) do
    case get_override(bd, :sleep_fn) do
      fun when is_function(fun, 1) ->
        fun.(seconds)

      _ ->
        Process.sleep(trunc(seconds * 1000))
    end
  end

  defp run_cmd(bd, command) when is_list(command) do
    case get_override(bd, :cmd_runner) do
      fun when is_function(fun, 1) ->
        normalize_cmd_result(fun.(command))

      _ ->
        default_run_cmd(command)
    end
  end

  defp normalize_cmd_result(%{returncode: rc} = res) do
    %{
      returncode: rc,
      stdout: Map.get(res, :stdout),
      stderr: Map.get(res, :stderr)
    }
  end

  defp normalize_cmd_result({stdout, stderr, rc}) do
    %{returncode: rc, stdout: stdout, stderr: stderr}
  end

  defp normalize_cmd_result({stdout, rc}) do
    %{returncode: rc, stdout: stdout, stderr: ""}
  end

  defp default_run_cmd([executable | args]) do
    try do
      {stdout, status} = System.cmd(executable, args, stderr_to_stdout: false)
      %{returncode: status, stdout: stdout, stderr: ""}
    rescue
      e ->
        %{returncode: 1, stdout: "", stderr: Exception.message(e)}
    end
  end

  defp fmt_out(nil), do: "None"
  defp fmt_out(val), do: to_string(val)

  defp get_override(nil, key) do
    Process.get({:openrelik_mount_override, key})
  end

  defp get_override(%__MODULE__{opts: opts}, key) do
    Keyword.get(opts, key) || Process.get({:openrelik_mount_override, key})
  end

  defp truthy_executable?(nil), do: false
  defp truthy_executable?(false), do: false
  defp truthy_executable?(_), do: true
end

defmodule OpenrelikWorkerCommon.MountUtils do
  @moduledoc """
  Disk image mounting utilities (`openrelik_worker_common.mount_utils`).
  """

  alias OpenrelikWorkerCommon.MountUtils.BlockDevice

  defdelegate new(image_path, opts \\ []), to: BlockDevice
  defdelegate setup(bd), to: BlockDevice
  defdelegate mount(bd, partition_name \\ ""), to: BlockDevice
  defdelegate umount(bd), to: BlockDevice
end
