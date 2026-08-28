#!/bin/bash
#
# Runs inside the image built from docker/build/debs-from-source.Dockerfile.
# Called by build-debs.ps1, which mounts this file to /c4b/in-container-build.sh.
#
# It replaces the image's own entrypoint for two reasons.
#
# 1. libv8-packaging does not build on bookworm. Its gyp scripts are Python 2
#    ("except SyntaxError, e:") and the image has Python 3.11. FreeSWITCH does not
#    need those packages: mod_v8 build-depends on libnode-dev from the Debian archive
#    (debian/control-modules:549), not on libv8-dev. So the libraries are listed
#    explicitly instead of using -a.
#
# 2. The image's entrypoint reports success even when the dependency build fails.
#    It runs "deps && chmod && fsdeb" under "set -e", and set -e deliberately does not
#    fire for a command that is not the last in an && list - so a failing dependency
#    build short-circuits the chain, skips the FreeSWITCH build entirely, and the
#    following echo still prints "Build completed successfully". That is how a run can
#    produce 23 dependency packages, no freeswitch package, and exit 0.

set -euo pipefail

BUILD_NUMBER="${BUILD_NUMBER:-42}"
OUTPUT_DIR="${OUTPUT_DIR:-/var/local/deb}"
FS_DIR="${FS_DIR:-/usr/src/freeswitch}"

LIBS=(libbroadvoice libilbc libsilk spandsp sofia-sip libks signalwire-c)

if [ "${SKIP_DEPS:-0}" = "1" ]; then
    # Reuse the packages already in the mounted output directory and only rebuild the
    # local apt repository from them. Saves about ten minutes per iteration.
    echo "=== 1/2 dependencies: skipped, reusing $OUTPUT_DIR ==="
    # dpkg-scanpackages comes from dpkg-dev, which the skipped setup step installs.
    apt-get update -qq && apt-get install -y -qq dpkg-dev gzip
    ( cd "$OUTPUT_DIR" && dpkg-scanpackages -m . > Packages && gzip -kf Packages )
    printf 'deb [trusted=yes] file:%s /\n' "$OUTPUT_DIR" > /etc/apt/sources.list.d/local.list
else
    echo "=== 1/2 dependencies: ${LIBS[*]} ==="
    /usr/local/bin/build-dependencies.sh \
        -b "$BUILD_NUMBER" -o "$OUTPUT_DIR" -p /usr/src -s -r "${LIBS[@]}"
fi
echo "=== dependencies done ==="

# debian/control build-depends on dotnet-sdk-10.0 for mod_managedcore, which Debian
# does not carry. Measured on 2026-08-28: it is the *only* build dependency of this
# line that bookworm cannot satisfy - mono, libtiff5-dev and libldns-dev are all in
# the archive. One extra repository is therefore cheaper than cutting the module set
# down, and it lets mod_managedcore be compiled on Linux for the first time.
echo "=== .NET SDK repository ==="
apt-get install -y -qq wget ca-certificates
wget -q https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -O /tmp/ms-prod.deb
dpkg -i /tmp/ms-prod.deb
apt-get update

# debian/rules:24 reads parallel=N out of DEB_BUILD_OPTIONS and passes it to make.
# Left alone it uses every core, and the Docker VM here has 24 of them against 1.9 GB
# of RAM - which is what killed cc1plus on mod_v8 ("Killed signal terminated program
# cc1plus") and took the daemon down with it. Two jobs fit; raise it on a machine with
# more memory, not more cores.
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:-parallel=2}"
echo "=== 2/2 freeswitch (DEB_BUILD_OPTIONS=$DEB_BUILD_OPTIONS) ==="
chmod +x "$FS_DIR/scripts/packaging/build/fsdeb.sh"
"$FS_DIR/scripts/packaging/build/fsdeb.sh" \
    -b "$BUILD_NUMBER" -o "$OUTPUT_DIR" -w "$FS_DIR"

echo "=== freeswitch done ==="
ls -1 "$OUTPUT_DIR"/freeswitch*.deb 2>/dev/null | wc -l | xargs -I{} echo "freeswitch packages: {}"
