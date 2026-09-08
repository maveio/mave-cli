defmodule MaveCli.DeviceNameTest do
  use ExUnit.Case, async: true

  alias MaveCli.DeviceName

  test "prefers the configured macOS computer name and normalizes display characters" do
    assert DeviceName.get(
             os: {:unix, :darwin},
             computer_name: fn -> "  Zoë’s Mac\u0000\u202E\n" end,
             hostname: fn -> flunk("hostname should not replace a usable computer name") end
           ) == "Zoë’s Mac"
  end

  test "uses the hostname on other systems without consulting macOS settings" do
    parent = self()

    for os <- [{:unix, :linux}, {:win32, :nt}] do
      assert DeviceName.get(
               os: os,
               computer_name: fn -> send(parent, :macos_lookup) end,
               hostname: fn -> "workstation-01" end
             ) == "workstation-01"
    end

    refute_received :macos_lookup
  end

  test "falls back to the hostname when the computer name cannot be read" do
    assert DeviceName.get(
             os: {:unix, :darwin},
             computer_name: fn -> raise ErlangError, original: :enoent end,
             hostname: fn -> "macbook.local" end
           ) == "macbook.local"
  end

  test "omits unavailable, invalid, generic and overlong names without inventing a label" do
    for name <- [
          nil,
          :unknown,
          "",
          "\n\u200B\t",
          <<255>>,
          "localhost",
          "localhost.localdomain",
          "(none)",
          String.duplicate("é", 161)
        ] do
      assert DeviceName.get(
               os: {:unix, :darwin},
               computer_name: fn -> name end,
               hostname: fn -> name end
             ) == nil
    end

    assert DeviceName.get(os: {:unix, :linux}, hostname: fn -> raise "unavailable" end) == nil
  end

  test "checks the length after normalization using Unicode characters" do
    name = String.duplicate("é", 160)

    assert DeviceName.get(os: {:unix, :linux}, hostname: fn -> "\n" <> name <> "\u200B" end) ==
             name
  end
end
