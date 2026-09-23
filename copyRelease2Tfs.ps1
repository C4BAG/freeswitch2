<#
.SYNOPSIS
    Deploys the Release x64 build into a TFS working folder.

.DESCRIPTION
    Unlike copyRelease2Server.ps1 the target path is taken literally - nothing is
    appended. Write protection is never cleared: if a target file is read-only the
    script names it and stops, so it can be checked out in source control first.

    Binaries and PDBs go to separate directories, because that is how the XCC tree is
    laid out. Pass -PdbDestination to place them, -NoPdb to skip them.

    Only build artefacts are copied. Configuration, sounds, scripts and the managed
    plugin under mod\managedcore are not produced by this repository and have to come
    from the previous deployment.

.PARAMETER Name
    Name of the target directory under -Root. The PDB directory is derived from it by
    replacing the leading "XCC" with "pdb", which is how the tree is laid out:

        XCC      ->  pdb        the 1.10 line
        XCC11    ->  pdb11      the 1.11 line

    Defaults to XCC. Note that XCC is the line currently in service, so deploying
    there without meaning to would overwrite it - in a TFS working folder the
    read-only guard catches that and names every file it would have touched.

.PARAMETER Destination
    Full target path, instead of -Root and -Name. -PdbDestination then has to be given
    as well, or -NoPdb.

.EXAMPLE
    .\copyRelease2Tfs.ps1 -Name XCC11

.EXAMPLE
    .\copyRelease2Tfs.ps1 -Name XCC11 -NoPdb

.EXAMPLE
    .\copyRelease2Tfs.ps1 `
        -Destination    "D:\somewhere\else\XCC" `
        -PdbDestination "D:\somewhere\else\pdb"
#>
[CmdletBinding(DefaultParameterSetName = 'Name')]
param (
    [Parameter(ParameterSetName = 'Name')]
    [string]$Name = 'XCC',

    [Parameter(ParameterSetName = 'Name')]
    [string]$Root = 'D:\TFS\C4B UC\Main\3rd Party\FreeSWITCH\C4B_FreeSwitch\Release64',

    [Parameter(Mandatory = $true, ParameterSetName = 'Destination')]
    [string]$Destination,

    [Parameter(ParameterSetName = 'Destination')]
    [string]$PdbDestination,

    [switch]$NoPdb
)

if ($PSCmdlet.ParameterSetName -eq 'Name') {
    $Destination = Join-Path $Root $Name
    if (-not $NoPdb) {
        if ($Name -notmatch '^XCC') {
            throw "Cannot derive the PDB directory from '$Name' - it does not start with XCC. Use -Destination and -PdbDestination, or -NoPdb."
        }
        $PdbDestination = Join-Path $Root ('pdb' + $Name.Substring(3))
    }
}

$fwd = @{
    Configuration = 'Release'
    Destination   = $Destination
    KeepReadOnly  = $true
    NoPdb         = $NoPdb
}
if ($PdbDestination) { $fwd['PdbDestination'] = $PdbDestination }

Write-Host "Binaries -> $Destination"
if ($PdbDestination) { Write-Host "PDBs     -> $PdbDestination" }
elseif ($NoPdb)      { Write-Host "PDBs     -> skipped (-NoPdb)" }

& "$PSScriptRoot\copybuild2Server.ps1" @fwd
