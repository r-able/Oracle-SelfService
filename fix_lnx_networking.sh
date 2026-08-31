#!/usr/bin/env bash
# fix_lnx_networking.sh
# Released under the MIT license. Copyright (c) 2026, Vlad von Grigorian <>
#
# Run LOCALLY, AS ROOT, on the affected VM (lnx002, or any other host that
# hits the same symptom) when Ansible reports "No route to host" / SSH
# refuses to connect after a snapshot restore or reboot.
#
# CONFIRMED ROOT CAUSE (diagnosed live on lnx002, Aug 30 2026):
#   /var/lib/NetworkManager/NetworkManager.state had NetworkingEnabled=false.
#   This is a GLOBAL switch, independent of any per-device config - while
#   it's false, NetworkManager marks EVERY device "unmanaged" (ifconfig -a
#   shows interfaces present but down, no carrier reported, no IP), even
#   though the individual ifcfg-* connection profiles are completely
#   correct and untouched. `nmcli device set <dev> managed yes` does NOT
#   fix this - the global flag overrides any per-device attempt. Only
#   `nmcli networking on` (which rewrites the state file) fixes it, and it
#   fixes ALL devices on the host in one shot, not just one.
#
#   Ruled out during that diagnosis (kept here as a record, NOT re-tested
#   by this script): NM_CONTROLLED=no in ifcfg files, NetworkManager.conf
#   conf.d overrides, udev unmanaged-device rules (85-nm-unmanaged.rules
#   only matches vmnet*/vnic*/vboxnet* MACs, not real VMware vNICs).
#
# WHAT THIS SCRIPT DOES:
#   1. Reports current networking state (safe, read-only)
#   2. If networking is globally disabled, re-enables it (the confirmed fix)
#   3. Brings up any of this host's known ethernet connections that are
#      still down after that (belt-and-suspenders - re-enabling networking
#      alone was sufficient on lnx002, but a specific connection profile
#      could theoretically still need an explicit nudge)
#   4. Verifies the expected IP actually came back on the expected
#      interface, and exits non-zero with a clear diagnostic pointer if it
#      didn't - so this script never reports success when the fix didn't
#      actually work
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO:
#   - It does not touch ifcfg files, NetworkManager.conf, or udev rules -
#     none of those were the actual cause here, and editing them blind on
#     a future recurrence that turns out to have a DIFFERENT cause would
#     make things worse, not better.
#   - It does not fix hypervisor-side problems (a missing/renamed vSwitch
#     portgroup, "Connected" unticked in VM settings). If `ethtool` shows
#     no carrier on the expected interface even after this script runs,
#     that is a vCenter/ESXi-side check, not something fixable from inside
#     the guest - see the FAILED output below for the exact next step.
#
# CONFIG - edit these two lines if reusing this script on a different host
# (e.g. copy to lnx001 and adjust):
EXPECTED_IFACE="ens160"
EXPECTED_IP="192.168.1.246"

# ---------------------------------------------------------------------------

set -uo pipefail   # NOT -e: this script deliberately continues past checks
                    # that are expected to sometimes fail (that's the point
                    # of a diagnostic/repair script), and reports its own
                    # pass/fail at the end via explicit exit codes.

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: this script must be run as root (it needs to change NetworkManager's global state)." >&2
    exit 1
fi

log "========================================================"
log "lnx networking fix - starting on $(hostname)"
log "Target interface: ${EXPECTED_IFACE}  Expected IP: ${EXPECTED_IP}"
log "========================================================"

# -- 1. Report current state (read-only) -------------------------------------

log "Current nmcli networking state:"
BEFORE_STATE="$(nmcli networking)"
echo "  ${BEFORE_STATE}"

log "Current device status:"
nmcli device status | sed 's/^/  /'

STATE_FILE="/var/lib/NetworkManager/NetworkManager.state"
if [[ -f "${STATE_FILE}" ]]; then
    log "Persisted state file (${STATE_FILE}):"
    sed 's/^/  /' "${STATE_FILE}"
else
    log "NOTE: ${STATE_FILE} does not exist - NetworkManager may not have written a state file yet on this host."
fi

# -- 2. Fix: re-enable networking globally if it's disabled -------------------

if [[ "${BEFORE_STATE}" == "disabled" ]]; then
    log "Networking is globally DISABLED (the confirmed recurring cause) - enabling it now."
    nmcli networking on
    sleep 3
else
    log "Networking is already globally enabled - this run's problem (if any) is something else. Continuing to check individual connections, but see the NOTE at the end if the expected IP still doesn't show up."
fi

# -- 3. Bring up any of this host's known ethernet connections that are
#       still down (belt-and-suspenders after step 2)  -----------------------

log "Bringing up any managed-but-inactive ethernet connections..."
while IFS=: read -r name uuid ctype device; do
    [[ "${ctype}" != "ethernet" ]] && continue
    if [[ -z "${device}" || "${device}" == "--" ]]; then
        log "  Activating '${name}' (currently inactive)..."
        nmcli connection up "${name}" >/dev/null 2>&1 \
            && log "    OK" \
            || log "    Could not activate '${name}' - it may not be the right profile for a currently-plugged NIC on this host. Not fatal if ${EXPECTED_IFACE} comes up separately below."
    fi
done < <(nmcli -t -f NAME,UUID,TYPE,DEVICE connection show)

sleep 2

# -- 4. Verify the actual outcome, not just that commands ran without error --

log "Post-fix device status:"
nmcli device status | sed 's/^/  /'

ACTUAL_IP="$(ip -4 -o addr show dev "${EXPECTED_IFACE}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
LINK_STATE="$(cat "/sys/class/net/${EXPECTED_IFACE}/operstate" 2>/dev/null || echo "unknown")"

log "========================================================"
if [[ "${ACTUAL_IP}" == "${EXPECTED_IP}" && "${LINK_STATE}" == "up" ]]; then
    log "SUCCESS: ${EXPECTED_IFACE} is up with the expected address ${EXPECTED_IP}."
    log "Confirm the persisted state stuck (should read NetworkingEnabled=true):"
    sed 's/^/  /' "${STATE_FILE}" 2>/dev/null
    log "========================================================"
    exit 0
else
    log "FAILED: ${EXPECTED_IFACE} link state is '${LINK_STATE}', address is '${ACTUAL_IP:-none}' (expected ${EXPECTED_IP})."
    log ""
    log "The confirmed global-networking-disabled cause has already been"
    log "addressed above, so if it's still not up, this is most likely the"
    log "OTHER known cause from the last incident: a hypervisor-side carrier"
    log "problem, invisible from inside this guest. Check in vCenter/ESXi:"
    log "  1. Edit Settings on this VM"
    log "  2. Find the NIC with MAC $(cat /sys/class/net/${EXPECTED_IFACE}/address 2>/dev/null || echo '(unknown)')"
    log "  3. Confirm 'Connected' and 'Connect at power on' are both ticked"
    log "  4. Confirm its portgroup still exists on the current vSwitch"
    log "     config - a snapshot restore can leave it pointed at a"
    log "     portgroup that was since renamed or removed"
    log "Re-run this script after fixing that in vCenter/ESXi."
    log "========================================================"
    exit 1
fi
