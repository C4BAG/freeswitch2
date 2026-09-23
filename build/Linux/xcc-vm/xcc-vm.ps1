<#
.SYNOPSIS
    Builds, creates and provisions the Hyper-V VM that runs the XCC under Linux.

.DESCRIPTION
    Four steps, each its own switch, because they need different privileges:

      -BuildImage   downloads Debian 12 and writes the VHDX plus the cloud-init seed.
                    Runs in a WSL distribution, which is only the build machine -
                    Windows ships no image converter. No admin.
      -CreateVm     creates and starts the VM. Needs ADMIN: without it the Hyper-V
                    cmdlets return empty results rather than an error, which is easy
                    to mistake for "the VM does not exist".
      -Provision    installs the XCC over SSH. No admin.
      -Status       what the VM is doing. No admin, but the Hyper-V part of the output
                    stays empty unless elevated.

    The VM attaches to the EXISTING external switch, so it gets its own LAN address by
    DHCP - different from the host's. That is the entire reason this model exists; see
    README.md for what the container models could not do.

.NOTES
    Debian's 'generic' variant is mandatory. 'genericcloud' carries virtio only, so
    under Hyper-V the kernel finds no SCSI disk and panics one second after GRUB.

.PARAMETER Replace
    With -CreateVm: remove the existing VM and its disk, put the freshly built
    <name>-new.vhdx in its place, then create anew. For swapping the image while the
    old VM still holds the file.

.PARAMETER Ipv6Address
    Static IPv6 for the VM, without prefix length. This site has no IPv6 router, so
    there is nothing to autoconfigure from; the convention here is the suffix
    172:23:83:<last octet of the IPv4>. Omit to leave the VM with link-local IPv6.

.EXAMPLE
    build\Linux\xcc-vm\xcc-vm.ps1 -BuildImage
    build\Linux\xcc-vm\xcc-vm.ps1 -CreateVm          # as administrator
    build\Linux\xcc-vm\xcc-vm.ps1 -Provision -Ipv6Address 2003:c9:882f:223:172:23:83:210
#>
[CmdletBinding()]
param(
    [string]$Name = 'xcc-linux',
    [string]$Path = 'D:\HyperV',
    [string]$SwitchName = 'Extern',
    [string]$Distro = 'Debian',

    [string]$DebsDir = (Join-Path $PSScriptRoot '..\_debs'),
    [string]$XccDeb = 'D:\TFS\C4B UC\Dev\VS2026\Applications\Telephone\XCC\FsC4B_Modules\bin_Core\net10.0\freeswitch-xcc-core.deb',

    [int64]$MemoryStartupBytes = 4GB,
    [int]$CpuCount = 4,
    [int]$DiskGB = 24,

    [string]$VmAddress = '',
    [string]$Ipv6Address = '',

    [switch]$BuildImage,
    [switch]$CreateVm,
    [switch]$Provision,
    [switch]$Status,
    [switch]$Replace,
    [switch]$Remove,
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'

if (-not ($BuildImage -or $CreateVm -or $Provision -or $Status -or $Remove -or $Purge)) {
    throw "Pick a step: -BuildImage, -CreateVm, -Provision, -Status, -Remove or -Purge."
}

$dir     = Join-Path $Path $Name
$vhdx    = Join-Path $dir "$Name.vhdx"
$vhdxNew = Join-Path $dir "$Name-new.vhdx"
$seed    = Join-Path $dir 'seed.iso'

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-WslPath {
    param([string]$WindowsPath)
    $p = (& wsl -d $Distro -u root -- wslpath -a ($WindowsPath -replace '\\', '/')) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "could not translate '$WindowsPath' for WSL: $p" }
    return ($p | Select-Object -First 1).Trim()
}

function Invoke-InDistro {
    param([string]$ScriptFile, [string[]]$Arguments = @(), [hashtable]$Env = @{})
    $script = ConvertTo-WslPath $ScriptFile
    $prefix = ($Env.GetEnumerator() | ForEach-Object { "$($_.Key)='$($_.Value)'" }) -join ' '
    $cmd = "$prefix bash '$script' $($Arguments -join ' ')".Trim()
    & wsl -d $Distro -u root -- bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { throw "step failed in distro '$Distro' (exit $LASTEXITCODE)." }
}

