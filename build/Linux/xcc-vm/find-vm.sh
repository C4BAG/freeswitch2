#!/bin/bash
#
# Finds the VM on the LAN when Hyper-V has not reported its address - either because
# hyperv-daemons is not up yet, or because the calling shell is not elevated and the
# Hyper-V cmdlets then return nothing.
#
#   $1  subnet, first three octets, for example 172.30.83
#   $2  expected hostname, for example xcc-linux
#
# Prints "FOUND <ip>" on success.
#
# A Hyper-V MAC prefix alone proves nothing: other hosts on this LAN run Hyper-V too and
# draw from the same 00:15:5d range - that already led to one wrong identification. So
# the MAC only narrows the candidates, and the hostname over SSH decides.
#
set -uo pipefail

SUBNET="${1:?usage: find-vm.sh <subnet> <hostname>}"
WANT="${2:?usage: find-vm.sh <subnet> <hostname>}"
SSH_KEY="${SSH_KEY:-/root/.ssh/xcc_vm}"

for i in $(seq 1 254); do
    ping -c1 -W1 "$SUBNET.$i" >/dev/null 2>&1 &
done
wait

cands=$(ip neigh | grep -i '00:15:5d' | awk '{print $1}' | sort -u)
if [ -z "$cands" ]; then
    echo "no neighbour with a Hyper-V MAC in $SUBNET.0/24" >&2
    exit 1
fi

for ip in $cands; do
    name=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
               -o LogLevel=ERROR -o ConnectTimeout=4 -o BatchMode=yes \
               "root@$ip" hostname 2>/dev/null)
    if [ "$name" = "$WANT" ]; then
        echo "FOUND $ip"
        exit 0
    fi
done

echo "candidates were: $(echo $cands | tr '\n' ' ') - none of them answered as '$WANT'" >&2
exit 1
