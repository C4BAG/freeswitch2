# The XCC under Linux in a container

A development instance of the XCC runtime on Debian, in a container. For the variant
with its own LAN address see `../xcc-vm/`, which solves a limitation this one has.

## Files

    xcc-dev.ps1      the entry point. Builds the image and runs the container.
    Dockerfile       how the image is assembled - also the reference for a native
                     install, which is what ../xcc-vm/provision.sh follows.
    entrypoint.sh    what happens on every container start, before FreeSWITCH.
    hyperv-fw.ps1    opens both firewalls, needed for host mode only. Administrator.

## What goes into the image

Three sources, none of them built here:

- the FreeSWITCH packages of this line, from `../build-debs.ps1` into `../_debs`
- `freeswitch-xcc-core.deb`, the C4B layer: plugin, configuration, sounds, Lua
- `dotnet-runtime-10.0`, pulled from Microsoft's repository inside the image

The XCC needs nothing else at runtime. Configuration, dialplan, directory and the sofia
profiles all arrive from the XPhone server through the plugin in `mod_managedcore`, over
the event socket - the server connects in, so one TCP port carries the whole
configuration path.

Two stand-in packages are built with `equivs` for `freeswitch-music` and
`freeswitch-sounds`. `c4b-freeswitch-meta-all` depends on them, but
`freeswitch-xcc-core` ships its own 857 sound files, so the upstream ones would only add
a second, unused set.

## Usage

    # build the image and start the container (Docker Desktop, bridge)
    build\Linux\xcc-dev\xcc-dev.ps1 -Build

    # against a native dockerd in a WSL distro, host networking
    build\Linux\xcc-dev\xcc-dev.ps1 -Context wsl-native -HostNetwork -Build

    # restart FreeSWITCH without touching configuration or databases
    docker restart xcc-dev
    docker --context wsl-native restart xcc-dev      # if built with -Context

    # rebuild the container from a new image; volumes are kept
    build\Linux\xcc-dev\xcc-dev.ps1 -Recreate

    # start over from the packaged state, dropping configuration and databases
    build\Linux\xcc-dev\xcc-dev.ps1 -Reset

`/etc/freeswitch` and `/var/lib/freeswitch` are named volumes (`xcc-etc`, `xcc-var`), so
removing and recreating the container keeps what the server wrote and keeps `c4b.db`,
`callcenter.db` and `core.db`. Only `-Reset` deletes them.

Note that the sofia profile files under `/etc/freeswitch/sip_profiles` are not
persistent state at all - the plugin removes them on shutdown and the server writes
them again on the next start.

## The two network modes, and what each costs

**Bridge mode** (default, Docker Desktop). The container sits on its own dual-stack
bridge with a fixed address, and ports are published on the host. A client on the same
Windows machine can reach it, because Docker Desktop's proxy opens the port in the
Windows stack.

The price is the bind/advertise split - the container does not own the host address, so
the XPhone server has to be told two different ones:

    sip-ip     = 172.28.0.10        ext-sip-ip = <host address>
    rtp-ip     = 172.28.0.10        ext-rtp-ip = <host address>

With offset ports also `ext-sip-port` per profile, which does not scale past a handful
of profiles; with 1:1 ports it is unnecessary. And the RTP range has to shrink, because
publishing costs one socket pair per port:

| ports | `docker run` | `docker rm -f` |
|---|---|---|
| 172 | 12 s | seconds |
| 396 | 23 s | 48 s |
| 3001 | over 6 min, never finished | over 13 min, backend at 819 MB |

So a SIP range of a few hundred ports is fine, the packaged RTP range 30000-33000 is
not. A further limitation: SIP arrives from the bridge gateway, so every peer looks like
`172.28.0.1` and per-peer `apply-inbound-acl` is meaningless.

**Host mode** (`-HostNetwork`, native dockerd in a WSL distro with
`networkingMode=mirrored`). The distro's namespace carries the Windows interfaces, so
the container binds the host's own addresses and nothing is translated - the same
configuration a bare-metal Windows XCC gets. Verified from a second machine on the LAN
by capture on the distro's eth2.

Its limitation is structural: **a client on that same Windows machine cannot reach it.**
Windows and WSL share the address, so such a connection never leaves the Windows stack.
Loopback is bridged, which rescues the event socket via `127.0.0.1`, but sofia binds a
specific address rather than the wildcard and has no loopback alternative - and
`sip-ip = 0.0.0.0` does not help, sofia replaces it with the guessed address.

Host mode also needs both firewalls opened for the ports (the existing FreeSWITCH rules
match by program, `FreeSwitchConsole.exe`, which never matches a process in WSL), and a
`wsl.exe` session has to keep the distro alive or dockerd goes down with it.

If the XPhone server runs on the container host, use bridge mode or `../xcc-vm/`.

## Known, and not caused by this setup

`mod_siren` fails to load: `modules.conf.xml` requests it and `mod_siren.dll` exists in
the Windows build, but `build/modules.conf.in:61` has `#codecs/mod_siren` commented out,
so the Debian packaging produces no such package.

`Open of conference.conf failed` and the missing `callcenter` include directories are
absent from the Windows installation too. The callcenter directories appear once the
server has pushed its queues.
