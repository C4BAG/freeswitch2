<#
.SYNOPSIS
    Deploys the Release x64 build into a freely chosen target tree, for example a TFS
    working folder.

.DESCRIPTION
    Unlike copyRelease2Server.ps1 the target path is taken literally - nothing is
    appended. Write protection is never cleared: if a target file is read-only the
    script names it and stops, so it can be checked out in source control first.

    Binaries and PDBs go to separate directories, because that is how the XCC tree is
    laid out. Pass -PdbDestination to place them, -NoPdb to skip them.

    Only build artefacts are copied. Configuration, sounds, scripts and the managed
    plugin under mod\managedcore are not produced by this repository and have to come
    from the previous deployment.

.EXAMPLE
    .\copyRelease2Tfs.ps1 `
        -Destination    "D:\TFS\C4B UC\Main\3rd Party\FreeSWITCH\C4B_FreeSwitch\Release64\XCC_1.11" `
        -PdbDestination "D:\TFS\C4B UC\Main\3rd Party\FreeSWITCH\C4B_FreeSwitch\Release64\pdb_1.11"
#>
param (
    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [string]$PdbDestination,

    [switch]$NoPdb
)

$fwd = @{
    Configuration = 'Release'
    Destination   = $Destination
    KeepReadOnly  = $true
    NoPdb         = $NoPdb
}
if ($PdbDestination) { $fwd['PdbDestination'] = $PdbDestination }

& "$PSScriptRoot\copybuild2Server.ps1" @fwd