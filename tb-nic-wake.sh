#!/bin/bash
# tb-nic-wake.sh — wake runtime-suspended Thunderbolt controllers so a dock's USB3 NIC enumerates.
# One-shot runtime fix (no reboot, no persistent change). Run as root.
#
# Finds Apple/Alpine Ridge Thunderbolt controllers by PCI ID and pins power/control=on, which resumes
# them to D0 so the dock's USB3 tunnel (and its gigabit NIC) can come up. See README.md for the why.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root (sudo $0)"; exit 1; }

# Thunderbolt controller PCI IDs to wake. Alpine Ridge: 15d2 = NHI, 15d4 = USB xHCI.
# Add your own (lspci -nn | grep -iE 'thunderbolt|JHL|DSL|USB4') if different.
IDS="8086:15d4 8086:15d2"

found=0
for id in $IDS; do
  ven="0x${id%%:*}"; dev="0x${id##*:}"
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "$ven" ] && [ "$(cat "$d/device" 2>/dev/null)" = "$dev" ] || continue
    found=1; bdf=$(basename "$d")
    before=$(cat "$d/power/runtime_status" 2>/dev/null)
    echo on > "$d/power/control" 2>/dev/null || true
    sleep 1
    echo "$bdf ($id): runtime_status $before -> $(cat "$d/power/runtime_status" 2>/dev/null), control=$(cat "$d/power/control" 2>/dev/null)"
  done
done
[ "$found" = 1 ] || { echo "No matching Thunderbolt controllers found. Check: lspci -nn | grep -i thunderbolt"; exit 1; }

sleep 2
echo "--- USB NICs now present ---"
for n in /sys/class/net/*/device; do
  nic=$(basename "$(dirname "$n")")
  drv=$(basename "$(readlink -f "$n/driver" 2>/dev/null)" 2>/dev/null)
  case "$drv" in r8152|r8153_ecm|cdc_ether|cdc_ncm|ax88179_178a|asix) echo "  $nic (driver=$drv)";; esac
done
echo "Done. If the dock NIC still isn't listed, unplug/replug the dock now that the controller is awake."
