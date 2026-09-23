<#
.SYNOPSIS
    Opens the firewalls for the XCC in a WSL distribution (host networking mode).

.DESCRIPTION
    Two firewalls sit in series, and the rules FreeSWITCH already has help with neither:

      1. The Windows host firewall matches FreeSWITCH by PROGRAM - the installer
         registers FreeSwitchConsole.exe - which never matches a process inside WSL.
         Portbased rules are required.

      2. The Hyper-V firewall of the WSL VM has DefaultInboundAction = Block, with
         default-allow rules only for ICMP and mDNS.

    Without both, a service in the distribution is reachable over 127.0.0.1 only, never
    over the host address, and no error says so - the packets are simply dropped.

    Not needed for build\Linux\xcc-vm\: a Hyper-V VM on the external switch sends its
    traffic out the physical adapter, which never passes the host's stack.

    Under Docker Desktop none of this is needed either, because there the receiving
    program is com.docker.backend, for which an allow rule already exists.

    MUST RUN AS ADMINISTRATOR.

.PARAMETER Remove
    Delete the rules this script created, in both firewalls.

.EXAMPLE
    build\Linux\xcc-dev\hyperv-fw.ps1

.EXAMPLE
    build\Linux\xcc-dev\hyperv-fw.ps1 -Remove
#>
[CmdletBinding()]
param(
    [switch]$Remove,
    [int]$SipPortLow  = 4800,
    [int]$SipPortHigh = 5100,
    [int]$RtpPortLow  = 30000,
    [int]$RtpPortHigh = 33000,
    [int]$EslPort     = 8021
)

$ErrorActionPreference = 'Stop'

# VMCreatorId of WSL. Hyper-V VMs created by other means carry different ids and are
# not affected by these rules.
$vm = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please start this in a PowerShell with administrator rights."
}

if ($Remove) {
    Get-NetFirewallHyperVRule -EA SilentlyContinue | Where-Object Name -like 'XCC-*' | ForEach-Object {
        Remove-NetFirewallHyperVRule -Name $_.Name
        "  removed from the Hyper-V firewall: $($_.Name)"
    }
    Get-NetFirewallRule -EA SilentlyContinue | Where-Object Name -like 'XCC-WSL-*' | ForEach-Object {
        Remove-NetFirewallRule -Name $_.Name
        "  removed from the host firewall:    $($_.Name)"
    }
    return
}

$rules = @(
    @{ Suffix = 'SIP-UDP'; Display = 'XCC SIP (UDP)';          Proto = 'UDP'; Ports = "$SipPortLow-$SipPortHigh" },
    @{ Suffix = 'SIP-TCP'; Display = 'XCC SIP (TCP)';          Proto = 'TCP'; Ports = "$SipPortLow-$SipPortHigh" },
    @{ Suffix = 'RTP-UDP'; Display = 'XCC RTP (UDP)';          Proto = 'UDP'; Ports = "$RtpPortLow-$RtpPortHigh" },
    @{ Suffix = 'ESL-TCP'; Display = 'XCC Event Socket (TCP)'; Proto = 'TCP'; Ports = "$EslPort" }
)

"--- Windows host firewall, portbased ---"
foreach ($r in $rules) {
    $n = "XCC-WSL-$($r.Suffix)"
    Get-NetFirewallRule -Name $n -EA SilentlyContinue | Remove-NetFirewallRule -EA SilentlyContinue
    New-NetFirewallRule -Name $n -DisplayName "$($r.Display) - WSL" -Direction Inbound `
        -Protocol $r.Proto -LocalPort $r.Ports -Action Allow -Profile Any | Out-Null
    "  $n  $($r.Proto) $($r.Ports)"
}

"--- Hyper-V firewall of the WSL VM ---"
foreach ($r in $rules) {
    $n = "XCC-$($r.Suffix)"
    Get-NetFirewallHyperVRule -Name $n -EA SilentlyContinue | Remove-NetFirewallHyperVRule -EA SilentlyContinue
    New-NetFirewallHyperVRule -Name $n -DisplayName $r.Display -Direction Inbound `
        -VMCreatorId $vm -Protocol $r.Proto -LocalPorts $r.Ports -Action Allow | Out-Null
    "  $n  $($r.Proto) $($r.Ports)"
}

""
"--- in the active store ---"
Get-NetFirewallHyperVRule -PolicyStore ActiveStore | Where-Object Name -like 'XCC-*' |
    Select-Object Name, Protocol, LocalPorts, Action, EnforcementStatus | Format-Table -AutoSize
Get-NetFirewallRule -PolicyStore ActiveStore | Where-Object Name -like 'XCC-WSL-*' |
    ForEach-Object {
        $f = $_ | Get-NetFirewallPortFilter
        [pscustomobject]@{ Name = $_.Name; Protocol = $f.Protocol; LocalPort = ($f.LocalPort -join ','); Action = $_.Action }
    } | Format-Table -AutoSize
