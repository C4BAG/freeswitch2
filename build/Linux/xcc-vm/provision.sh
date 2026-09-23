#!/bin/bash
#
# Installs the XCC into the VM. Runs in a WSL distribution and works over SSH on the VM.
# Same sequence as build/Linux/xcc-dev/Dockerfile, without Docker.
#
#   $1  address of the VM
#
# Environment:
#   DEBS_DIR      the FreeSWITCH packages of this line   (required)
#   XCC_DEB       freeswitch-xcc-core.deb                (required)
#   SSH_KEY       private key                            (default /root/.ssh/xcc_vm)
#   IPV6_ADDRESS  static IPv6 to configure, without prefix length; empty to skip
#
set -euo pipefail

VM="${1:?usage: provision.sh <ip-of-vm>}"
DEBS_DIR="${DEBS_DIR:?DEBS_DIR is required}"
XCC_DEB="${XCC_DEB:?XCC_DEB is required}"
SSH_KEY="${SSH_KEY:-/root/.ssh/xcc_vm}"
IPV6_ADDRESS="${IPV6_ADDRESS:-}"

SSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR root@$VM"

for f in "$DEBS_DIR" "$XCC_DEB" "$SSH_KEY"; do
    [ -e "$f" ] || { echo "not found: $f" >&2; exit 1; }
done
DEB_COUNT=$(ls "$DEBS_DIR"/*.deb 2>/dev/null | wc -l)
[ "$DEB_COUNT" -gt 0 ] || { echo "no packages in $DEBS_DIR - run build-debs.ps1 first" >&2; exit 1; }

echo "== target =="
$SSH 'head -1 /etc/os-release; uname -r; ip -br addr show scope global'

echo "== transferring $DEB_COUNT packages =="
$SSH 'rm -rf /root/debs /root/xcc && mkdir -p /root/debs /root/xcc'
tar -C "$DEBS_DIR" -cf - . | $SSH 'tar -C /root/debs -xf -'
tar -C "$(dirname "$XCC_DEB")" -cf - "$(basename "$XCC_DEB")" | $SSH 'tar -C /root/xcc -xf -'

echo "== install =="
$SSH "IPV6_ADDRESS='$IPV6_ADDRESS' bash -s" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "-- local repository --"
cd /root/debs
dpkg-scanpackages -m . > Packages 2>/dev/null
gzip -kf Packages
printf 'deb [trusted=yes] file:/root/debs /\n' > /etc/apt/sources.list.d/local.list

echo "-- Microsoft repository, for dotnet-runtime-10.0 --"
if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]; then
    wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/ms.deb
    dpkg -i /tmp/ms.deb
    rm -f /tmp/ms.deb
fi

echo "-- stand-ins for the two sound packages --"
# c4b-freeswitch-meta-all depends on freeswitch-music and freeswitch-sounds, which are
# provided by FreeSWITCH's separately built sound packages. freeswitch-xcc-core ships
# its own 857 sound files, so the upstream ones would only add a second, unused set.
apt-get update -qq
apt-get install -y -qq equivs dpkg-dev
mkdir -p /root/equivs && cd /root/equivs
for p in freeswitch-music freeswitch-sounds; do
    printf 'Section: comm\nPriority: optional\nStandards-Version: 3.9.2\nPackage: %s\nVersion: 1.11.2-c4b-dev\nMaintainer: C4B dev VM <root@localhost>\nArchitecture: all\nDescription: placeholder for %s\n Satisfies the dependency of c4b-freeswitch-meta-all. The sounds actually\n used come from freeswitch-xcc-core.\n' "$p" "$p" > "$p.ctl"
    equivs-build "$p.ctl" >/dev/null
done
dpkg -i /root/equivs/*.deb

echo "-- FreeSWITCH and the C4B layer --"
apt-get update -qq
apt-get install -y --no-install-recommends dotnet-runtime-10.0 c4b-freeswitch-meta-all
apt-get install -y --no-install-recommends /root/xcc/freeswitch-xcc-core.deb

if [ -n "${IPV6_ADDRESS:-}" ]; then
    echo "-- static IPv6 $IPV6_ADDRESS --"
    # This site has no IPv6 router: no Router Advertisements at all and no default
    # route, so addresses are assigned by hand. cloud-init rewrites
    # 50-cloud-init.yaml on every boot, hence a separate file - netplan merges by key.
    cat > /etc/netplan/60-ipv6.yaml <<NETPLAN
network:
  version: 2
  ethernets:
    eth0:
      accept-ra: false
      dhcp6: false
      addresses:
        - ${IPV6_ADDRESS}/64
NETPLAN
    chmod 600 /etc/netplan/60-ipv6.yaml
    chmod 600 /etc/netplan/50-cloud-init.yaml 2>/dev/null || true
    netplan apply 2>&1 | grep -v openvswitch || true
    sleep 6
fi

echo "-- start the service --"
# On a first install dpkg starts the unit while the postinst's useradd has not finished,
# chown fails with 'invalid user freeswitch:freeswitch', and systemd gives up after five
# restarts. The user exists by now, so clearing the failed state is enough.
systemctl reset-failed freeswitch 2>/dev/null || true
systemctl enable freeswitch >/dev/null 2>&1 || true
systemctl restart freeswitch
sleep 8

echo "-- result --"
systemctl is-active freeswitch
/usr/bin/freeswitch -version 2>&1 | head -1
ip -br addr show scope global
REMOTE

echo "== done =="
