#!/bin/bash
#
# State of the XCC in the VM. Read only. Runs in a WSL distribution, over SSH.
#
#   $1  address of the VM
#
# Environment:
#   SSH_KEY   private key   (default /root/.ssh/xcc_vm)
#
set -uo pipefail

VM="${1:?usage: check.sh <ip-of-vm>}"
SSH_KEY="${SSH_KEY:-/root/.ssh/xcc_vm}"

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=6 "root@$VM" 'bash -s' <<'REMOTE'
LOG=/var/log/freeswitch/freeswitch.log

echo "== host =="
printf '  %s\n' "$(head -1 /etc/os-release | cut -d'"' -f2) - $(uname -r)"
ip -br addr show scope global | sed 's/^/  /'
df -h / | tail -1 | sed 's/^/  /'

echo "== service =="
printf '  %s\n' "$(systemctl is-active freeswitch) / $(systemctl is-enabled freeswitch)"
fs_cli -p XPhoneTheBrave -x 'status' 2>&1 | sed -n '1,2p' | sed 's/^/  /'

echo "== plugin =="
printf '  C4B APIs:         %s\n' "$(grep -c 'Loaded Api FsC4B_Modules' "$LOG" 2>/dev/null)"
printf '  C4B applications: %s\n' "$(grep -c 'Loaded App' "$LOG" 2>/dev/null)"
grep -E 'Loaded Core HostFXR:' "$LOG" 2>/dev/null | tail -1 | sed 's/^/  /'

echo "== sofia =="
fs_cli -p XPhoneTheBrave -x 'sofia status' 2>&1 | sed 's/^/  /'

echo "== bound =="
ss -lntu 2>/dev/null | grep -E ':(8021|50[0-9][0-9]|49[0-9][0-9])\b' | sed 's/^/  /'

echo "== errors since start =="
# Expected and not caused by this setup: mod_siren has no Debian package
# (build/modules.conf.in has it commented out) and conference.conf.xml is absent from
# the Windows installation as well.
grep -E '\[ERR\]|\[CRIT\]' "$LOG" 2>/dev/null | tail -8 | sed 's/^/  /'
REMOTE
