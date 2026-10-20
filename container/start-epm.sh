#!/bin/bash
#
# Starts everything, in Oracle's documented order: the WebLogic Admin Server (which
# must be running the first time services start after configuration, and is kept
# running for its console), then all EPM services with the single start script. Essbase
# 21c has its own domain and start script; it's started here if EPM's script didn't.

set -euo pipefail
source /home/oracle/container/common.sh

mkdir -p "$CONFIG_LOG_DIR"

# Without boot.properties, startWebLogic.sh prompts for credentials, which no one is
# there to answer. WebLogic encrypts the values in place on the first boot that reads it.
boot_properties="$EPM_DOMAIN_HOME/servers/AdminServer/security/boot.properties"
if [ ! -f "$boot_properties" ]; then
    mkdir -p "$(dirname "$boot_properties")"
    printf 'username=%s\npassword=%s\n' "$WLS_ADMIN_USER" "$WLS_ADMIN_PASSWORD" > "$boot_properties"
    chmod 600 "$boot_properties"
fi

if port_is_listening 7001; then
    log "WebLogic Admin Server already running"
else
    log "Starting the WebLogic Admin Server"
    nohup "$EPM_DOMAIN_HOME/bin/startWebLogic.sh" > "$CONFIG_LOG_DIR/AdminServer.out" 2>&1 &
    wait_for_port 127.0.0.1 7001 900 || fail "The Admin Server didn't open port 7001; see $CONFIG_LOG_DIR/AdminServer.out"
    until grep -q 'Server state changed to RUNNING' "$CONFIG_LOG_DIR/AdminServer.out"; do
        sleep 5
    done
    log "WebLogic Admin Server is running"
fi

log "Starting EPM services ($EPM_ORACLE_INSTANCE/bin/start.sh)"
"$EPM_ORACLE_INSTANCE/bin/start.sh"

if port_is_listening 1423; then
    log "Essbase agent is listening on 1423"
else
    log "Starting Essbase ($ESSBASE_DOMAIN_HOME/esstools/bin/start.sh)"
    "$ESSBASE_DOMAIN_HOME/esstools/bin/start.sh"
fi
