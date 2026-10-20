#!/bin/bash
#
# Installs the EPM System 11.2.15 base from the parts mounted at $BASE_MEDIA, using
# install-response.xml next to this script. Runs at image build time as root, so it can
# read the media whatever its permissions; the installer itself runs as oracle.
#
# Oracle's rules for the media: unzip every part into one directory, with no spaces
# in its path; the assemblies land in assemblies/<product>/<version>/assembly.dat.

set -euo pipefail

: "${BASE_MEDIA:?BASE_MEDIA must point at the directory holding the 11.2.15 Linux parts}"

here=$(cd "$(dirname "$0")" && pwd)
staging=/tmp/epm-media
response=/tmp/install-response.xml

log() {
    echo "[install-epm] $*"
}

# The parts may sit directly in $BASE_MEDIA or in subfolders (Part_1 ... Part_6). The
# installation docs and the Oracle HTTP Server installer are skipped: neither is needed.
: "${BASE_MEDIA_SKIP:=Docs OHS}"
find_args=()
for dir in $BASE_MEDIA_SKIP; do
    find_args+=(-not -path "*/$dir/*")
done
mapfile -t zips < <(find "$BASE_MEDIA" -name '*.zip' "${find_args[@]}" | sort)
if [ ${#zips[@]} -eq 0 ]; then
    echo "No zips in $BASE_MEDIA. Planning needs the EPM System 11.2.15 for Linux x86-64" \
         "Parts 1 to 6 (per the 11.2.15 media pack readme)." >&2
    exit 1
fi

log "ulimit -n is $(ulimit -n); /tmp has $(df -h /tmp | awk 'NR==2 {print $4}') free"

mkdir -p "$staging"
for zip in "${zips[@]}"; do
    log "Extracting ${zip#"$BASE_MEDIA"/}"
    unzip -q -o "$zip" -d "$staging"
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
