#!/bin/bash
#
# Container entry point: configure on first start, start everything, run any LCM
# imports staged in ~/start_scripts on that first start, then follow the logs until
# the container is stopped.
#
# compose restarts this container (restart: unless-stopped), so it guards the two
# situations where starting again would only do damage: a first-time configuration that
# didn't finish (it can't be repeated over a partial attempt), and a configured volume
# started under a different host name (EPM recorded the old one). In both it idles with
# an explanation rather than exiting, so the restart policy doesn't loop on it.

set -euo pipefail
source /home/oracle/container/common.sh

# Logs why, then waits (healthcheck: unhealthy) until the container is stopped.
refuse() {
    log "ERROR: $*"
    log "Not starting EPM. The container stays up, doing nothing, so this message stays in its logs."
    trap 'exit 0' TERM INT
    sleep infinity &
    wait $!
    exit 0
}

fqdn=$(hostname -f)
first_start=false

if [ -f "$CONFIGURED_MARKER" ]; then
    configured_host=$(sed -n 's/^host=//p' "$CONFIGURED_MARKER")
    if [ -z "$configured_host" ]; then
        # A marker from before host names were recorded: the name hasn't changed since.
        printf 'host=%s\n' "$fqdn" >> "$CONFIGURED_MARKER"
    elif [ "$configured_host" != "$fqdn" ]; then
        refuse "EPM on this volume was configured as $configured_host, but this container is" \
               "$fqdn. EPM can't be renamed after configuration. Set EPM_HOSTNAME and EPM_DOMAIN" \
               "back, or run 'docker compose down -v' to configure afresh under the new name."
    fi
elif [ -f "$CONFIGURING_MARKER" ]; then
    refuse "First-time configuration began ($(tr '\n' ' ' < "$CONFIGURING_MARKER")) but never" \
           "finished, and it can't be repeated over a partial attempt. Logs:" \
           "$CONFIG_LOG_DIR and $EPM_ORACLE_INSTANCE/diagnostics/logs/config." \
           "Reset with 'docker compose down -v'."
else
    first_start=true
    printf 'started=%s\nhost=%s\n' "$(date)" "$fqdn" > "$CONFIGURING_MARKER"
    "$CONTAINER_DIR/configure.sh"
fi

shutdown() {
    log "Shutdown requested"
    "$CONTAINER_DIR/stop-epm.sh"
    exit 0
}
trap shutdown TERM INT

# After a Docker restart, compose's depends_on doesn't apply: SQL Server may still be
# coming up when this starts.
log "Waiting for SQL Server at $DB_HOST:$DB_PORT"
wait_for_port "$DB_HOST" "$DB_PORT" 600 || fail "SQL Server at $DB_HOST:$DB_PORT never came up"

"$CONTAINER_DIR/start-epm.sh"

# The launcher page at http://<host>:9000/. After start, because the proxy it lives in is
# only staged once EPMServer0 has started; it's redeployed only if the page changed.
"$CONTAINER_DIR/install-landing.sh" --redeploy || log "WARNING: the launcher page wasn't installed"

# LCM imports: any folder in ~/start_scripts holding an Import.xml, exported from
# Shared Services, as in the 11.1.2.4 image. The credentials in Import.xml are replaced
# with this container's admin user. A Planning application import needs its data source
# to exist first (see README.md).
if [ "$first_start" = "true" ] && [ -d /home/oracle/start_scripts ]; then
    for dir in /home/oracle/start_scripts/*/; do
        [ -f "$dir/Import.xml" ] || continue
        target="/tmp/$(basename "$dir")"
        log "LCM import of $dir"
        rm -rf "$target"
        cp -R "$dir" "$target"
        sed -i -e "s|<User .*/>|<User name=\"$EPM_ADMIN_USER\" password=\"$EPM_ADMIN_PASSWORD\"/>|" "$target/Import.xml"
        "$EPM_ORACLE_INSTANCE/bin/Utility.sh" "$target/Import.xml" || log "WARNING: LCM import of $dir failed"
    done
fi

log "EPM is up. Workspace: http://$fqdn:9000/workspace/"

# Run tail in the background so the trap can fire while we wait on it.
tail -F \
    "$EPM_DOMAIN_HOME/servers/EPMServer0/logs/EPMServer0.log" \
    "$ESSBASE_DOMAIN_HOME/servers/essbase_server1/logs/essbase_server1.log" &
wait $!
