# Thunderbolt dock gigabit NIC won't enumerate on an Apple Mac under Linux — the autosuspend fix

**TL;DR** — On an Apple Mac (Alpine Ridge Thunderbolt 3 controller) running Linux, a USB‑C / Thunderbolt
dock's **gigabit ethernet NIC never shows up** (no `enx…` interface, nothing in `lsusb`), even though the
dock's **USB2 devices (hubs, audio, keyboard/mouse) enumerate fine**. The cause is **PCI runtime
autosuspend on the Thunderbolt USB (xHCI) controller**: while it's suspended it can't host the dock's
USB3 tunnel, so anything on the dock's SuperSpeed side — most visibly the NIC — is invisible. The fix is
to pin the Thunderbolt controllers' runtime power management to **`on`**. **No reboot, and no
`acpi_osi=Darwin`.**

```sh
# immediate (adjust PCI addresses to your machine — see below):
echo on | sudo tee /sys/bus/pci/devices/0000:08:00.0/power/control   # TB USB (xHCI) controller
echo on | sudo tee /sys/bus/pci/devices/0000:07:00.0/power/control   # TB NHI
# the dock's USB3 tree — and the NIC — enumerate within a second or two.
```

Make it permanent with the udev rule in this repo.

---

## Symptom

You plug a USB‑C/Thunderbolt dock into a Mac running Linux and:

- The dock's **USB2 side works**: internal USB hubs, audio, and any keyboard/mouse appear in `lsusb`.
- The dock's **gigabit NIC does not appear** — no new `enx…`/`eth…` interface, and the NIC chip
  (commonly a Realtek `0bda:8153` RTL8153, or an ASIX AX88179) is **absent from `lsusb` entirely**.
- The Thunderbolt USB3 root hub (the 10 Gb/s xHCI bus on the TB controller) is **empty**.
- `dmesg` shows, once at boot:
  ```
  thunderbolt 0000:07:00.0: device links to tunneled native ports are missing!
  ```
- It may be intermittent — the NIC appears "sometimes" (whenever the controller happened to be awake)
  and not others. That intermittency is the tell.

If instead your **whole** Thunderbolt controller is invisible at boot when no device is attached, you have
the *other* classic Apple problem (firmware power-gating that wants `acpi_osi=Darwin`); see References.
This repo is about the case where the controller is present but **runtime-autosuspended**.

## Why it happens

A Thunderbolt dock's downstream USB tree is split across two paths:

- **USB2** (hubs/audio/HID) rides USB‑C's always-on USB2 lanes into the Mac's **PCH** xHCI — a controller
  that never sleeps here, so these always enumerate.
