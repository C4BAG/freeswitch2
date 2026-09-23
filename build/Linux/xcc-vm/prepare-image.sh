#!/bin/bash
#
# Builds the VM disk and the cloud-init seed. Runs in a WSL distribution, which serves
# only as the build machine - Windows ships no image converter. Its own release does not
# matter; the VM is Debian 12 regardless.
#
# Environment:
#   OUT_DIR         where to write, a /mnt/<drive> path      (required)
#   SSH_KEY         private key to create or reuse           (default /root/.ssh/xcc_vm)
#   DISK_NAME       base name of the VHDX                    (default xcc-linux)
#   VM_HOSTNAME     hostname the VM gives itself             (default xcc-linux)
#   NEW_SUFFIX      write <name>-new.vhdx instead of <name>.vhdx, for swapping the
#                   image under a VM that is still running and holding the file
#
set -euo pipefail

OUT_DIR="${OUT_DIR:?OUT_DIR is required, for example /mnt/d/HyperV/xcc-linux}"
SSH_KEY="${SSH_KEY:-/root/.ssh/xcc_vm}"
DISK_NAME="${DISK_NAME:-xcc-linux}"
VM_HOSTNAME="${VM_HOSTNAME:-xcc-linux}"
NEW_SUFFIX="${NEW_SUFFIX:-0}"

WORK=/root/xcc-vm-work
BASE=https://cloud.debian.org/images/cloud/bookworm/latest

# 'generic', not 'genericcloud'. The latter carries virtio only; under Hyper-V the
# kernel then finds no SCSI disk and panics one second after GRUB.
IMG=debian-12-generic-amd64.qcow2

export DEBIAN_FRONTEND=noninteractive

echo "== tools =="
apt-get update -qq
apt-get install -y -qq qemu-utils genisoimage wget ca-certificates openssh-client
qemu-img --version | head -1

mkdir -p "$WORK" "$OUT_DIR"
cd "$WORK"

echo "== image =="
if [ ! -f "$IMG" ]; then
    wget -q -O "$IMG.part" "$BASE/$IMG"
    mv "$IMG.part" "$IMG"
fi
qemu-img info "$IMG" | sed -n '1,4p' | sed 's/^/  /'

echo "== ssh key =="
if [ ! -f "$SSH_KEY" ]; then
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -q -t ed25519 -N "" -C "xcc-vm" -f "$SSH_KEY"
    echo "  created $SSH_KEY"
else
    echo "  reusing $SSH_KEY"
fi
PUB=$(cat "${SSH_KEY}.pub")

echo "== cloud-init seed =="
# hyperv-daemons so the VM reports its address to Hyper-V; the rest is what the package
# installation in provision.sh needs.
rm -rf "$WORK/seed"
mkdir -p "$WORK/seed"
cat > "$WORK/seed/meta-data" <<META
instance-id: ${VM_HOSTNAME}-001
local-hostname: ${VM_HOSTNAME}
META
cat > "$WORK/seed/user-data" <<USER
#cloud-config
hostname: ${VM_HOSTNAME}
manage_etc_hosts: true
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
users:
  - name: xcc
    groups: [sudo]
    shell: /bin/bash
    sudo: ['ALL=(ALL) NOPASSWD:ALL']
    lock_passwd: false
    ssh_authorized_keys:
      - $PUB
  - name: root
    ssh_authorized_keys:
      - $PUB
ssh_pwauth: false
disable_root: false
package_update: true
packages:
  - openssh-server
  - ca-certificates
  - iproute2
  - wget
  - gnupg
  - dpkg-dev
  - equivs
  - procps
  - hyperv-daemons
runcmd:
  - [ systemctl, enable, --now, ssh ]
USER

# The seed is attached to the VM as a DVD, so it is locked while the VM exists. Skip it
# rather than fail - its content only changes when the key or the hostname changes.
if genisoimage -quiet -output "$OUT_DIR/seed.iso" -volid cidata -joliet -rock \
        "$WORK/seed/user-data" "$WORK/seed/meta-data" 2>/dev/null; then
    echo "  wrote $OUT_DIR/seed.iso"
else
    echo "  $OUT_DIR/seed.iso is locked (attached to a running VM) - kept as it is"
fi

echo "== convert to VHDX =="
if [ "$NEW_SUFFIX" = "1" ]; then
    TARGET="$OUT_DIR/$DISK_NAME-new.vhdx"
else
    TARGET="$OUT_DIR/$DISK_NAME.vhdx"
fi
rm -f "$TARGET"
qemu-img convert -f qcow2 -O vhdx -o subformat=dynamic "$IMG" "$TARGET"
qemu-img info "$TARGET" | sed -n '1,4p' | sed 's/^/  /'

echo "== done =="
ls -la "$OUT_DIR" | sed 's/^/  /'
