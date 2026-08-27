param (
    [Parameter(Mandatory = $true)]
    [string]$Branch
)

& "$PSScriptRoot\copybuild2Server.ps1" -Configuration "Debug" -Branch $Branch