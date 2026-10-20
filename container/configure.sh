#!/bin/bash
#
# First-start configuration: RCU, RCUSchema.properties, the EPM System Configurator in
# silent mode, then the Essbase ODBC fix. Run by entrypoint.sh when the configured
# marker is absent.
#
#   configure.sh                 everything
#   configure.sh --prepare-only  stop before the configurator (for recording its
#                                response file by hand; see recorder/README.md)
#
# None of this can be safely re-run over a partial attempt: RCU won't recreate an
# existing prefix, a reinstall can't reuse the Shared Services registry, and Essbase
# can't be reconfigured. After a failure, start over with `docker compose down -v`.

set -euo pipefail
source /home/oracle/container/common.sh

prepare_only=false
[ "${1:-}" = "--prepare-only" ] && prepare_only=true

config_dir="$EPM_ORACLE_HOME/common/config/11.1.2.0"
mkdir -p "$CONFIG_LOG_DIR"

check_hostname() {
    local fqdn
    fqdn=$(hostname -f 2>/dev/null || true)
    log "Host name: $(hostname), FQDN: ${fqdn:-<none>}"
    if [[ $fqdn != *.* ]]; then
        fail "The host name doesn't resolve to a fully qualified name. Set hostname and" \
             "domainname in compose.yml; EPM records this name and it can't change later."
    fi
    if [[ $fqdn == *_* ]]; then
        fail "EPM host names may contain only letters, digits, dashes and dots: $fqdn"
    fi
    # Oracle's own check of Java's canonical name resolution. It ships zipped.
    if [ ! -x "$config_dir/epmsys_hostname.sh" ] && [ -f "$config_dir/epmsys_hostname.zip" ]; then
        unzip -q -o "$config_dir/epmsys_hostname.zip" -d "$config_dir"
        chmod +x "$config_dir"/epmsys_hostname.sh 2>/dev/null || true
    fi
    if [ -x "$config_dir/epmsys_hostname.sh" ]; then
        (cd "$config_dir" && JAVA_HOME="$EPM_JAVA_HOME" ./epmsys_hostname.sh "$fqdn") || true
    fi
}

run_rcu() {
    local args=() component
    for component in $RCU_COMPONENTS; do
        args+=(-component "$component")
    done
    log "Creating RCU schemas with prefix $RCU_PREFIX in $RCU_DB ($RCU_COMPONENTS)"
    RCU_LOG_LOCATION="$CONFIG_LOG_DIR" \
    "$MW_HOME/oracle_common/bin/rcu" -silent -createRepository \
        -databaseType SQLSERVER \
        -connectString "$DB_HOST:$DB_PORT:$RCU_DB" \
        -dbUser "$DB_ADMIN_USER" \
        -unicodeSupport Yes \
        -useSamePasswordForAllSchemaUsers true \
        -schemaPrefix "$RCU_PREFIX" \
        "${args[@]}" \
        -f <<EOF
$DB_ADMIN_PASSWORD
$RCU_SCHEMA_PASSWORD
EOF
}

