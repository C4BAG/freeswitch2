<#
.SYNOPSIS
    Copies the XCC set of build artefacts out of this repository into a target tree.

.DESCRIPTION
    Two ways to name the target. -Branch keeps the original behaviour and appends
    _build\<Configuration>\server\XCC to the path given. -Destination takes the path
    literally, which is what a deployment into a source-controlled tree needs.

    PDBs are a different set from the binaries: most belong to statically linked
    libraries that have no DLL of their own, and the build produces no FreeSwitch.pdb
    and no mod_*.pdb at all. They are therefore not derived from the binary list.
    Without -PdbDestination each copied binary's PDB is placed next to it, as before;
    with it, every *.pdb the build produced is copied flat into that directory.

.PARAMETER KeepReadOnly
    Never clear the read-only flag on anything. Instead, refuse to start when a target
    file is read-only and name the files. Use this for a TFS working folder: the files
    have to be checked out there, not made writable behind source control's back.

.EXAMPLE
    .\copybuild2Server.ps1 -Configuration Release -Branch D:\xphone\branch

.EXAMPLE
    .\copybuild2Server.ps1 -Configuration Release -KeepReadOnly `
        -Destination     "D:\TFS\...\Release64\XCC_1.11" `
        -PdbDestination  "D:\TFS\...\Release64\pdb_1.11"
#>
[CmdletBinding(DefaultParameterSetName = 'Branch')]
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration,

    [Parameter(Mandatory = $true, ParameterSetName = 'Branch')]
    [string]$Branch,

    [Parameter(Mandatory = $true, ParameterSetName = 'Destination')]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Destination')]
    [string]$PdbDestination,

    [switch]$NoPdb,

    [switch]$KeepReadOnly
)

$ErrorActionPreference = 'Stop'

$scriptPath = $PSScriptRoot
$buildPath  = Join-Path -Path $scriptPath -ChildPath "x64\$Configuration\"

if ($PSCmdlet.ParameterSetName -eq 'Branch') {
    $xccPath = Join-Path -Path $Branch -ChildPath "_build\$Configuration\server\XCC"
} else {
    $xccPath = $Destination
}

class Binary {
    [string]$General
    [string]$Release
    [string]$Debug
}

$binariesToCopy = @(
    [PSCustomObject]@{ General = "FreeSwitch.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "FreeSwitchConsole.exe"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "fs_cli.exe"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libapr.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libbroadvoice.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libpng16.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libpq.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libsndfile-1.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libspandsp.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "libteletone.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "lua53.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "openssl.exe"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = $null; Release = "pcre2-8.dll"; Debug = "pcre2-8d.dll" },
    [PSCustomObject]@{ General = "pocketsphinx.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "pthread.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "sphinxbase.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = $null; Release = "zlib.dll"; Debug = "zlibd.dll" },
    [PSCustomObject]@{ General = "\mod\FreeSWITCH.ManagedCore.deps.json"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\FreeSWITCH.ManagedCore.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\FreeSWITCH.ManagedCore.runtimeconfig.json"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_callcenter.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_commands.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_conference.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_console.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_dialplan_xml.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_dptools.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_event_socket.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_expr.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_fifo.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_fsv.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_hash.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_local_stream.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_logfile.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_loopback.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_lua.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_managed.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_managedcore.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_native_file.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_opus.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_png.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_siren.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_sndfile.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_sofia.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_spandsp.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_tone_stream.dll"; Release = $null; Debug = $null },
    [PSCustomObject]@{ General = "\mod\mod_verto.dll"; Release = $null; Debug = $null }
)


# Resolve the binary list for this configuration once, so a missing file is reported
# before anything is copied rather than half way through.
$files = @()
foreach ($binary in $binariesToCopy)
{
    if ($binary.General) {
        $files += $binary.General
    }
    elseif ($Configuration -eq "Release" -and $binary.Release) {
        $files += $binary.Release
    }
    elseif ($Configuration -eq "Debug" -and $binary.Debug) {
        $files += $binary.Debug
    }
    else {
        Write-Warning "Keine passende Datei gefunden für Konfiguration '$Configuration'"
    }
}

$missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $buildPath $_) -PathType Leaf) })
if ($missing.Count) {
    Write-Host "Missing in $buildPath :" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    throw "$($missing.Count) of $($files.Count) files are not in the build. Nothing was copied."
}

# With -KeepReadOnly the write protection of the target is source control's business,
# not this script's. Report and stop so the files can be checked out properly.
if ($KeepReadOnly) {
    $locked = @()
    foreach ($f in $files) {
        $t = Join-Path $xccPath $f
        if ((Test-Path -LiteralPath $t -PathType Leaf) -and (Get-Item -LiteralPath $t).IsReadOnly) { $locked += $f }
    }
    if ($locked.Count) {
        Write-Host "Read-only in $xccPath :" -ForegroundColor Red
        $locked | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw "$($locked.Count) target files are write protected. Check them out first; this script will not clear the flag."
    }
}

function CopyOne ($source, $destination)
{
    $dir = Split-Path -Path $destination -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $destination -Force
    if (-not $KeepReadOnly) {
        Set-ItemProperty -LiteralPath $destination -Name IsReadOnly -Value $false
    }
}

foreach ($f in $files) {
    CopyOne (Join-Path $buildPath $f) (Join-Path $xccPath $f)
}
Write-Host "$($files.Count) binaries -> $xccPath"

if ($NoPdb) {
    Write-Host "PDBs skipped (-NoPdb)."
}
elseif ($PdbDestination) {
    # Every PDB the build produced, flat. The set cannot be derived from the binary
    # list: most PDBs belong to statically linked libraries with no DLL of their own,
    # and the build produces neither FreeSwitch.pdb nor any mod_*.pdb.
    $pdbs = @(Get-ChildItem -LiteralPath $buildPath -Filter '*.pdb' -File) +
            @(Get-ChildItem -LiteralPath (Join-Path $buildPath 'mod') -Filter '*.pdb' -File -ErrorAction SilentlyContinue)
    if ($KeepReadOnly) {
        $locked = @($pdbs | Where-Object {
            $t = Join-Path $PdbDestination $_.Name
            (Test-Path -LiteralPath $t -PathType Leaf) -and (Get-Item -LiteralPath $t).IsReadOnly })
        if ($locked.Count) {
            Write-Host "Read-only in $PdbDestination :" -ForegroundColor Red
            $locked | ForEach-Object { Write-Host "  $($_.Name)" -ForegroundColor Red }
            throw "$($locked.Count) target PDBs are write protected. Check them out first."
        }
    }
    foreach ($pdb in $pdbs) { CopyOne $pdb.FullName (Join-Path $PdbDestination $pdb.Name) }
    $mb = [Math]::Round((($pdbs | Measure-Object Length -Sum).Sum) / 1MB)
    Write-Host "$($pdbs.Count) PDBs ($mb MB) -> $PdbDestination"
}
else {
    # Original behaviour: the PDB belonging to each binary, next to it.
    $n = 0
    foreach ($f in $files) {
        $dir  = Split-Path -Path $f -Parent
        $name = [IO.Path]::GetFileNameWithoutExtension($f) + ".pdb"
        $rel  = if ([string]::IsNullOrEmpty($dir)) { $name } else { Join-Path $dir $name }
        $src  = Join-Path $buildPath $rel
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            CopyOne $src (Join-Path $xccPath $rel)
            $n++
        }
    }
    Write-Host "$n PDBs -> $xccPath"
}