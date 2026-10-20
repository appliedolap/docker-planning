#!/bin/bash
#
# Makes Essbase's ODBC configuration name its DataDirect 8.0.2 drivers by absolute path.
# Oracle's 11.2.26 Readme (known issues 39039397 and 39010704) says Essbase 21.8.1 needs
# this done by hand on SQL Server, and that without it creating the Vision sample
# application fails partway through.
#
# What a fresh 11.2.15 + 11.2.26 configuration actually produces differs from the
# Readme's upgrade-centred description (no 7.1.6 drivers are ever present):
#   - odbc.ini (essbase_datasource) names its driver by bare file name, ARsqls28.so;
#   - the 8.0.2 odbcinst.ini points every driver at /u01/app/dist/essbase/..., Oracle's
#     build-machine path.
# Both are fixed here. The Readme's 7.1.6 -> 8.0.2 rewrite is kept for upgraded homes.
# Idempotent; it logs the result and fails if a referenced driver doesn't exist.

set -euo pipefail
source /home/oracle/container/common.sh

odbc_ini="$ESSBASE_DOMAIN_HOME/config/fmwconfig/essconfig/core/odbc.ini"
odbc_home="$MW_HOME/essbase/modules/oracle.essbase.datadirect.odbc"
odbc_lib="$odbc_home/8.0.2/lib"
odbcinst_ini="$odbc_home/8.0.2/odbcinst.ini"

[ -d "$odbc_lib" ] || fail "No DataDirect 8.0.2 drivers at $odbc_lib; is the update applied?"
[ -f "$odbc_ini" ] || fail "No $odbc_ini; has Essbase been configured?"

cp -n "$odbc_ini" "$odbc_ini.orig"
sed -i \
    -e 's|oracle\.essbase\.datadirect\.odbc/7\.1\.6/lib/ARsqls27\.so|oracle.essbase.datadirect.odbc/8.0.2/lib/ARsqls28.so|g' \
    -e 's|oracle\.essbase\.datadirect\.odbc/7\.1\.6/lib/ARdb227\.so|oracle.essbase.datadirect.odbc/8.0.2/lib/ARdb228.so|g' \
    -e 's|oracle\.essbase\.datadirect\.odbc/7\.1\.6/lib/ARmysql27\.so|oracle.essbase.datadirect.odbc/8.0.2/lib/ARmysql28.so|g' \
    -e 's|Oracle 7\.1 SQL Server Wire Protocol|Oracle 8.0 SQL Server Wire Protocol|g' \
    -e "s|^Driver=\([^/][^/]*\.so\)\$|Driver=$odbc_lib/\1|" \
    "$odbc_ini"

if [ -f "$odbcinst_ini" ]; then
    cp -n "$odbcinst_ini" "$odbcinst_ini.orig"
    sed -i \
        -e "s|/u01/app/dist/essbase/|$MW_HOME/essbase/|g" \
        -e "s|\$ODBC_PATH|$odbc_home|g" \
        -e "s|<Oracle_HOME>|$MW_HOME|g" \
        "$odbcinst_ini"
else
    log "WARNING: no $odbcinst_ini"
fi

log "Essbase ODBC data source drivers ($odbc_ini):"
grep -E '^Driver=' "$odbc_ini"

missing=0
while IFS= read -r driver; do
    if [ ! -f "$driver" ]; then
        log "ERROR: driver not found: $driver"
        missing=1
    fi
done < <(grep -h -E '^Driver=' "$odbc_ini" "$odbcinst_ini" 2>/dev/null | cut -d= -f2- | sort -u)
[ $missing -eq 0 ] || fail "Some ODBC drivers named in the configuration don't exist (above)"

leftovers=$(grep -l -E '7\.1\.6|/u01/app/dist' "$odbc_ini" "$odbcinst_ini" 2>/dev/null || true)
if [ -n "$leftovers" ]; then
    log "WARNING: old driver references remain in: $leftovers"
fi
log "Essbase ODBC configuration fixed"
