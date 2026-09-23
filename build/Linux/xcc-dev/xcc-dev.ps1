<#
.SYNOPSIS
    Builds and runs the XCC runtime under Linux in a container, for development.

.DESCRIPTION
    Assembles a build context from three sources and hands it to docker:

      - the FreeSWITCH packages of this line, produced by build\Linux\build-debs.ps1
      - freeswitch-xcc-core.deb, the C4B layer: plugin, configuration, sounds, Lua
      - dotnet-runtime-10.0, pulled from Microsoft's repository inside the image

    The XCC needs nothing else at runtime. Configuration, dialplan, directory and the
    sofia profiles all arrive from the XPhone server through the plugin in
    mod_managedcore, over the event socket.

.NOTES
    Two network modes, because two container runtimes are available on a Windows
    development machine and they differ fundamentally in what a container can bind.

    -- Bridge mode (default, Docker Desktop) ------------------------------------

    The container sits on its own bridge with a fixed address in both families, by
    default 172.28.0.10 and fd00:c4b:1::10. Fixed, because the XPhone server writes
    literal addresses into the sofia profile, so the bind address must not move.

    That address is what sofia BINDS to. It is not what SIP peers can reach, because
    two NAT layers sit in between - the docker bridge and Docker Desktop's own. What
    peers reach is the Windows host and the ports published here.

    So the XPhone server has to bind and advertise different addresses:

        sip-ip     = 172.28.0.10        rtp-ip     = 172.28.0.10
        ext-sip-ip = <host address>     ext-rtp-ip = <host address>

    Setting all four to the host address - which is what a bare-metal XCC gets - makes
    sofia fail to bind, because that address does not exist inside the container.

    Ports are published so that RTP needs no translation. Publishing a large range is
    not viable: Docker Desktop's userspace proxy opens one socket pair per port, and
    3001 ports (the packaged RTP range) took over six minutes to start and left the
    daemon unusable. A development range of a few hundred ports is fine.

    -- Host mode (-HostNetwork, native dockerd in a WSL distro) ------------------

    With a dockerd running inside a WSL distro and WSL in mirrored networking mode,
    the distro's namespace carries the Windows interfaces themselves. A container with
    --network host then binds the host's own addresses, and nothing is translated:

        sip-ip = ext-sip-ip = <host address>       no ports published
        rtp-ip = ext-rtp-ip = <host address>       packaged RTP range unchanged

    That is the same configuration a bare-metal Windows XCC gets, which is the point:
    the XPhone server needs no container-specific profile at all.

    Verified by capture on the distro's eth2, from a second machine on the LAN:

        eth2 In  172.30.83.207.63375 > 172.30.83.201.8021: [S]
        eth2 Out 172.30.83.201.8021 > 172.30.83.207.63375: [S.]

    Three things this mode needs, none of them optional:

      1. Both firewalls opened for the ports. The Windows host firewall matches
         FreeSWITCH by PROGRAM (FreeSwitchConsole.exe), which never matches a process
         in WSL, so portbased rules are required; and the Hyper-V firewall of the WSL
         VM has DefaultInboundAction=Block. See hyperv-fw.ps1.
      2. The distro kept alive. WSL shuts a distro down once no wsl.exe session is
         attached, and dockerd goes with it.
      3. From Windows itself the service is reachable on localhost only, not on the
         host address - Windows and WSL share that address, so the connection never
         leaves the Windows stack. LAN clients are unaffected.

    -- Both modes ----------------------------------------------------------------

    Configuration and databases live in named volumes, so removing and recreating the
    container keeps them. /etc/freeswitch holds what the server wrote,
    /var/lib/freeswitch holds c4b.db, callcenter.db and core.db.

.PARAMETER Context
    Docker context to use, for example wsl-native. Empty means the CLI default.

.PARAMETER HostNetwork
    Run with --network host instead of a bridge. Only meaningful against a dockerd
    inside a WSL distro with mirrored networking; against Docker Desktop it lands in
    Desktop's own namespace, which is not the host.

.PARAMETER Recreate
    Remove an existing container and create it anew. Safe with respect to
    configuration and databases - those are in volumes - but it drops anything written
    elsewhere in the container.

.PARAMETER Reset
    Additionally delete the volumes, so the XCC starts from the packaged state and the
    server reconfigures it from scratch.

.EXAMPLE
    build\Linux\xcc-dev\xcc-dev.ps1 -Build

.EXAMPLE
    build\Linux\xcc-dev\xcc-dev.ps1 -Context wsl-native -HostNetwork -Build
