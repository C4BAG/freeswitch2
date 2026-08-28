<#
.SYNOPSIS
    Builds the Debian packages of this line in a container, from a Windows working copy.

.DESCRIPTION
    Wraps docker/build/debs-from-source.Dockerfile, which is upstream's own recipe:
    debian:bookworm, the dependency sources cloned and built into packages, then
    fsdeb.sh for FreeSWITCH itself. Because fsdeb.sh goes through debian/util.sh and
    therefore debian/bootstrap.sh, c4b-freeswitch-meta-all is produced with the rest.

    No SignalWire token is needed - that is only for the prebuilt package repository.

    Three things this script exists for, each of them measured rather than assumed:

    1. The build context is a shallow clone, not the working copy and not git archive.
       Handing docker the working copy carries CRLF into the container: on this machine
       176 of 384 Makefile.am, 7 of 24 configure.ac and every shell script, which
       breaks autotools and produces "bad interpreter". git archive does not help -
       it applies the same checkout conversion, so with core.autocrlf=true it emits
       CRLF as well. A clone made with core.autocrlf=false gives LF, and unlike an
       archive it also brings .git, which fsdeb.sh needs: it derives the package
       version from git rev-parse and aborts with "fatal: not in a git directory"
       otherwise. The version then names the real commit.

    2. SPANDSP_REF=origin/master. The Dockerfile clones spandsp's packages branch,
       which is at 3.0.0 and builds libspandsp3, while this tree's debian/bootstrap.sh
       build-depends on libspandsp4-dev. master is 3.1.1 with ABI 4 and carries the
       matching packaging. Without this, apt drops the whole build-deps package and
       every dependency is then reported as unmet.

    3. The image's entrypoint is replaced by in-container-build.sh. See the comment
       block there: libv8 does not build on bookworm, and a failing dependency build
       is otherwise reported as success.

.PARAMETER Ref
    Git ref to build. Default HEAD. The working copy is not read - what gets built is
    what is committed.

.PARAMETER OutputDir
    Where the .deb files land. Default build\Linux\_debs, which is gitignored.

.PARAMETER SkipDeps
    Reuse the dependency packages already in OutputDir and only rebuild the local apt
    repository from them. Saves about ten minutes per iteration.

.PARAMETER ImageOnly
    Build the image and stop - a dry run over context, clones and COPY.

.EXAMPLE
    build\Linux\build-debs.ps1

.EXAMPLE
    build\Linux\build-debs.ps1 -SkipDeps -OutputDir D:\temp\debs
#>
[CmdletBinding()]
param (
    [string]$Ref = 'HEAD',
    [string]$OutputDir = "$PSScriptRoot\_debs",
    [string]$ImageTag = 'fs-deb-builder',
    [string]$SpandspRef = 'origin/master',
    [switch]$SkipDeps,
    [switch]$ImageOnly
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$dockerfileRel = 'docker/build/debs-from-source.Dockerfile'
$inner = Join-Path $PSScriptRoot 'in-container-build.sh'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "docker not found in PATH." }
$os = (docker version --format '{{.Server.Os}}' 2>&1)
if ($os -ne 'linux') { throw "Docker is not running Linux containers (server OS: $os)." }
if (-not (Test-Path $inner)) { throw "$inner not found." }

$clone = Join-Path ([IO.Path]::GetTempPath()) "fs-ctx-$PID"
Remove-Item $clone -Recurse -Force -ErrorAction SilentlyContinue
try {
    $url = 'file://' + ($repoRoot -replace '\\', '/')
    Write-Host "Cloning $Ref from $url without the checkout conversion ..."
    git clone -q -c core.autocrlf=false --depth 1 --no-single-branch $url $clone
    if ($LASTEXITCODE -ne 0) { throw "git clone failed." }
    if ($Ref -ne 'HEAD') {
        git -C $clone checkout -q $Ref
        if ($LASTEXITCODE -ne 0) { throw "ref '$Ref' not found in the clone." }
    }
    $sha = (git -C $clone rev-parse --short HEAD)
    $mb = [Math]::Round((Get-ChildItem $clone -Recurse -File -Force | Measure-Object Length -Sum).Sum / 1MB)
    Write-Host "  context: $mb MB, HEAD $sha"

    Write-Host "Building image $ImageTag (spandsp $SpandspRef) ..."
    docker build -t $ImageTag --build-arg "SPANDSP_REF=$SpandspRef" `
        -f (Join-Path $clone $dockerfileRel.Replace('/', '\')) $clone
    if ($LASTEXITCODE -ne 0) { throw "docker build failed." }
}
finally {
    Remove-Item $clone -Recurse -Force -ErrorAction SilentlyContinue
}

if ($ImageOnly) {
    Write-Host "Image built. Stopping here (-ImageOnly)."
    return
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$OutputDir = (Resolve-Path $OutputDir).Path

$envArgs = @()
if ($SkipDeps) { $envArgs += @('-e', 'SKIP_DEPS=1') }

Write-Host "Building packages into $OutputDir ..."
docker run --rm @envArgs `
    -v "${OutputDir}:/var/local/deb" `
    -v "${inner}:/c4b/in-container-build.sh:ro" `
    --entrypoint /bin/bash $ImageTag /c4b/in-container-build.sh
if ($LASTEXITCODE -ne 0) { throw "The package build failed." }

$fs = @(Get-ChildItem -LiteralPath $OutputDir -Filter 'freeswitch*.deb' -File)
if ($fs.Count -eq 0) { throw "No freeswitch package was produced." }

$debs = @(Get-ChildItem -LiteralPath $OutputDir -Filter '*.deb' -File)
Write-Host ("{0} packages, {1} MB - {2} of them freeswitch" -f `
    $debs.Count, [Math]::Round((($debs | Measure-Object Length -Sum).Sum) / 1MB), $fs.Count)
Get-ChildItem -LiteralPath $OutputDir -Filter 'c4b-*.deb' -File |
    ForEach-Object { Write-Host ("  " + $_.Name) }
