defmodule OpenrelikWorkerCommon.PasswordUtilsTest do
  use ExUnit.Case, async: true

  alias OpenrelikWorkerCommon.PasswordUtils

  @tag :tmp_dir
  test "bruteforce_password_hashes with hashcat (mocked)", %{tmp_dir: tmp_dir} do
    hash =
      "$6$NS6w5Q6yjrlZiw7s$5jeyNS.bsw2p4nlbbMRI5H8oZnSbbwKs0Lsw94xCouqn/y/yQpKNA4vdPSr/wdA0isyUmq3BD..ZcirwOVNPF/"

    plaintext = "test"

    wordlist = Path.join(tmp_dir, "wordlist.txt")
    File.write!(wordlist, "test\n")

    pot_file = Path.join(tmp_dir, "hashcat.pot")

    ret =
      PasswordUtils.bruteforce_password_hashes([hash], tmp_dir, wordlist, "",
        extra_args: "-m 1800",
        which_fn: fn
          "hashcat" -> "/usr/bin/hashcat"
          _ -> nil
        end,
        cmd_runner: fn cmd, _timeout ->
          assert Enum.at(cmd, 0) == "hashcat"
          assert "--force" in cmd
          assert "-m" in cmd
          assert "1800" in cmd
          File.write!(pot_file, "#{hash}:#{plaintext}\n")
          :ok
        end
      )

    assert ret == [{hash, plaintext}]
    refute File.exists?(pot_file)
  end

  @tag :tmp_dir
  test "bruteforce_password_hashes with john for yescrypt ($y$) hashes (mocked)", %{
    tmp_dir: tmp_dir
  } do
    hash = "$y$j9T$Ju9QNI0mUsapuQPOXH4Ie0$o7RT.ZY25GXZkBd2EguKLGXNeSVmIN6KWrZkWl5PoL9"
    plaintext = "password"

    wordlist = Path.join(tmp_dir, "wordlist.txt")
    File.write!(wordlist, "password\n")

    pot_file = Path.join(tmp_dir, "john.pot")

    ret =
      PasswordUtils.bruteforce_password_hashes([hash], tmp_dir, wordlist, "",
        pot_file: pot_file,
        which_fn: fn
          "john" -> "/usr/sbin/john"
          _ -> nil
        end,
        cmd_runner: fn cmd, _timeout ->
          assert Enum.at(cmd, 0) == "john"
          assert "--format=crypt" in cmd
          assert "--wordlist=#{wordlist}" in cmd
          File.write!(pot_file, "#{hash}:#{plaintext}\n")
          :ok
        end
      )

    assert ret == [{hash, plaintext}]
    refute File.exists?(pot_file)
  end

  @tag :tmp_dir
  test "raises RuntimeError when no password list is available", %{tmp_dir: tmp_dir} do
    assert_raise RuntimeError, "No password list available", fn ->
      PasswordUtils.bruteforce_password_hashes(
        ["$6$hash"],
        tmp_dir,
        "/nonexistent/wordlist.lst",
        "",
        fallback_password_list: "/nonexistent/fallback.lst"
      )
    end
  end

  @tag :tmp_dir
  test "raises RuntimeError when hashcat or john is not installed", %{tmp_dir: tmp_dir} do
    wordlist = Path.join(tmp_dir, "wordlist.txt")
    File.write!(wordlist, "password\n")

    assert_raise RuntimeError, "Trying to execute hashcat but it's not installed", fn ->
      PasswordUtils.bruteforce_password_hashes(["$6$hash"], tmp_dir, wordlist, "",
        which_fn: fn _ -> nil end
      )
    end

    assert_raise RuntimeError, "Trying to execute jtr but it's not installed", fn ->
      PasswordUtils.bruteforce_password_hashes(["$y$hash"], tmp_dir, wordlist, "",
        which_fn: fn _ -> nil end
      )
    end
  end
end
