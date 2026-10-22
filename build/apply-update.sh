#!/bin/bash
#
# Applies the 11.2.26 update to the freshly installed 11.2.15 home, before any
# configuration, which is the order Oracle documents for a new install. Runs at image
# build time as root so it can read the media; the patching itself runs as oracle,
# the user that installed.
#
# Oracle's ApplyUpdate.sh extracts every zip in its own directory into the Middleware
# home and always exits 0, reporting problems only in its summary log. So this script
# hands it only the patches for products that are installed, and judges the result from
# that log.

set -euo pipefail

: "${MEDIA:?MEDIA must point at the directory holding the Oracle media}"
: "${MANIFEST:?MANIFEST must name the manifest of the 11.2.26 update, in MEDIA}"

here=$(cd "$(dirname "$0")" && pwd)
release=11.2.26
work=/tmp/epm-update
update="$work/$release.0-Update-Linux"
summary="$EPM_ORACLE_HOME/diagnostics/logs/install/ApplyUpdateSummary.log"

# configureLinux.properties keys to keep. Left out: HFM, FDMEE, FR, FCM, TAXPROV and
# HPCM (not installed), and all FMW.OHS* entries (OHS isn't installed either).
keep=(JDK Infra InfraCommon HSS Workspace CALC HP FMW.ADF FMW.CVEADF FMW.Weblogic FMW.ESS FMW.RCU FMW.OPSS)

log() {
    echo "[apply-update] $*"
}

"$here/check-media.sh" "$MEDIA" "$MANIFEST"
mapfile -t zips < <(awk 'NF == 2 {print $2}' "$MEDIA/$MANIFEST")
if [ ${#zips[@]} -ne 1 ]; then
    echo "Expected $MANIFEST to list exactly one update zip, found ${#zips[@]}" >&2
    exit 1
fi
media="$MEDIA/${zips[0]}"

mkdir -p "$work"
unzip -q -o "$media" \
    "$release.0-Update-Linux/ApplyUpdate.sh" \
    "$release.0-Update-Linux/RollbackUpdate.sh" \
    "$release.0-Update-Linux/configureLinux.properties" \
    -d "$work"

properties="$update/configureLinux.properties"
mv "$properties" "$properties.orig"
pattern=$(printf '%s|' "${keep[@]}" | sed -e 's/|$//' -e 's/\./\\./g')
grep -E "^($pattern)=" "$properties.orig" > "$properties"
log "Applying only these patches:"
cat "$properties"

# The patch files are named for their IDs (39314811-Planning-Linux.zip,
# 18143322-JDK-Linux.tar.gz, 39522094_12-WLS-Generic.zip), so extract by ID.
for id in $(cut -d= -f2 "$properties"); do
    unzip -q -o "$media" "$release.0-Update-Linux/$id*" -d "$work"
done
ls -l "$update"
chown -R oracle:oinstall "$work"

# The installer registers the Middleware (FMW) home in a second central inventory, which
# it puts in ~oracle/oraInventory: outside /u01/oracle, so it would never reach the image
# or the epm-home volume. Move it in and repoint the Middleware home's oraInst.loc. (The
# EPM home is registered in /u01/oracle/oraInventory, via /etc/oraInst.loc.)
fmw_inventory="$ORACLE_ROOT/fmwInventory"
old_inventory=$(sed -n 's/^inventory_loc=//p' "$MW_HOME/oraInst.loc")
if [ "$old_inventory" != "$fmw_inventory" ] && [ -d "$old_inventory" ]; then
    log "Moving the FMW inventory from $old_inventory to $fmw_inventory"
    mv "$old_inventory" "$fmw_inventory"
    sed -i "s|^inventory_loc=.*|inventory_loc=$fmw_inventory|" "$MW_HOME/oraInst.loc"
fi

# The EPM home's OPatch (11.1.0.9, which ApplyUpdate never upgrades) fails every EPM
# product patch with "not able to find the Middleware Home's directory .../utils to
# configure OCM" unless this exists. This install doesn't create it; empty is enough.
runuser -u oracle -- mkdir -p "$MW_HOME/utils"

# ApplyUpdate.sh reads configureLinux.properties from the working directory, and it
# uses bash arrays despite its #!/bin/sh.
log "Running ApplyUpdate.sh $MW_HOME as oracle"
runuser -u oracle -- bash -c "cd '$update' && bash ./ApplyUpdate.sh '$MW_HOME'"

log "Summary log:"
cat "$summary"

# The EPM home's OPatch predates lspatches.
log "EPM patches:"
runuser -u oracle -- env JAVA_HOME="$MW_HOME/jdk" "$EPM_ORACLE_HOME/OPatch/opatch" lsinventory \
    -oh "$EPM_ORACLE_HOME" -jdk "$MW_HOME/jdk" | grep -E '^Patch +[0-9]' || true
log "FMW patches:"
runuser -u oracle -- env JAVA_HOME="$MW_HOME/jdk" "$MW_HOME/OPatch/opatch" lspatches -oh "$MW_HOME" || true
"$MW_HOME/jdk/bin/java" -version

# "already installed" is expected: the WebLogic stack patch bundle carries some of the
# same fixes as the individual FMW patches. Anything else is a real failure.
failed=0
if grep -E ' (ERROR|FATAL) ' "$summary"; then
    failed=1
fi
if grep -E 'Failed to apply' "$summary" | grep -v -E 'already installed in the Oracle Home'; then
    failed=1
fi
if [ $failed -ne 0 ]; then
    echo "ApplyUpdate reported failures (above). Detail logs:" \
         "$EPM_ORACLE_HOME/diagnostics/logs/install/ApplyUpdateDetail-*.log" >&2
    exit 1
fi

# Only a rollback needs these: the extracted patches, OPatch's own backups and the
# patch storage directories.
rm -rf "$work" \
    "$MW_HOME/oracle_common/OPatch/Patches/patchFiles_$release" \
    "$MW_HOME/inventory.bak" "$MW_HOME/oui.bak" "$MW_HOME/OPatch.bak" \
    "$MW_HOME/.patch_storage" "$EPM_ORACLE_HOME/.patch_storage" \
    "$MW_HOME/cfgtoollogs/opatch" "$EPM_ORACLE_HOME/cfgtoollogs/opatch"
log "Update to $release complete"
