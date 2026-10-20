#!/bin/bash
#
# Stops everything start-epm.sh started, in reverse. Best effort: a failure stopping one
# piece shouldn't stop the rest from being stopped.

source /home/oracle/container/common.sh

log "Stopping EPM services"
"$EPM_ORACLE_INSTANCE/bin/stop.sh" || log "WARNING: stop.sh failed"

if [ -x "$ESSBASE_DOMAIN_HOME/esstools/bin/stop.sh" ] && port_is_listening 1423; then
    log "Stopping Essbase"
    "$ESSBASE_DOMAIN_HOME/esstools/bin/stop.sh" || log "WARNING: Essbase stop.sh failed"
fi

if port_is_listening 7001; then
    log "Stopping the WebLogic Admin Server"
    "$EPM_DOMAIN_HOME/bin/stopWebLogic.sh" || log "WARNING: stopWebLogic.sh failed"
fi
log "Stopped"
