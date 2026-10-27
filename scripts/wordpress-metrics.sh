#!/bin/bash
#
# wordpress-metrics.sh
# Collects WordPress + Cloudflare metrics for every OpenLiteSpeed vhost and
# writes one JSON report per site into $DATA_DIR for the PHP dashboard.
#
# Usage:
#   wordpress-metrics.sh               # all vhosts
#   wordpress-metrics.sh site1 site2   # only the named vhosts
#
# Credentials (~/.site-setup/creds), either:
#   cf_token="..."                      # preferred: scoped API token, all READ permissions:
#                                       #   Zone, Zone Settings, Zone WAF, Firewall Services, SSL and Certificates,
#                                       #   Cache Rules, Config Rules, Transform Rules, Dynamic URL Redirects,
#                                       #   Origin Rules, Page Rules, Bot Management, DNS (for DNSSEC), Email Routing Rules
# or
#   cf_email="..." ; cf_key="..."       # legacy Global API key

set -uo pipefail

SCRIPT_VERSION="2.2.0"
SCHEMA_VERSION=2

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"   # OpenLiteSpeed vhost configs
DATA_DIR="/nas/wp-metrics-test1"                 # where JSON reports are written
WP_CLI="/usr/local/bin/wp"                       # WP-CLI executable
CREDS_FILE="$HOME/.site-setup/creds"
LOCK_FILE="/var/lock/wordpress-metrics.lock"
WP_TIMEOUT=300                                   # seconds per WP-CLI call
CF_TIMEOUT=20                                    # seconds per Cloudflare API call
COLLECT_DISK_USAGE=1                             # set 0 to skip `du` on large sites
DISK_TIMEOUT=120

CF_DELAY=0.15                                    # pause between Cloudflare calls (API limit: 1200 req / 5 min)

# All zone settings come from one bulk call. These are fetched individually
# only if the bulk response doesn't include them.
CF_EXTRA_SETTINGS=(
    speed_brain automatic_platform_optimization fonts early_hints
    h2_prioritization image_resizing origin_max_http_version
)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }

for cmd in jq curl sudo flock timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -x "$WP_CLI" ]]; then
    echo "ERROR: WP-CLI not found at $WP_CLI" >&2
    exit 1
fi

# Prevent overlapping runs (e.g. cron firing while a long run is still going)
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "Another run is already in progress ($LOCK_FILE). Exiting."
    exit 0
fi

