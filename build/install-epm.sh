#!/bin/bash
#
# Installs the EPM System 11.2.15 base from the parts in $MEDIA that $MANIFEST lists,
# using install-response.xml next to this script. Runs at image build time as root, so
# it can read the media whatever its permissions; the installer itself runs as oracle.
#
# Oracle's rules for the media: unzip every part into one directory, with no spaces
# in its path; the assemblies land in assemblies/<product>/<version>/assembly.dat.

set -euo pipefail

: "${MEDIA:?MEDIA must point at the directory holding the Oracle media}"
: "${MANIFEST:?MANIFEST must name the manifest of the 11.2.15 Linux parts, in MEDIA}"

here=$(cd "$(dirname "$0")" && pwd)
staging=/tmp/epm-media
response=/tmp/install-response.xml

log() {
    echo "[install-epm] $*"
}

# Every part present and intact before 40 minutes of installing.
"$here/check-media.sh" "$MEDIA" "$MANIFEST"

# The manifest lists the parts in Oracle's order, Part 1 to Part 6.
mapfile -t zips < <(awk 'NF == 2 {print $2}' "$MEDIA/$MANIFEST")

log "ulimit -n is $(ulimit -n); /tmp has $(df -h /tmp | awk 'NR==2 {print $4}') free"

mkdir -p "$staging"
for zip in "${zips[@]}"; do
    log "Extracting $zip"
    unzip -q -o "$MEDIA/$zip" -d "$staging"
done
log "Assemblies available:"
ls -1 "$staging/assemblies"

sed -e "s|__MW_HOME__|$MW_HOME|g" "$here/install-response.xml" > "$response"
chown -R oracle:oinstall "$staging" "$response"

# Don't use relative paths for either the installer or the response file. The
# installer re-launches itself through several shells and loses the working directory.
# runuser without -l keeps the environment (MW_HOME and friends) and sets HOME.
log "Running installTool.sh -silent as oracle"
runuser -u oracle -- bash -c "cd '$staging' && xvfb-run -a '$staging/installTool.sh' -silent '$response'"

# The installer's exit status isn't trustworthy, so check for what it should have laid
# down, and show the per-assembly logs either way.
install_logs="$EPM_ORACLE_HOME/diagnostics/logs/install"
if [ -d "$install_logs" ]; then
    log "Install logs:"
    ls -1 "$install_logs"
    grep -i -l -E 'fail|error' "$install_logs"/*.log || true
fi

missing=0
for path in \
    "$MW_HOME/wlserver" \
    "$MW_HOME/jdk/bin/java" \
    "$MW_HOME/oracle_common/bin/rcu" \
    "$MW_HOME/essbase" \
    "$EPM_ORACLE_HOME/common/config/11.1.2.0/configtool.sh" \
    "$EPM_ORACLE_HOME/products/Planning"; do
    if [ ! -e "$path" ]; then
        echo "Expected after install, but missing: $path" >&2
        missing=1
    fi
done
[ $missing -eq 0 ] || exit 1

rm -rf "$staging" "$response"
log "Base install complete"
