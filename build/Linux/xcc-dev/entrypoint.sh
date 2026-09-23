#!/bin/bash
#
# Starts the XCC in the foreground. Two things are set from the environment because
# they are the only per-instance values the container cannot know:
#
#   XCC_LOCAL_IP    the address the XCC puts into c4bvars.xml as local_ip_v4, which
#                   freeswitch.xml then uses as $${domain}. Defaults to the container's
#                   own address, which is right for host networking and wrong behind a
#                   bridge - there, pass the address the outside world uses.
#   XCC_RTP_START   RTP port range. The shipped configuration uses 30000-33000, which
#   XCC_RTP_END     is 3001 ports; with a bridge network every one of them needs its
#                   own -p, so a development instance wants a much smaller range.
#
set -euo pipefail

CONF=/etc/freeswitch

# Skip lo: with WSL mirrored networking it carries a global /32 (10.255.255.254,
# the host gateway), which would otherwise win as the first match.
detected=$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '$2 != "lo" { split($4, a, "/"); print a[1]; exit }')
XCC_LOCAL_IP="${XCC_LOCAL_IP:-${detected:-127.0.0.1}}"

echo "[xcc-dev] local_ip_v4 = $XCC_LOCAL_IP"
sed -i -E "s|(data=\"set\" data=\"local_ip_v4=)[^\"]*|\1${XCC_LOCAL_IP}|" "$CONF/c4bvars.xml" 2>/dev/null || true
sed -i -E "s|(local_ip_v4=)[^\"]*|\1${XCC_LOCAL_IP}|" "$CONF/c4bvars.xml"
grep -o 'local_ip_v4=[^"]*' "$CONF/c4bvars.xml" | sed 's/^/[xcc-dev]   /'

if [ -n "${XCC_RTP_START:-}" ] && [ -n "${XCC_RTP_END:-}" ]; then
    echo "[xcc-dev] rtp ports = $XCC_RTP_START-$XCC_RTP_END"
    sed -i -E "s|(\"rtp-start-port\" value=\")[0-9]+|\1${XCC_RTP_START}|" "$CONF/autoload_configs/switch.conf.xml"
    sed -i -E "s|(\"rtp-end-port\" value=\")[0-9]+|\1${XCC_RTP_END}|" "$CONF/autoload_configs/switch.conf.xml"
fi
grep -oE '"rtp-(start|end)-port" value="[0-9]+"' "$CONF/autoload_configs/switch.conf.xml" | sed 's/^/[xcc-dev]   /'

echo "[xcc-dev] $(/usr/bin/freeswitch -version 2>&1 | head -1)"
echo "[xcc-dev] dotnet: $(dotnet --list-runtimes 2>/dev/null | grep -c NETCore) NETCore runtime(s)"

# -nf   stay in the foreground, so the container lives as long as FreeSWITCH does
# -nonat  no UPnP/NAT-PMP probing; a container gets its external address told to it
exec /usr/bin/freeswitch -nf -nonat "$@"
