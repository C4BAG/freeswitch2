# The XCC under Linux in a Hyper-V VM

A development instance of the XCC runtime on Debian, in a VM with its **own LAN
address**. That address is the whole point.

## Why a VM and not a container

Two container models were built and measured first (`build/Linux/xcc-dev/`), and both
fail the one requirement that matters here: the XPhone server runs on the same Windows
machine as the container host.

| | bridge + published ports | WSL host network | Hyper-V VM |
|---|---|---|---|
| local XPhone server reaches SIP | yes | **no** | yes |
| LAN peers reach SIP | yes | yes | yes |
| real SIP source address | no, all `172.28.0.1` | yes | yes |
| RTP range 30000-33000 | must be cut to a few hundred ports | unchanged | unchanged |
| server configuration | bind/advertise split, `ext-sip-port` | identical to Windows | identical to Windows |

The WSL model fails structurally: with `networkingMode=mirrored` the distro carries the
host's addresses, so a connection from Windows to that address never leaves the Windows
stack and cannot reach a listener living in the WSL stack. Loopback is bridged, which
rescues the event socket, but sofia binds a specific address rather than the wildcard,
so SIP has no loopback alternative. No configuration fixes this - `sip-ip = 0.0.0.0` is
replaced by sofia with the guessed address (measured).

A VM on the external switch has none of that: a separate address, separate stack,
nothing shared, nothing translated.

## What the VM needs from the host

The external switch **already exists** on this machine - Windows itself runs through
`vEthernet (Extern)`. Attaching a VM to it interrupts nothing. No new switch has to be
created, so the NIC is never rebound.

The firewall rules from the WSL experiment (`XCC-WSL-*` on the host firewall, `XCC-*`
on the Hyper-V firewall) are **not** needed for this model - VM traffic goes out the
physical adapter and never passes the host's stack. They can be removed.

## Prerequisites

- Hyper-V enabled, the external switch (default name `Extern`)
- a WSL distribution with `qemu-img` and `genisoimage` - the scripts use it as the
  build machine, because Windows ships no image converter. Any distro will do; it is
  not the VM and its own release does not matter.
- the FreeSWITCH packages of this line in `build/Linux/_debs`, from
  `build/Linux/build-debs.ps1`
- `freeswitch-xcc-core.deb` built for .NET 10

## Usage

    # once: build the disk image and the cloud-init seed (runs in WSL, no admin)
    build\Linux\xcc-vm\xcc-vm.ps1 -BuildImage

    # create and start the VM (ADMIN - Hyper-V cmdlets need it)
    build\Linux\xcc-vm\xcc-vm.ps1 -CreateVm

    # install the XCC into the running VM (no admin)
    build\Linux\xcc-vm\xcc-vm.ps1 -Provision

    # what is it doing
    build\Linux\xcc-vm\xcc-vm.ps1 -Status

    # rebuild the image and swap it under the existing VM (ADMIN)
    build\Linux\xcc-vm\xcc-vm.ps1 -BuildImage
    build\Linux\xcc-vm\xcc-vm.ps1 -CreateVm -Replace

`-Remove` deletes the VM and keeps the disk, so recreating it returns to the installed
state. `-Purge` deletes the disk too.

## Configuration the XPhone server needs

Structurally the same as for a Windows host, only with the VM's address:

    sip-ip = ext-sip-ip = <VM address>
    rtp-ip = ext-rtp-ip = <VM address>
    rtp range 30000-33000, unchanged

No `ext-sip-port`, no published ports, no address translation. The event socket target
is the VM's address as well - reachable from the Windows host and from the LAN alike.

## Three things that cost a rebuild, so they are worth knowing

**Debian's image variant.** `genericcloud` does not boot under Hyper-V. It carries
virtio only, not `hv_storvsc`, so the kernel finds no SCSI disk and panics one second
after GRUB. In the Windows event log that reads:

    Ein Betriebssystem wurde erfolgreich gestartet
    Kritisch: schwerwiegender Fehler, vom Gastbetriebssystem gemeldet

`prepare-image.sh` therefore uses **`generic`**. The VHDX written by `qemu-img` is fine;
that was a wrong suspicion at the time.

**The freeswitch service fails on the very first install.** `chown: invalid user
'freeswitch:freeswitch'` - dpkg starts the unit while the postinst's `useradd` has not
finished yet, and systemd gives up after five restarts. `provision.sh` runs
`systemctl reset-failed` before starting, which is all it takes.

**IPv6 is manual on this site.** There is no IPv6 router: zero Router Advertisements in
25 seconds of tcpdump, and no default route even on the Windows host. Addresses in
`2003:c9:882f:223::/64` are assigned by hand with the suffix
`172:23:83:<last octet of the IPv4>`. Pass `-Ipv6Address` to have `provision.sh` write a
netplan drop-in; without it the VM has link-local IPv6 only. IPv6 reach is inside the
/64 either way.

The event socket stays IPv4-only regardless: the XCC's `event_socket.conf.xml` sets
`listen-ip 0.0.0.0`, exactly as on Windows.

## Known, and not caused by this setup

`mod_siren` fails to load. `modules.conf.xml` requests it and `mod_siren.dll` exists in
the Windows build, but `build/modules.conf.in:61` has `#codecs/mod_siren` commented out,
so the Debian packaging produces no such package.

`Open of conference.conf failed` - `conference.conf.xml` is absent from the Windows
installation too.

An OS4K trunk with `register=false` identifies its peer purely by source address. A VM
with its own address is therefore rejected with `403` on INVITE while OPTIONS still get
`200 OK` - which makes the trunk read as `UP`. That is a permission entry in the PBX,
not a defect here.