- **USB3 / SuperSpeed** (including the dock's gigabit NIC) is tunneled over Thunderbolt and surfaces on the
  **Thunderbolt xHCI controller** (Intel Alpine Ridge, PCI `8086:15d4`).

Linux enables **PCI runtime power management** on that Thunderbolt xHCI. With nothing on its SuperSpeed
bus it autosuspends to D3. Then it's a chicken‑and‑egg: the controller is asleep because the bus is empty,
and the bus stays empty because the asleep controller can't bring up the dock's USB3 tunnel. USB2 keeps
working (different controller), so the dock "sees connected" while the NIC never appears.

Pinning the controller's `power/control` to `on` resumes it to D0 and keeps it there; the dock's USB3
tree then enumerates immediately, and the NIC comes up.

This is **not** the `acpi_osi=Darwin` firmware power‑gating issue — the controller is visible the whole
time, just runtime‑suspended.

## Diagnose (confirm this is your case)

1. Find your Thunderbolt controllers' PCI addresses:
   ```sh
   lspci -nn | grep -iE 'thunderbolt|alpine ridge|JHL|DSL'
   # NHI         = 8086:15d2  (…:07:00.0 in the example below)
   # TB USB xHCI = 8086:15d4  (…:08:00.0)
   ```
2. With the dock plugged in but the NIC missing, check the TB USB controller's runtime state:
   ```sh
   cat /sys/bus/pci/devices/0000:08:00.0/power/runtime_status   # -> suspended  (the smoking gun)
   cat /sys/bus/pci/devices/0000:08:00.0/power/control          # -> auto
   ```
3. Confirm the dock's USB2 side is present but the NIC/USB3 side isn't:
   ```sh
   lsusb        # dock hubs/audio present; no 0bda:8153 / AX88179 "LAN"
   ```

## Fix — runtime (no reboot)

```sh
echo on | sudo tee /sys/bus/pci/devices/0000:08:00.0/power/control    # TB USB xHCI (8086:15d4)
echo on | sudo tee /sys/bus/pci/devices/0000:07:00.0/power/control    # TB NHI     (8086:15d2)
```
Within a second or two `dmesg` shows the dock's SuperSpeed tree enumerate and the NIC come up
(`r8152 … enx…: carrier on` for Realtek docks). See [`tb-nic-wake.sh`](tb-nic-wake.sh) for a script that
finds the controllers by ID and does this automatically.

## Fix — persistent (survives reboots and re‑plugs)

Install the udev rule, which pins both TB controllers to `power/control=on` by PCI ID at every boot:

```sh
sudo install -m 0644 90-thunderbolt-nosuspend.rules /etc/udev/rules.d/90-thunderbolt-nosuspend.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=pci --attr-match=vendor=0x8086
```

Verify:
```sh
for d in 0000:07:00.0 0000:08:00.0; do
  echo "$d control=$(cat /sys/bus/pci/devices/$d/power/control) rt=$(cat /sys/bus/pci/devices/$d/power/runtime_status)"
done
# expect: control=on rt=active
```

## Revert

```sh
sudo rm /etc/udev/rules.d/90-thunderbolt-nosuspend.rules
sudo udevadm control --reload-rules
# optional: let them autosuspend again now
echo auto | sudo tee /sys/bus/pci/devices/0000:08:00.0/power/control
echo auto | sudo tee /sys/bus/pci/devices/0000:07:00.0/power/control
```

## Trade‑off

Pinning the Thunderbolt controllers to D0 defeats their idle power saving, so they draw a little more
power / run slightly warmer. On an always‑on desktop (e.g. an iMac used as a Linux box) that's a fine
trade for a NIC that reliably appears. On a battery‑powered laptop you may prefer the runtime one‑shot
([`tb-nic-wake.sh`](tb-nic-wake.sh)) over the always‑on udev rule.

## Tested on

- Apple iMac, Intel **Alpine Ridge** Thunderbolt 3 controller (NHI `8086:15d2`, USB xHCI `8086:15d4`).
- Ubuntu 24.04 base (Linux Mint 22.x), kernel 6.x–7.x.
- Reproduced with two different Thunderbolt/USB‑C docks whose NICs are Realtek RTL8153 (`0bda:8153`);
  the same mechanism applies to ASIX‑based dock NICs.

Adjust the PCI addresses (`07:00.0` / `08:00.0` here) to your own topology — the udev rule matches by
**PCI vendor/device ID**, so it is portable across machines with the same controller.

## References

- Matthew Garrett, *Apple, Thunderbolt and firmware* — the Apple ACPI power/GPE mechanism:
  https://mjg59.dreamwidth.org/15948.html
- Linux kernel: *thunderbolt: Power down controller when idle* (Apple ACPI power methods + GPE wake):
  https://lkml.iu.edu/hypermail/linux/kernel/1701.1/00018.html
- Arch Wiki — Thunderbolt: https://wiki.archlinux.org/title/Thunderbolt
- Kernel docs — Thunderbolt: https://www.kernel.org/doc/html/latest/admin-guide/thunderbolt.html

## License

MIT — see [LICENSE](LICENSE).
