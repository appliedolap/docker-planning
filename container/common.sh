#!/bin/bash
#
# Settings and helpers shared by the container scripts. Every setting can be overridden
# from compose.yml; the defaults match it.
# shellcheck disable=SC2034  # variables here are used by the scripts that source this

: "${DB_HOST:=mssql}"
: "${DB_PORT:=1433}"
: "${DB_ADMIN_USER:=sa}"
: "${DB_ADMIN_PASSWORD:?DB_ADMIN_PASSWORD is required}"

# EPM repository (Shared Services registry, Calculation Manager, EAS, Planning system
# tables), the RCU database, and the first Planning application's database. compose's
# mssql-init service creates all three with the settings Oracle requires.
: "${EPM_DB:=EPM}"
: "${RCU_DB:=EPM_RCU}"
: "${PLANNING_APP_DB:=EPM_VISION}"

# RCU creates one set of FMW schemas for the EPM domain under RCU_PREFIX, and the
# configurator creates another for the Essbase domain under ESSBASE_RCU_PREFIX, both in
# RCU_DB. Prefixes: letters and digits, 12 at most, not starting with a digit.
: "${RCU_PREFIX:=EPM}"
: "${ESSBASE_RCU_PREFIX:=ESS}"
: "${RCU_SCHEMA_PASSWORD:=$DB_ADMIN_PASSWORD}"
# Oracle's install guide says "all AS Common Schemas except ODI and Essbase"; of those,
# User Messaging Service (UCSUMS) is Oracle-database-only (rcu -listComponents).
: "${RCU_COMPONENTS:=STB OPSS IAU IAU_APPEND IAU_VIEWER WLS MDS}"

: "${WLS_ADMIN_USER:=epm_admin}"
: "${WLS_ADMIN_PASSWORD:=$DB_ADMIN_PASSWORD}"
: "${EPM_ADMIN_USER:=admin}"
: "${EPM_ADMIN_PASSWORD:=$WLS_ADMIN_PASSWORD}"

# Silent mode may or may not need a display; Xvfb is cheap insurance until that's known.
: "${EPM_USE_XVFB:=true}"

CONTAINER_DIR=/home/oracle/container
# .configuring is written before first-time configuration starts and .configured when it
# finishes (with the host name it was done under), so a restart can tell a configured
# volume from a failed attempt.
CONFIGURING_MARKER="$ORACLE_ROOT/.configuring"
CONFIGURED_MARKER="$ORACLE_ROOT/.configured"
CONFIG_LOG_DIR="$ORACLE_ROOT/container-logs"
EPM_JAVA_HOME="$MW_HOME/jdk"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

# Runs a command under Xvfb when EPM_USE_XVFB is true.
with_display() {
    if [ "$EPM_USE_XVFB" = "true" ] && [ -z "${DISPLAY:-}" ]; then
        xvfb-run -a "$@"
    else
        "$@"
    fi
}

# Waits for a TCP port to accept connections: wait_for_port host port timeout-seconds
wait_for_port() {
    local host=$1 port=$2 timeout=$3 waited=0
    until (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

port_is_listening() {
    (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

# Oracle's password rules, which constrain each other. Checked up front because each
# one otherwise surfaces as a failure deep inside RCU or the configurator.
check_passwords() {
    local problems=()
    if [ ${#DB_ADMIN_PASSWORD} -gt 16 ]; then
        problems+=("DB_ADMIN_PASSWORD is used as RCU's sysDBAPassword: 16 characters at most")
    fi
    if [ ${#RCU_SCHEMA_PASSWORD} -gt 16 ] || ! [[ $RCU_SCHEMA_PASSWORD =~ ^[A-Za-z][A-Za-z0-9\$#_]*$ ]]; then
        problems+=("RCU_SCHEMA_PASSWORD: 16 characters at most, starting with a letter, specials only \$ # _")
    fi
    if [ ${#WLS_ADMIN_PASSWORD} -lt 8 ] || [ ${#WLS_ADMIN_PASSWORD} -gt 30 ] \
        || ! [[ $WLS_ADMIN_PASSWORD =~ ^[A-Za-z][A-Za-z0-9\$#_]*$ ]] || ! [[ $WLS_ADMIN_PASSWORD =~ [0-9] ]]; then
        problems+=("WLS_ADMIN_PASSWORD: 8-30 characters, starting with a letter, with a digit, specials only \$ # _")
    fi
    if [ ${#EPM_ADMIN_PASSWORD} -gt 16 ] || ! [[ $EPM_ADMIN_PASSWORD =~ [0-9] ]]; then
        problems+=("EPM_ADMIN_PASSWORD: 16 characters at most, with a digit")
    fi
    if [ ${#problems[@]} -gt 0 ]; then
        printf '  %s\n' "${problems[@]}" >&2
        fail "Passwords don't meet Oracle's rules (above)"
    fi
}