function Get-VmAddress {
    if ($VmAddress) { return $VmAddress }
    if (Test-Admin) {
        $ips = (Get-VMNetworkAdapter -VMName $Name -EA SilentlyContinue).IPAddresses
        $v4 = $ips | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
        if ($v4) { return $v4 }
    }
    # hyperv-daemons has not reported yet, or we are not elevated. Find the VM by asking
    # the neighbours with a Hyper-V MAC for their hostname - the MAC pool alone is not
    # proof, other hosts on this LAN use the same range.
    Write-Host "Address not reported - searching the LAN ..."
    $find = Join-Path $PSScriptRoot 'find-vm.sh'
    $subnet = ((Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch 'Loopback|WSL' -and $_.IPAddress -notmatch '^169\.254\.' } |
        Select-Object -First 1).IPAddress -split '\.')[0..2] -join '.'
    $out = & wsl -d $Distro -u root -- bash -lc "bash '$(ConvertTo-WslPath $find)' $subnet $Name"
    $hit = $out | Select-String '^FOUND ' | Select-Object -First 1
    if (-not $hit) { throw "could not find the VM. Pass -VmAddress explicitly.`n$($out -join "`n")" }
    return ($hit.ToString() -split ' ')[1]
}

# ------------------------------------------------------------------ remove ------
if ($Remove -or $Purge) {
    if (-not (Test-Admin)) { throw "-Remove and -Purge need an elevated PowerShell." }
    if (Get-VM -Name $Name -EA SilentlyContinue) {
        Stop-VM -Name $Name -TurnOff -Force -EA SilentlyContinue
        Remove-VM -Name $Name -Force
        Write-Host "  removed VM $Name"
    } else { Write-Host "  VM $Name does not exist" }
    if ($Purge -and (Test-Path $vhdx)) { Remove-Item $vhdx -Force; Write-Host "  deleted $vhdx" }
    return
}

# -------------------------------------------------------------- build image -----
if ($BuildImage) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $vmExists = (Test-Admin) -and (Get-VM -Name $Name -EA SilentlyContinue)
    $newSuffix = if ($vmExists -or (Test-Path $vhdx)) { '1' } else { '0' }
    if ($newSuffix -eq '1') {
        Write-Host "An image is already in place - writing $Name-new.vhdx; use -CreateVm -Replace to swap it in."
    }
    Invoke-InDistro (Join-Path $PSScriptRoot 'prepare-image.sh') -Env @{
        OUT_DIR     = (ConvertTo-WslPath $dir)
        DISK_NAME   = $Name
        VM_HOSTNAME = $Name
        NEW_SUFFIX  = $newSuffix
    }
}

# --------------------------------------------------------------- create vm ------
if ($CreateVm) {
    if (-not (Test-Admin)) {
        throw "-CreateVm needs an elevated PowerShell. Without it the Hyper-V cmdlets return empty results instead of an error."
    }

    if ($Replace) {
        if (-not (Test-Path -LiteralPath $vhdxNew)) { throw "not found: $vhdxNew - run -BuildImage first." }
        if (Get-VM -Name $Name -EA SilentlyContinue) {
            Stop-VM -Name $Name -TurnOff -Force -EA SilentlyContinue
            Remove-VM -Name $Name -Force
            Write-Host "  removed the previous VM"
        }
        if (Test-Path $vhdx) { Remove-Item $vhdx -Force }
        Move-Item -LiteralPath $vhdxNew -Destination $vhdx
        Write-Host "  swapped in the new image"
    }

    foreach ($f in $vhdx, $seed) {
        if (-not (Test-Path -LiteralPath $f)) { throw "not found: $f - run -BuildImage first." }
    }
    if (-not (Get-VMSwitch -Name $SwitchName -EA SilentlyContinue)) {
        throw "switch '$SwitchName' not found. Available: $((Get-VMSwitch).Name -join ', ')"
    }
    if (Get-VM -Name $Name -EA SilentlyContinue) {
        throw "VM $Name already exists. -Replace replaces it including the disk, -Remove keeps the disk, -Purge deletes it."
    }

    if ((Get-VHD -Path $vhdx).Size -lt ($DiskGB * 1GB)) {
        Resize-VHD -Path $vhdx -SizeBytes ($DiskGB * 1GB)
        Write-Host "  disk grown to $DiskGB GB - cloud-init extends the filesystem on first boot"
    }

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes $MemoryStartupBytes `
           -VHDPath $vhdx -SwitchName $SwitchName -Path $Path | Out-Null
    Set-VMProcessor -VMName $Name -Count $CpuCount
    Set-VMMemory    -VMName $Name -DynamicMemoryEnabled $false
    # Debian's images are UEFI capable but not signed with the Microsoft UEFI CA.
    Set-VMFirmware  -VMName $Name -EnableSecureBoot Off
    Add-VMDvdDrive  -VMName $Name -Path $seed
    Set-VMFirmware  -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name)
    Set-VM          -VMName $Name -AutomaticCheckpointsEnabled $false `
                    -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    Start-VM -Name $Name

    Write-Host ""
    Write-Host "  VM $Name started, MAC $((Get-VMNetworkAdapter -VMName $Name).MacAddress)"
    Write-Host "  cloud-init needs a minute. Then: xcc-vm.ps1 -Provision"
}

# ---------------------------------------------------------------- provision -----
if ($Provision) {
    $DebsDir = (Resolve-Path $DebsDir).Path
    if (-not (Test-Path -LiteralPath $XccDeb)) { throw "not found: $XccDeb" }
    $addr = Get-VmAddress
    Write-Host "Provisioning $Name at $addr ..."
    Invoke-InDistro (Join-Path $PSScriptRoot 'provision.sh') -Arguments @($addr) -Env @{
        DEBS_DIR     = (ConvertTo-WslPath $DebsDir)
        XCC_DEB      = (ConvertTo-WslPath $XccDeb)
        IPV6_ADDRESS = $Ipv6Address
    }
    Write-Host ""
    Write-Host "  The XPhone server needs no container-specific profile:"
    Write-Host "      sip-ip = ext-sip-ip = $addr"
    Write-Host "      rtp-ip = ext-rtp-ip = $addr"
    Write-Host "      rtp range 30000-33000, unchanged; event socket on ${addr}:8021"
}

# ------------------------------------------------------------------- status -----
if ($Status) {
    if (Test-Admin) {
        Get-VM -Name $Name -EA SilentlyContinue |
            Select-Object Name, State, Status, Uptime, ProcessorCount,
                @{n='MemGB';e={[int]($_.MemoryAssigned/1GB)}} | Format-List
        Get-VMNetworkAdapter -VMName $Name -EA SilentlyContinue |
            Select-Object SwitchName, MacAddress, Status,
                @{n='IPs';e={$_.IPAddresses -join ', '}} | Format-List
    } else {
        Write-Host "(not elevated - the Hyper-V part is omitted, it would return empty)"
    }
    $addr = Get-VmAddress
    Invoke-InDistro (Join-Path $PSScriptRoot 'check.sh') -Arguments @($addr)
}
