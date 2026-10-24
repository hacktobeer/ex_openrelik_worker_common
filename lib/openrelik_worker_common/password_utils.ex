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

defmodule OpenrelikWorkerCommon.PasswordUtils do
  @moduledoc """
  Helper functions for password hash cracking (`openrelik_worker_common.password_utils`).
  """

  require Logger

  @fallback_password_list "/usr/share/john/password.lst"

  @doc """
  Bruteforces password hashes using Hashcat or John the Ripper (`john`).

  ## Parameters
  * `password_hashes` - List of password hashes as strings.
  * `tmp_dir` - Path to use as a temporary directory.
  * `password_list_file_path` - Path to the password list file.
  * `password_rules_file_path` - Path to the password rules file.
  * `timeout` - Number of seconds to run before terminating the process (default `300`).
  * `extra_args` - Any extra arguments to be passed to Hashcat (default `""`).
  * `opts` - Optional keyword overrides for testing (`:which_fn`, `:cmd_runner`, `:pot_file`, `:fallback_password_list`).

  ## Returns
  List of `{password_hash, plaintext}` tuples.

  ## Raises
  `RuntimeError` if execution fails or required tools/wordlists are unavailable.
  """
  @spec bruteforce_password_hashes(
          [String.t()],
          String.t() | nil,
          String.t(),
          String.t(),
          pos_integer() | keyword(),
          String.t(),
          keyword()
        ) :: [{String.t(), String.t()}]
  def bruteforce_password_hashes(
        password_hashes,
        tmp_dir,
        password_list_file_path,
        password_rules_file_path,
        timeout_or_opts \\ 300,
        extra_args \\ "",
        opts \\ []
      )
      when is_list(password_hashes) do
    {timeout, extra_args, opts} =
      if Keyword.keyword?(timeout_or_opts) do
        {
          Keyword.get(timeout_or_opts, :timeout, 300),
          Keyword.get(timeout_or_opts, :extra_args, extra_args),
          timeout_or_opts
        }
      else
        {timeout_or_opts, extra_args, opts}
      end

    Logger.info("Starting password hash bruteforce")

    effective_tmp_dir =
      if is_binary(tmp_dir) and tmp_dir != "" do
        tmp_dir
      else
        System.tmp_dir!()
      end

    File.mkdir_p!(effective_tmp_dir)

    password_hashes_file_path = create_temp_file(effective_tmp_dir, "hashes_")
    File.write!(password_hashes_file_path, Enum.join(password_hashes, "\n"))

    default_pot_file = Path.join(effective_tmp_dir, "hashcat.pot")

    fallback_list =
      Keyword.get(opts, :fallback_password_list) ||
        Process.get(:openrelik_fallback_password_list) ||
        @fallback_password_list

    resolved_password_list =
      if File.regular?(password_list_file_path || "") do
        password_list_file_path
      else
        fallback_list
      end

    if not File.regular?(resolved_password_list) do
      raise RuntimeError, "No password list available"
    end

    password_rules_temp_path = create_temp_file(effective_tmp_dir, "rules_")

    resolved_rules_path =
      if File.regular?(password_rules_file_path || "") do
        password_rules_file_path
      else
        File.write!(password_rules_temp_path, Enum.join([":", "d"], "\n"))
        password_rules_temp_path
      end

    which_fn =
      Keyword.get(opts, :which_fn) ||
        Process.get(:openrelik_which_fn) ||
        (&System.find_executable/1)

    joined_hashes = Enum.join(password_hashes, "")

    {cmd, pot_file} =
      if String.contains?(joined_hashes, "$y$") do
        if not truthy_executable?(which_fn.("john")) do
          raise RuntimeError, "Trying to execute jtr but it's not installed"
        end

        john_pot =
          Keyword.get(opts, :pot_file) ||
            Process.get(:openrelik_john_pot_file) ||
            Path.expand("~/.john/john.pot")

        {
          [
            "john",
            "--format=crypt",
            "--wordlist=#{resolved_password_list}",
            password_hashes_file_path
          ],
          john_pot
        }
      else
        if not truthy_executable?(which_fn.("hashcat")) do
          raise RuntimeError, "Trying to execute hashcat but it's not installed"
        end

        hashcat_pot =
          Keyword.get(opts, :pot_file) ||
            Process.get(:openrelik_hashcat_pot_file) ||
            default_pot_file

        base_cmd = ["hashcat", "--force", "-a", "0"]

        base_cmd =
          if is_binary(extra_args) and extra_args != "" do
            base_cmd ++ String.split(extra_args, " ")
          else
            base_cmd
          end

        full_cmd =
          base_cmd ++
            [
              "--potfile-path=#{hashcat_pot}",
              password_hashes_file_path,
              resolved_password_list,
              "-r",
              resolved_rules_path
            ]

        {full_cmd, hashcat_pot}
      end

    Logger.info("Using command: #{inspect(cmd)}")

    cmd_runner =
      Keyword.get(opts, :cmd_runner) ||
        Process.get(:openrelik_password_cmd_runner) ||
        (&run_with_timeout/2)

    case cmd_runner.(cmd, timeout) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise RuntimeError, "#{Enum.join(cmd, " ")} failed: #{inspect(reason)}"
    end

    parse_and_remove_pot_file(pot_file)
  end

  defp parse_and_remove_pot_file(pot_file) do
    if File.regular?(pot_file) do
      lines =
        pot_file
        |> File.read!()
        |> String.split("\n", trim: true)

      result =
        Enum.reduce(lines, [], fn line, acc ->
          case rsplit_once(line, ":") do
            {password_hash, plaintext} ->
              cleaned_plaintext = String.trim_trailing(plaintext)

              if cleaned_plaintext != "" do
                acc ++ [{password_hash, cleaned_plaintext}]
              else
                acc
              end

            :error ->
              acc
          end
        end)

      File.rm(pot_file)
      result
    else
      []
    end
  end

  defp rsplit_once(string, delimiter) do
    case :binary.matches(string, delimiter) do
      [] ->
        :error

      matches ->
        {idx, len} = List.last(matches)
        <<left::binary-size(^idx), _::binary-size(^len), right::binary>> = string
        {left, right}
    end
  end

  defp run_with_timeout([executable | args], timeout_seconds) do
    exec_path = System.find_executable(executable)

    if is_nil(exec_path) do
      {:error, :enoent}
    else
      timeout_ms = trunc(timeout_seconds * 1000)

      try do
        port =
          Port.open({:spawn_executable, exec_path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        wait_for_port(port, timeout_ms)
      rescue
        e -> {:error, Exception.message(e)}
      end
    end
  end

  defp wait_for_port(port, timeout_ms) do
    timer_ref = Process.send_after(self(), {:port_timeout, port}, timeout_ms)

    loop_port(port, timer_ref)
  end

  defp loop_port(port, timer_ref) do
    receive do
      {^port, {:data, _data}} ->
        loop_port(port, timer_ref)

      {^port, {:exit_status, _status}} ->
        Process.cancel_timer(timer_ref)
        :ok

      {:port_timeout, ^port} ->
        terminate_port(port)
        :ok
    end
  end

  defp terminate_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end
  end

  defp create_temp_file(dir, prefix) do
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    path = Path.join(dir, "#{prefix}#{rand}")
    File.write!(path, "")
    path
  end

  defp truthy_executable?(nil), do: false
  defp truthy_executable?(false), do: false
  defp truthy_executable?(_), do: true
end