#>
[CmdletBinding()]
param (
    [string]$XccDeb = 'D:\TFS\C4B UC\Dev\VS2026\Applications\Telephone\XCC\FsC4B_Modules\bin_Core\net10.0\freeswitch-xcc-core.deb',
    [string]$DebsDir = (Join-Path $PSScriptRoot '..\_debs'),
    [string]$ImageTag = 'xcc-dev',
    [string]$ContainerName = 'xcc-dev',

    [string]$Context = '',
    [switch]$HostNetwork,

    [string]$Network = 'xcc-net',
    [string]$Subnet4 = '172.28.0.0/24',
    [string]$Gateway4 = '172.28.0.1',
    [string]$Subnet6 = 'fd00:c4b:1::/64',
    [string]$Gateway6 = 'fd00:c4b:1::1',
    [string]$ContainerIp4 = '172.28.0.10',
    [string]$ContainerIp6 = 'fd00:c4b:1::10',

    [int]$EslPort = 8022,
    [int]$SipPort = 5062,
    [int]$RtpStart = 34000,
    [int]$RtpEnd = 34099,

    [string]$EtcVolume = 'xcc-etc',
    [string]$VarVolume = 'xcc-var',

    [switch]$Build,
    [switch]$Recreate,
    [switch]$Reset,
    [switch]$Foreground
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker not found in PATH." }
if ($Context) { $env:DOCKER_CONTEXT = $Context }

$os = (docker version --format '{{.Server.Os}}' 2>&1)
if ($os -ne 'linux') { throw "Docker is not running Linux containers (server OS: $os)." }

# ---------------------------------------------------------------- image ---------
if ($Build -or -not (docker images -q $ImageTag)) {
    if (-not (Test-Path -LiteralPath $XccDeb)) { throw "not found: $XccDeb" }
    $DebsDir = (Resolve-Path $DebsDir).Path
    $debCount = @(Get-ChildItem -LiteralPath $DebsDir -Filter '*.deb' -File).Count
    if ($debCount -eq 0) { throw "no packages in $DebsDir - run build\Linux\build-debs.ps1 first." }

    $ctx = Join-Path ([IO.Path]::GetTempPath()) "xcc-dev-ctx-$PID"
    New-Item -ItemType Directory -Path (Join-Path $ctx 'debs') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ctx 'xcc') -Force | Out-Null
    try {
        Write-Host "Assembling context ($debCount packages + $(Split-Path $XccDeb -Leaf)) ..."
        Copy-Item -Path (Join-Path $DebsDir '*.deb') -Destination (Join-Path $ctx 'debs')
        Copy-Item -LiteralPath $XccDeb -Destination (Join-Path $ctx 'xcc\freeswitch-xcc-core.deb')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Dockerfile') -Destination $ctx
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'entrypoint.sh') -Destination $ctx

        Write-Host "Building image $ImageTag ..."
        docker build -t $ImageTag $ctx
        if ($LASTEXITCODE -ne 0) { throw "docker build failed." }
    }
    finally {
        if (Test-Path $ctx) { Get-ChildItem $ctx -Recurse -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $ctx) { [IO.Directory]::Delete($ctx, $true) }
    }
}

# --------------------------------------------------------------- network --------
if (-not $HostNetwork) {
    if (-not (docker network ls --filter "name=^$Network$" --format '{{.Name}}')) {
        Write-Host "Creating network $Network ($Subnet4, $Subnet6) ..."
        docker network create --driver bridge --ipv6 `
            --subnet $Subnet4 --gateway $Gateway4 `
            --subnet $Subnet6 --gateway $Gateway6 $Network | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "could not create network $Network." }
    }
}

# --------------------------------------------------------------- volumes --------
if ($Reset) {
    Write-Host "Reset: dropping volumes $EtcVolume and $VarVolume ..."
    docker rm -f $ContainerName 2>&1 | Out-Null
    docker volume rm $EtcVolume $VarVolume 2>&1 | Out-Null
}

$hostIp4 = (Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue |
    Where-Object { $_.InterfaceAlias -notmatch 'Loopback|WSL|Default Switch|Virtual' -and $_.IPAddress -notmatch '^169\.254\.' } |
    Select-Object -First 1).IPAddress
$hostIp6 = (Get-NetIPAddress -AddressFamily IPv6 -EA SilentlyContinue |
    Where-Object { $_.IPAddress -match '^2' } | Select-Object -First 1).IPAddress