# Sets key=value in a properties file, replacing the key if present.
set_property() {
    local file=$1 key=$2 value=$3
    if grep -q "^$key=" "$file"; then
        # The value may contain sed metacharacters, so replace via awk instead.
        awk -v k="$key" -v v="$value" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' \
            "$file" > "$file.tmp" && mv "$file.tmp" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

write_rcu_properties() {
    local file="$config_dir/RCUSchema.properties"
    log "Writing $file"
    touch "$file"
    set_property "$file" sysDBAUser "$DB_ADMIN_USER"
    set_property "$file" sysDBAPassword "$DB_ADMIN_PASSWORD"
    set_property "$file" schemaPrefix "$RCU_PREFIX"
    set_property "$file" rcuSchemaPassword "$RCU_SCHEMA_PASSWORD"
    set_property "$file" dbURL "jdbc:weblogic:sqlserver://$DB_HOST:$DB_PORT;databaseName=$RCU_DB"
    # The configurator creates the Essbase domain's RCU schemas itself from these two.
    set_property "$file" schemaPrefixEssbase "$ESSBASE_RCU_PREFIX"
    set_property "$file" dbURLEssbase "$DB_HOST:$DB_PORT:$RCU_DB"
}

render_response() {
    local template=$1 out=$2 fqdn
    fqdn=$(hostname -f)
    # Passwords go in as clear text inside encrypt="true" properties; the configurator
    # encrypts them in place, which is why the rendered copy is written, not piped.
    sed -e "s|__MW_HOME__|$MW_HOME|g" \
        -e "s|__EPM_ORACLE_INSTANCE__|$EPM_ORACLE_INSTANCE|g" \
        -e "s|__HOST__|$fqdn|g" \
        -e "s|__DB_HOST__|$DB_HOST|g" \
        -e "s|__DB_PORT__|$DB_PORT|g" \
        -e "s|__DB_USER__|$DB_ADMIN_USER|g" \
        -e "s|__DB_PASSWORD__|$DB_ADMIN_PASSWORD|g" \
        -e "s|__EPM_DB__|$EPM_DB|g" \
        -e "s|__WLS_ADMIN_USER__|$WLS_ADMIN_USER|g" \
        -e "s|__WLS_ADMIN_PASSWORD__|$WLS_ADMIN_PASSWORD|g" \
        -e "s|__EPM_ADMIN_USER__|$EPM_ADMIN_USER|g" \
        -e "s|__EPM_ADMIN_PASSWORD__|$EPM_ADMIN_PASSWORD|g" \
        "$template" > "$out"
    if grep -q '__[A-Z_]*__' "$out"; then
        fail "Unreplaced placeholders in $template: $(grep -o '__[A-Z_]*__' "$out" | sort -u | tr '\n' ' ')"
    fi
}

# Runs the configurator silently on one template: run_configtool <template> <label>.
# The summary log accumulates across runs, so only the lines this run adds are judged.
run_configtool() {
    local template=$1 label=$2 before=0
    local response="$CONFIG_LOG_DIR/response-$label.xml"
    local summary="$EPM_ORACLE_INSTANCE/diagnostics/logs/config/configtool_summary.log"
    [ -f "$template" ] || fail "$template is missing; see recorder/README.md"
    render_response "$template" "$response"
    [ -f "$summary" ] && before=$(wc -l < "$summary")

    log "Running the EPM System Configurator silently: $label"
    with_display "$config_dir/configtool.sh" -silent "$response"
    rm -f "$response"

    [ -f "$summary" ] || fail "No configurator summary log; check $EPM_ORACLE_INSTANCE/diagnostics/logs/config"
    log "Configurator summary ($label):"
    tail -n +$((before + 1)) "$summary"
    if tail -n +$((before + 1)) "$summary" | grep -q -E '\): Fail '; then
        fail "The configurator reported failures ($label, above)"
    fi
}

# The Essbase 21c configuration registers its Provider Services web app without the
# "context" property every other web app has (its logical entry says "essbase"). The
# web server task reads that property for every web app and dies with a
# NullPointerException when it's missing, which leaves Workspace unusable. Add it.
fix_provider_services_context() {
    local registry="$EPM_ORACLE_INSTANCE/bin/epmsys_registry.sh"
    if "$registry" view PROVIDER_SERVICES_WEB_APP 2>/dev/null | grep -q -E '^\s+context = '; then
        log "Provider Services already has a registry context"
        return 0
    fi
    log "Adding the missing Provider Services context (essbase) to the registry"
    "$registry" addproperty PROVIDER_SERVICES_WEB_APP/@context essbase
    "$registry" view PROVIDER_SERVICES_WEB_APP | grep -q -E '^\s+context = essbase' \
        || fail "Couldn't add the Provider Services context to the registry"
}

log "Configuring EPM for the first time"
check_passwords
check_hostname

log "Waiting for SQL Server at $DB_HOST:$DB_PORT"
wait_for_port "$DB_HOST" "$DB_PORT" 600 || fail "SQL Server at $DB_HOST:$DB_PORT never came up"

run_rcu
write_rcu_properties

if [ "$prepare_only" = "true" ]; then
    log "Prepared (RCU schemas, RCUSchema.properties). Run the configurator by hand now."
    exit 0
fi

run_configtool "$CONTAINER_DIR/config-response.xml" products
fix_provider_services_context
run_configtool "$CONTAINER_DIR/webserver-response.xml" webserver
"$CONTAINER_DIR/fix-essbase-odbc.sh"

printf 'configured=%s\nhost=%s\n' "$(date)" "$(hostname -f)" > "$CONFIGURED_MARKER"
rm -f "$CONFIGURING_MARKER"
log "Configuration complete"