cf_token="" cf_email="" cf_key=""
if [[ -f "$CREDS_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CREDS_FILE"
else
    warn "Credentials file $CREDS_FILE not found - Cloudflare data will be skipped."
fi

CF_AUTH=()
if [[ -n "${cf_token:-}" ]]; then
    CF_AUTH=(-H "Authorization: Bearer $cf_token")
elif [[ -n "${cf_email:-}" && -n "${cf_key:-}" ]]; then
    CF_AUTH=(-H "X-Auth-Email: $cf_email" -H "X-Auth-Key: $cf_key")
else
    warn "No Cloudflare credentials set - Cloudflare data will be skipped."
fi

install -d -o root -g nogroup -m 0750 "$DATA_DIR"

ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT

# Cloudflare GET helper: prints the response body, returns non-zero on failure
cf_get() {
    local path="$1"
    sleep "$CF_DELAY"
    curl -sS --max-time "$CF_TIMEOUT" --retry 2 --retry-delay 2 \
        -H "Content-Type: application/json" "${CF_AUTH[@]}" \
        "https://api.cloudflare.com/client/v4/$path"
}

# Build list of candidate zone names: www.blog.example.co.uk -> blog.example.co.uk, example.co.uk, co.uk(stops at 2 labels)
zone_candidates() {
    local name="${1#www.}"
    while [[ "$name" == *.* ]]; do
        echo "$name"
        name="${name#*.}"
    done
}

# --- Cloudflare result store (a per-site JSON file, avoids argument-size limits) ---
# cf_store KEY      : read JSON from stdin, set it at dotted KEY in $CF_FILE
# cf_append KEY     : read JSON from stdin, append it to the array at KEY
cf_store() {
    jq -c --arg k "$1" --slurpfile v /dev/stdin 'setpath($k | split("."); $v[0])' "$CF_FILE" > "$CF_FILE.tmp" \
        && mv -f "$CF_FILE.tmp" "$CF_FILE"
}
cf_append() {
    jq -c --arg k "$1" --slurpfile v /dev/stdin \
        '($k | split(".")) as $p | setpath($p; (getpath($p) // []) + $v)' "$CF_FILE" > "$CF_FILE.tmp" \
        && mv -f "$CF_FILE.tmp" "$CF_FILE"
}
cf_err_msg() {
    jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ") | if . == "" then "invalid response" else . end' \
        <<< "$1" 2>/dev/null || echo "invalid response"
}
cf_fetch_error() {
    jq -nc --arg m "$1" '$m' | cf_append fetch_errors
}
# cf_collect KEY PATH [JQ_FILTER] [quiet]
# GETs PATH, applies JQ_FILTER to .result and stores it at KEY.
# Failures are recorded in cloudflare.fetch_errors (unless "quiet": endpoints that
# are commonly unavailable on lower plans or with limited token permissions).
cf_collect() {
    local key="$1" path="$2" filter="${3:-.}" quiet="${4:-}" resp
    if ! resp=$(cf_get "$path"); then
        cf_fetch_error "$key: request failed"
        return 1
    fi
    if jq -e '.success == true' <<< "$resp" >/dev/null 2>&1; then
        jq -c ".result | $filter" <<< "$resp" | cf_store "$key"
        return 0
    fi
    [[ -z "$quiet" ]] && cf_fetch_error "$key: $(cf_err_msg "$resp")"
    return 1
}

# Best-effort detection of what's installed in a folder
detect_cms() {
    local d="$1"
    if   [[ -f "$d/wp-config.php" || -f "$d/wp-load.php" ]];                         then echo "WordPress"
    elif [[ -f "$d/configuration.php" && -d "$d/administrator" ]];                   then echo "Joomla"
    elif [[ -f "$d/core/lib/Drupal.php" || -f "$d/sites/default/settings.php" ]];    then echo "Drupal"
    elif [[ -f "$d/app/etc/env.php" ]];                                              then echo "Magento"
    elif [[ -f "$d/config/settings.inc.php" || -f "$d/app/config/parameters.php" ]]; then echo "PrestaShop"
    elif [[ -f "$d/config.php" && -d "$d/admin" && -d "$d/catalog" ]];               then echo "OpenCart"
    elif [[ -f "$d/artisan" ]];                                                      then echo "Laravel"
    elif [[ -f "$d/index.php" ]];                                                    then echo "PHP"
    elif [[ -f "$d/index.html" || -f "$d/index.htm" ]];                              then echo "Static HTML"
    fi
}

# PHP evaluated inside each WordPress install for environment/health details.
# Output is prefixed with a marker so stray plugin output can't break the JSON.
read -r -d '' WP_ENV_PHP <<'PHP'
global $wpdb;
$users = count_users();
$autoload = $wpdb->get_var("SELECT SUM(LENGTH(option_value)) FROM {$wpdb->options} WHERE autoload IN ('yes','on','auto-on','auto')");
$cron = _get_cron_array();
$overdue = 0;
if (is_array($cron)) { foreach ($cron as $ts => $hooks) { if ($ts < time() - 3600) { $overdue += count($hooks); } } }
echo "\n__WPM__" . wp_json_encode(array(
    'php_version'        => PHP_VERSION,
    'mysql_version'      => $wpdb->db_version(),
    'siteurl'            => get_option('siteurl'),
    'home'               => get_option('home'),
    'is_multisite'       => is_multisite(),
    'blog_public'        => (bool) get_option('blog_public'),
    'wp_debug'           => defined('WP_DEBUG') && WP_DEBUG,
    'wp_debug_display'   => defined('WP_DEBUG') && WP_DEBUG && (!defined('WP_DEBUG_DISPLAY') || WP_DEBUG_DISPLAY),
    'disallow_file_edit' => defined('DISALLOW_FILE_EDIT') && DISALLOW_FILE_EDIT,
    'disable_wp_cron'    => defined('DISABLE_WP_CRON') && DISABLE_WP_CRON,
    'auto_update_core'   => defined('WP_AUTO_UPDATE_CORE') ? WP_AUTO_UPDATE_CORE : null,
    'memory_limit'       => defined('WP_MEMORY_LIMIT') ? WP_MEMORY_LIMIT : null,
    'users_total'        => (int) $users['total_users'],
    'admins'             => (int) (isset($users['avail_roles']['administrator']) ? $users['avail_roles']['administrator'] : 0),
    'autoload_bytes'     => (int) $autoload,
    'cron_overdue'       => $overdue,
    'table_prefix'       => $wpdb->prefix,
));
PHP

# ---------------------------------------------------------------------------
# Per-site collection
# ---------------------------------------------------------------------------
collect_site() {
    local VHOST_DIR="$1"
    local VHOST="${VHOST_DIR##*/}"
    local VHCONF_FILE="$VHOST_DIR/vhconf.conf"
    local WEB_ROOT="/home/$VHOST/public_html"
    local ERRORS="[]"
    local PRIMARY_DOMAIN="" DOMAIN ALIASES="[]"

    add_error() { ERRORS=$(jq -c --arg m "$1" '. + [$m]' <<< "$ERRORS"); warn "$VHOST: $1"; }

    if [[ ! -f "$WEB_ROOT/wp-config.php" ]]; then
        log "Skipping non-WordPress vhost: $VHOST"
        return 0
    fi

    # Domain from vhAliases (first entry), fallback to vhost name
    local VH_ALIAS_LINE
    VH_ALIAS_LINE=$(grep -E '^\s*vhAliases\s+' "$VHCONF_FILE" | head -n 1)
    if [[ -n "$VH_ALIAS_LINE" ]]; then
        ALIASES=$(sed -E 's/^[[:space:]]*vhAliases[[:space:]]+//' <<< "$VH_ALIAS_LINE" \
            | tr ',' '\n' | tr -d ' \t"\r' | grep -v -e '^$' -e '^\*$' -e '\$' \
            | jq -R . | jq -sc .)
        PRIMARY_DOMAIN=$(jq -r '.[0] // empty' <<< "$ALIASES")
    fi
    DOMAIN="${PRIMARY_DOMAIN:-$VHOST}"
    DOMAIN="${DOMAIN#www.}"

    log "Collecting $DOMAIN (vhost: $VHOST)"

    wp() {
        timeout "$WP_TIMEOUT" sudo -u "$VHOST" "$WP_CLI" \
            --path="$WEB_ROOT" --no-color --quiet "$@" 2>"$ERR_FILE"
    }
    last_err() { head -c 300 "$ERR_FILE" | tr '\n' ' '; }

    # --- Core ---
    local CORE_VERSION CORE_STATUS="ok" CORE_UPDATES CORE_CHECKSUMS="unknown"
    if ! CORE_VERSION=$(wp core version); then
        add_error "core version failed: $(last_err)"
        CORE_VERSION=""
    fi

    CORE_UPDATES=$(wp core check-update --format=json) || { CORE_STATUS="error"; add_error "core check-update failed: $(last_err)"; }
    [[ -z "$CORE_UPDATES" ]] && CORE_UPDATES="[]"
    if ! jq -e 'type == "array"' <<< "$CORE_UPDATES" >/dev/null 2>&1; then
        CORE_STATUS="error"; CORE_UPDATES="[]"
    fi

    # Core file integrity (detects modified/injected core files)
    if wp core verify-checksums >/dev/null; then
        CORE_CHECKSUMS="ok"
    else
        CORE_CHECKSUMS="failed"
    fi

    # --- Plugins / themes ---
    local PLUGINS THEMES
    PLUGINS=$(wp plugin list --format=json --fields=name,title,status,update,version,update_version,auto_update) || { add_error "plugin list failed: $(last_err)"; PLUGINS="[]"; }
    jq -e 'type == "array"' <<< "$PLUGINS" >/dev/null 2>&1 || { add_error "plugin list returned invalid JSON"; PLUGINS="[]"; }

    THEMES=$(wp theme list --format=json --fields=name,title,status,update,version,update_version,auto_update) || { add_error "theme list failed: $(last_err)"; THEMES="[]"; }
    jq -e 'type == "array"' <<< "$THEMES" >/dev/null 2>&1 || { add_error "theme list returned invalid JSON"; THEMES="[]"; }

    # --- Environment / health ---
    local ENV_JSON="{}" ENV_RAW
    if ENV_RAW=$(wp eval "$WP_ENV_PHP"); then
        ENV_JSON=$(grep -o '__WPM__.*' <<< "$ENV_RAW" | tail -n 1 | sed 's/^__WPM__//')
        jq -e 'type == "object"' <<< "$ENV_JSON" >/dev/null 2>&1 || { add_error "environment JSON invalid"; ENV_JSON="{}"; }
    else
        add_error "environment eval failed: $(last_err)"
    fi

    local DISK_BYTES="null" UPLOADS_BYTES="null"
    if [[ "$COLLECT_DISK_USAGE" == "1" ]]; then
        DISK_BYTES=$(timeout "$DISK_TIMEOUT" du -sb "$WEB_ROOT" 2>/dev/null | cut -f1)
        UPLOADS_BYTES=$(timeout "$DISK_TIMEOUT" du -sb "$WEB_ROOT/wp-content/uploads" 2>/dev/null | cut -f1)
        [[ "$DISK_BYTES" =~ ^[0-9]+$ ]] || DISK_BYTES="null"
        [[ "$UPLOADS_BYTES" =~ ^[0-9]+$ ]] || UPLOADS_BYTES="null"
    fi

    # --- Drop-ins ---
    local DROPINS="[]" NAME FILE SIZE
    for NAME in advanced-cache.php object-cache.php db.php db-error.php install.php \
                maintenance.php php-error.php fatal-error-handler.php sunrise.php; do
        FILE="$WEB_ROOT/wp-content/$NAME"
        if [[ -f "$FILE" ]]; then
            SIZE=$(stat -c '%s' "$FILE")
            DROPINS=$(jq -c --arg name "$NAME" --argjson size "$SIZE" \
                '. + [{name: $name, status: "dropin", exists: true, size_bytes: $size}]' <<< "$DROPINS")
        fi
    done

    # --- Document root: top-level folders with permissions + key files ---
    local DOCROOT_FOLDERS="[]" DOCROOT_FILES="[]" LINE D_NAME D_TYPE D_PATH D_CMS D_VER P
    DOCROOT_FOLDERS=$(
        find "$WEB_ROOT" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) \
            -printf '%f\t%m\t%M\t%u\t%g\t%TY-%Tm-%TdT%TH:%TM\t%y\t%l\n' 2>/dev/null | sort |
        while IFS= read -r LINE; do
            D_NAME="${LINE%%$'\t'*}"
            D_PATH="$WEB_ROOT/$D_NAME"
            D_CMS="" D_VER=""
            if [[ -d "$D_PATH" ]]; then
                D_CMS=$(detect_cms "$D_PATH")
                if [[ "$D_CMS" == "WordPress" && -f "$D_PATH/wp-includes/version.php" ]]; then
                    D_VER=$(grep -oP "^\\\$wp_version\s*=\s*'\K[^']+" "$D_PATH/wp-includes/version.php" 2>/dev/null | head -n 1)
                fi
            fi
            printf '%s\t%s\t%s\n' "$LINE" "$D_CMS" "$D_VER"
        done |
        jq -R -s -c '
            def nz: if . == "" or . == null then null else . end;
            split("\n") | map(select(length > 0) | split("\t") | {
                name: .[0], mode: .[1], perms: .[2], owner: .[3], group: .[4], modified: .[5],
                type: (if .[6] == "l" then "symlink" else "dir" end),
                target: (.[7] | nz), cms: (.[8] | nz), version: (.[9] | nz),
                wp_core: (.[0] | IN("wp-admin", "wp-includes", "wp-content"))
            })'
    ) || DOCROOT_FOLDERS="[]"
    [[ -n "$DOCROOT_FOLDERS" ]] || DOCROOT_FOLDERS="[]"

    for P in "" wp-config.php .htaccess index.php wp-content/uploads; do
        [[ -e "$WEB_ROOT/$P" ]] || continue
        DOCROOT_FILES=$(jq -c --arg name "${P:-.}" \
            --arg info "$(stat -c '%a|%A|%U|%G|%y' "$WEB_ROOT/$P" 2>/dev/null)" \
            '. + [($info | split("|")) as $i | {name: $name, mode: $i[0], perms: $i[1], owner: $i[2], group: $i[3], modified: ($i[4] // "" | .[0:16] | sub(" "; "T"))}]' \
            <<< "$DOCROOT_FILES")
    done

    # --- Cloudflare ---
    local CF_PLAN="none" CF_ZONE_ID="" CF_ZONE_NAME="" CF_STATUS="inactive" CF_PAUSED="false"
    local CF_NS="[]" CANDIDATE RESP CF_FILE
    CF_FILE=$(mktemp)
    echo '{}' > "$CF_FILE"
    if [[ ${#CF_AUTH[@]} -gt 0 ]]; then
        while read -r CANDIDATE; do
            RESP=$(cf_get "zones?name=$CANDIDATE") || { add_error "Cloudflare zone lookup request failed"; break; }
            if jq -e '.success == true and (.result | length) > 0' <<< "$RESP" >/dev/null 2>&1; then
                CF_ZONE_ID=$(jq -r '.result[0].id' <<< "$RESP")
                CF_ZONE_NAME=$(jq -r '.result[0].name' <<< "$RESP")
                CF_STATUS=$(jq -r '.result[0].status // "unknown"' <<< "$RESP")
                CF_PAUSED=$(jq -r '.result[0].paused // false' <<< "$RESP")
                CF_PLAN=$(jq -r '.result[0].plan.name // "Free"' <<< "$RESP" | awk '{print $1}')
                CF_NS=$(jq -c '.result[0].name_servers // []' <<< "$RESP")
                break
            elif jq -e '.success == false' <<< "$RESP" >/dev/null 2>&1; then
                add_error "Cloudflare API: $(jq -r '[.errors[]?.message] | join("; ")' <<< "$RESP")"
                break
            fi
        done < <(zone_candidates "$DOMAIN")

        if [[ -n "$CF_ZONE_ID" ]]; then
            local Z="zones/$CF_ZONE_ID" S RID
            log "  Cloudflare zone $CF_ZONE_NAME ($CF_PLAN) - collecting configuration"

            # --- Zone settings: one bulk call, then individual calls for any missing ---
            cf_collect settings "$Z/settings" '[.[] | {key: .id, value: .value}] | from_entries'
            for S in "${CF_EXTRA_SETTINGS[@]}"; do
                if jq -e --arg k "$S" '(.settings // {})[$k] == null' "$CF_FILE" >/dev/null; then
                    cf_collect "settings.$S" "$Z/settings/$S" '.value' quiet
                fi
            done
            cf_collect settings.email_routing "$Z/email/routing" '.enabled // false'

            # --- SSL/TLS ---
            cf_collect ssl.universal_ssl              "$Z/ssl/universal/settings"          '.enabled'
            cf_collect ssl.certificate_packs          "$Z/ssl/certificate_packs?status=all" \
                '[.[] | {id, type, status, hosts, certificate_authority, validity_days, validation_method,
                         expires_on: ([.certificates[]?.expires_on | select(. != null)] | min)}]'
            cf_collect ssl.dnssec                     "$Z/dnssec"                          '.status'
            cf_collect ssl.authenticated_origin_pulls "$Z/origin_tls_client_auth/settings" '.enabled'
            cf_collect ssl.total_tls                  "$Z/acm/total_tls"                   '{enabled, certificate_authority}' quiet

            # --- Cache ---
            cf_collect cache.tiered_caching           "$Z/argo/tiered_caching"                     '.value'
            cf_collect cache.smart_tiered_cache       "$Z/cache/tiered_cache_smart_topology_enable" '.value' quiet
            cf_collect cache.regional_tiered_cache    "$Z/cache/regional_tiered_cache"             '.value' quiet
            cf_collect cache.cache_reserve            "$Z/cache/cache_reserve"                     '.value' quiet

            # --- Speed ---
            cf_collect speed.argo_smart_routing       "$Z/argo/smart_routing" '.value' quiet

            # --- WAF / security ---
            cf_collect security.bot_management        "$Z/bot_management" '.'
            cf_collect security.leaked_credential_checks "$Z/leaked-credential-checks" '.enabled' quiet
            cf_collect security.ip_access_rules       "$Z/firewall/access_rules/rules?per_page=100" \
                '[.[] | {mode, target: .configuration.target, value: .configuration.value, notes, scope: .scope.type}]'
            cf_collect security.zone_lockdowns        "$Z/firewall/lockdowns?per_page=100" \
                '[.[] | {description, paused, urls, configurations}]' quiet
            cf_collect security.ua_rules              "$Z/firewall/ua_rules?per_page=100" \
                '[.[] | {description, mode, paused, value: .configuration.value}]' quiet

            # --- Legacy page rules ---
            cf_collect page_rules "$Z/pagerules" \
                '[.[] | {status, priority, target: (.targets[0].constraint.value // ""), actions: [.actions[] | {id, value}]}]'

            # --- Rulesets: WAF custom/managed/rate limiting, cache, redirect, transform, config, origin... ---
            echo '[]' | cf_store rulesets
            RESP=$(cf_get "$Z/rulesets")
            if jq -e '.success == true' <<< "$RESP" >/dev/null 2>&1; then
                jq -c '[.result[] | {key: .id, value: .name}] | from_entries' <<< "$RESP" | cf_store ruleset_names
                for RID in $(jq -r '.result[] | select(.kind == "zone") | .id' <<< "$RESP"); do
                    cf_collect "_ruleset" "$Z/rulesets/$RID" \
                        '{id, name, phase, last_updated,
                          rules: [(.rules // [])[] | {id, description: (.description // ""), expression, action,
                                   enabled, action_parameters, ratelimit, logging, last_updated}
                                  | with_entries(select(.value != null))]}' \
                    && jq -c '._ruleset' "$CF_FILE" | cf_append rulesets
                done
                jq -c 'del(._ruleset)' "$CF_FILE" > "$CF_FILE.tmp" && mv -f "$CF_FILE.tmp" "$CF_FILE"
            else
                cf_fetch_error "rulesets: $(cf_err_msg "$RESP")"
            fi
        fi
    fi

    # --- Build report ---
    local REPORT
    REPORT=$(jq -n \
        --arg site "$VHOST" \
        --arg domain "$DOMAIN" \
        --argjson aliases "$ALIASES" \
        --arg path "$WEB_ROOT" \
        --arg collected "$(date --iso-8601=seconds)" \
        --arg script_version "$SCRIPT_VERSION" \
        --argjson schema "$SCHEMA_VERSION" \
        --arg core_version "$CORE_VERSION" \
        --arg core_status "$CORE_STATUS" \
        --arg core_checksums "$CORE_CHECKSUMS" \
        --argjson core_updates "$CORE_UPDATES" \
        --argjson plugins "$PLUGINS" \
        --argjson themes "$THEMES" \
        --argjson dropins "$DROPINS" \
        --argjson docroot_folders "$DOCROOT_FOLDERS" \
        --argjson docroot_files "$DOCROOT_FILES" \
        --argjson env "$ENV_JSON" \
        --argjson disk "$DISK_BYTES" \
        --argjson uploads "$UPLOADS_BYTES" \
        --arg cf_zone_id "$CF_ZONE_ID" \
        --arg cf_zone_name "$CF_ZONE_NAME" \
        --arg cf_status "$CF_STATUS" \
        --argjson cf_paused "$CF_PAUSED" \
        --arg cf_plan "$CF_PLAN" \
        --argjson cf_ns "$CF_NS" \
        --slurpfile cfx "$CF_FILE" \
        --argjson errors "$ERRORS" \
        '
        def regular: [.[] | select(.status != "must-use" and .status != "dropin")];
        {
            schema_version: $schema,
            script_version: $script_version,
            site: $site,
            domain: $domain,
            aliases: $aliases,
            site_path: $path,
            owner: $site,
            generated_at: $collected,
            errors: $errors,

            wordpress: {
                version: $core_version,
                update_check_status: $core_status,
                update_available: ($core_status == "ok" and ($core_updates | length) > 0),
                updates: $core_updates,
                checksums: $core_checksums
            },

            environment: ($env + {disk_bytes: $disk, uploads_bytes: $uploads}),

            cloudflare: ({
                zone_id: $cf_zone_id,
                zone_name: $cf_zone_name,
                status: $cf_status,
                paused: $cf_paused,
                plan: $cf_plan,
                is_pro_or_higher: ($cf_plan | test("(?i)pro|business|enterprise")),
                name_servers: $cf_ns
            } + ($cfx[0] // {}) + {
                settings: ($cfx[0].settings // {}),
                fetch_errors: ($cfx[0].fetch_errors // [])
            }),

            plugins: {
                total: ($plugins | regular | length),
                active: ([$plugins[] | select(.status == "active" or .status == "active-network")] | length),
                inactive: ([$plugins[] | select(.status == "inactive")] | length),
                must_use: ([$plugins[] | select(.status == "must-use")] | length),
                updates_available: ([$plugins | regular | .[] | select(.update == "available")] | length),
                items: $plugins
            },

            themes: {
                total: ($themes | length),
                updates_available: ([$themes[] | select(.update == "available")] | length),
                active: ([$themes[] | select(.status == "active")][0].name // null),
                items: $themes
            },

            dropins: $dropins,

            docroot: {
                path: $path,
                folders: $docroot_folders,
                files: $docroot_files
            }
        }') || { warn "$VHOST: failed to build report"; rm -f "$CF_FILE"; return 1; }
    rm -f "$CF_FILE"

    # Write atomically so PHP never reads a partially written report
    local OUTPUT_FILE="$DATA_DIR/$VHOST.json" TEMP_FILE
    TEMP_FILE=$(mktemp "$DATA_DIR/.${VHOST}.XXXXXX") || return 1
    if printf '%s\n' "$REPORT" > "$TEMP_FILE"; then
        chown root:nogroup "$TEMP_FILE"
        chmod 0640 "$TEMP_FILE"
        mv -f -- "$TEMP_FILE" "$OUTPUT_FILE"
        log "Saved $OUTPUT_FILE ($(jq 'length' <<< "$ERRORS") warnings)"
    else
        rm -f -- "$TEMP_FILE"
        warn "$VHOST: could not save report"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
    TARGETS=()
    for v in "$@"; do TARGETS+=("$VHOST_CONFIG_DIR/$v"); done
else
    TARGETS=("$VHOST_CONFIG_DIR"/*)
fi

for VHOST_DIR in "${TARGETS[@]}"; do
    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue
    collect_site "$VHOST_DIR"
done

log "WordPress metrics collection completed."