# ------------------------------------------------------------- container --------
$existing = docker ps -aq --filter "name=^$ContainerName$"
if ($existing -and -not ($Recreate -or $Reset)) {
    $state = docker inspect -f '{{.State.Status}}' $ContainerName
    if ($state -eq 'running') {
        Write-Host "$ContainerName is already running - left untouched. -Recreate rebuilds it, 'docker restart $ContainerName' restarts the service."
    } else {
        Write-Host "Starting the existing container ($state) - configuration and databases are kept."
        docker start $ContainerName | Out-Null
    }
} else {
    docker rm -f $ContainerName 2>&1 | Out-Null
    $runArgs = @('run', '--name', $ContainerName)
    if ($Foreground) { $runArgs += @('--rm', '-it') } else { $runArgs += '-d' }
    $runArgs += @('-v', "${EtcVolume}:/etc/freeswitch", '-v', "${VarVolume}:/var/lib/freeswitch")
    # Without it FreeSWITCH logs 'Failed to set SCHED_FIFO scheduler' and runs the RTP
    # threads at normal priority.
    $runArgs += @('--cap-add', 'SYS_NICE')

    if ($HostNetwork) {
        # No addresses, no published ports: the container binds what the host has, and
        # the packaged RTP range stays as it is because nothing is translated. The
        # entrypoint detects local_ip_v4 from the interface it finds, which in mirrored
        # mode is the host's own address.
        $runArgs += @('--network', 'host')
        $runArgs += @('-e', "XCC_LOCAL_IP=$hostIp4")
        if ($PSBoundParameters.ContainsKey('RtpStart') -and $PSBoundParameters.ContainsKey('RtpEnd')) {
            $runArgs += @('-e', "XCC_RTP_START=$RtpStart", '-e', "XCC_RTP_END=$RtpEnd")
        }
    } else {
        $runArgs += @('--network', $Network, '--ip', $ContainerIp4, '--ip6', $ContainerIp6)
        $runArgs += @('-p', "${EslPort}:8021/tcp")
        $runArgs += @('-p', "${SipPort}:5060/udp", '-p', "${SipPort}:5060/tcp")
        $runArgs += @('-p', "${RtpStart}-${RtpEnd}:${RtpStart}-${RtpEnd}/udp")
        $runArgs += @('-e', "XCC_LOCAL_IP=$ContainerIp4", '-e', "XCC_RTP_START=$RtpStart", '-e', "XCC_RTP_END=$RtpEnd")
    }

    $runArgs += $ImageTag
    & docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker run failed." }
}

Write-Host ""
if ($HostNetwork) {
    Write-Host "  host network - the container binds the host's own addresses"
    Write-Host "  host        $hostIp4   $hostIp6"
    Write-Host "  ports       esl 8021    sip 5060    rtp as packaged - nothing published"
    Write-Host ""
    Write-Host "  The XPhone server needs no container-specific profile:"
    Write-Host "      sip-ip     = $hostIp4          ext-sip-ip = $hostIp4"
    Write-Host "      rtp-ip     = $hostIp4          ext-rtp-ip = $hostIp4"
    Write-Host ""
    Write-Host "  From Windows itself use localhost, not $hostIp4 - Windows and WSL share"
    Write-Host "  that address, so such a connection never leaves the Windows stack. LAN"
    Write-Host "  clients reach $hostIp4 normally. Both firewalls must be open for the"
    Write-Host "  ports (see hyperv-fw.ps1), and a wsl.exe session must keep the distro up."
}
else {
    Write-Host "  container   $ContainerIp4   $ContainerIp6"
    Write-Host "  host        $hostIp4   $hostIp6"
    Write-Host "  published   esl $EslPort -> 8021    sip $SipPort -> 5060    rtp $RtpStart-$RtpEnd (1:1)"
    Write-Host ""
    Write-Host "  The XPhone server has to bind and advertise different addresses:"
    Write-Host "      sip-ip     = $ContainerIp4          ext-sip-ip   = $hostIp4"
    Write-Host "      rtp-ip     = $ContainerIp4          ext-rtp-ip   = $hostIp4"
    Write-Host "      sip-port   = 5060                   ext-sip-port = $SipPort"
    Write-Host "      rtp range  = $RtpStart-$RtpEnd (published 1:1, no translation)"
    if ($SipPort -ne 5060) {
        Write-Host ""
        Write-Host "  ext-sip-port is not optional here: sofia writes ext-sip-ip:sip-port into"
        Write-Host "  Contact and Via, so without it peers would answer to $hostIp4`:5060, where"
        Write-Host "  nothing listens. RTP has no such parameter - each stream picks a port from"
        Write-Host "  the range and puts it into the SDP unchanged, which is why that range must"
        Write-Host "  be published 1:1. Stop the Windows XCC and -SipPort 5060 -EslPort 8021"
        Write-Host "  removes the need for ext-sip-port altogether."
    }
}
