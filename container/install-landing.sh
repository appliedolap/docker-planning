#!/bin/bash
#
# Installs the launcher page (landing/index.html) at the root of port 9000.
#
# The root path belongs to EPM's embedded web proxy (the proxyservlet app, context root
# "/"), which the configurator's web server task generates. It can't be replaced: it
# forwards /essbase and /eas on port 9000 to Essbase and EAS. But it has no welcome page,
# so "/" was a 404, and WebLogic serves an index.html in it by default. The app is
# deployed with staging mode external_stage, so EPMServer0 serves its own staged copy
# rather than the source; the page goes into both, and a running server only sees it
# after the app is redeployed.
#
#   install-landing.sh             install the page if it's missing or out of date
#   install-landing.sh --redeploy  ...and redeploy the proxy if anything changed (needs
#                                  the Admin Server running; takes about 10 seconds)
#
# Idempotent; nothing changes and nothing is redeployed when the page is current.

set -euo pipefail
source /home/oracle/container/common.sh

redeploy=false
[ "${1:-}" = "--redeploy" ] && redeploy=true

page="$CONTAINER_DIR/landing/index.html"
proxy_source="$EPM_ORACLE_INSTANCE/httpConfig/EmbeddedWeblogicHttpServer/proxyservlet"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT
sed -e "s|__EPM_HOST__|$(hostname -f)|g" \
    -e "s|__SQL_HOST_PORT__|${MSSQL_HOST_PORT:-21433}|g" \
    "$page" > "$rendered"

changed=false
targets=("$proxy_source")
for staged in "$EPM_DOMAIN_HOME"/servers/EPMServer0/stage/proxyservlet/*/proxyservlet; do
    [ -d "$staged" ] && targets+=("$staged")
done
for dir in "${targets[@]}"; do
    if [ ! -d "$dir" ]; then
        log "WARNING: no proxy app at $dir; launcher page not installed there"
        continue
    fi
    if ! cmp -s "$rendered" "$dir/index.html"; then
        cp "$rendered" "$dir/index.html"
        chmod 644 "$dir/index.html"
        changed=true
        log "Launcher page installed in $dir"
    fi
done

if [ "$changed" = "true" ] && [ "$redeploy" = "true" ]; then
    port_is_listening 7001 || fail "The Admin Server isn't running; can't redeploy the proxy"
    log "Redeploying the web proxy so the launcher page is served"
    # setWLSEnv.sh references unset variables, so it can't be sourced under set -u.
    set +u
    # shellcheck disable=SC1091
    source "$MW_HOME/wlserver/server/bin/setWLSEnv.sh" > /dev/null
    set -u
    # The domain records the app as proxyservlet#<version>.
    app_version=$(grep -o -m1 'proxyservlet#[^<]*' "$EPM_DOMAIN_HOME/config/config.xml" | cut -d'#' -f2)
    [ -n "$app_version" ] || fail "Couldn't find the proxyservlet deployment in the EPM domain's config.xml"
    java weblogic.Deployer -adminurl t3://localhost:7001 \
        -user "$WLS_ADMIN_USER" -password "$WLS_ADMIN_PASSWORD" \
        -redeploy -name proxyservlet -appversion "$app_version" 2>&1 \
        | grep -E 'completed|failed|Error' || true
fi
