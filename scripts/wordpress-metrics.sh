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
#   cf_token="..."                      # preferred: scoped API token (Zone:Read, Zone Settings:Read)
# or
#   cf_email="..." ; cf_key="..."       # legacy Global API key

set -uo pipefail

SCRIPT_VERSION="2.0.0"
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

# Cloudflare settings recorded for each zone (compared against the standard in the dashboard)
CF_SETTINGS=(
    always_use_https automatic_https_rewrites ssl min_tls_version tls_1_3
    opportunistic_encryption http2 h2_prioritization http3 0rtt
    early_hints speed_brain rocket_loader mirage brotli
    email_obfuscation hotlink_protection browser_check security_level
    development_mode always_online cache_level browser_cache_ttl
    automatic_platform_optimization
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

    # --- Cloudflare ---
    local CF_PLAN="none" CF_ZONE_ID="" CF_ZONE_NAME="" CF_STATUS="inactive" CF_PAUSED="false"
    local CF_NS="[]" CF_SETTINGS_JSON="{}" CANDIDATE RESP
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
            # One bulk call for all settings, then fetch individually only what's missing
            local WANTED ALL_SETTINGS="{}" MISSING S
            WANTED=$(printf '%s\n' "${CF_SETTINGS[@]}" | jq -R . | jq -sc .)
            RESP=$(cf_get "zones/$CF_ZONE_ID/settings")
            if jq -e '.success == true' <<< "$RESP" >/dev/null 2>&1; then
                ALL_SETTINGS=$(jq -c '[.result[] | {key: .id, value: .value}] | from_entries' <<< "$RESP")
            else
                add_error "Cloudflare bulk settings request failed"
            fi
            CF_SETTINGS_JSON=$(jq -c --argjson w "$WANTED" 'with_entries(select(.key as $k | $w | index($k)))' <<< "$ALL_SETTINGS")

            MISSING=$(jq -r --argjson w "$WANTED" '. as $s | $w[] | select($s[.] == null)' <<< "$CF_SETTINGS_JSON")
            for S in $MISSING; do
                RESP=$(cf_get "zones/$CF_ZONE_ID/settings/$S")
                if jq -e '.success == true' <<< "$RESP" >/dev/null 2>&1; then
                    CF_SETTINGS_JSON=$(jq -c --arg k "$S" --argjson v "$(jq -c '.result.value' <<< "$RESP")" '.[$k] = $v' <<< "$CF_SETTINGS_JSON")
                fi
            done

            RESP=$(cf_get "zones/$CF_ZONE_ID/email/routing")
            if jq -e '.success == true' <<< "$RESP" >/dev/null 2>&1; then
                CF_SETTINGS_JSON=$(jq -c --argjson v "$(jq '.result.enabled // false' <<< "$RESP")" '.email_routing = $v' <<< "$CF_SETTINGS_JSON")
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
        --argjson env "$ENV_JSON" \
        --argjson disk "$DISK_BYTES" \
        --argjson uploads "$UPLOADS_BYTES" \
        --arg cf_zone_id "$CF_ZONE_ID" \
        --arg cf_zone_name "$CF_ZONE_NAME" \
        --arg cf_status "$CF_STATUS" \
        --argjson cf_paused "$CF_PAUSED" \
        --arg cf_plan "$CF_PLAN" \
        --argjson cf_ns "$CF_NS" \
        --argjson cf_settings "$CF_SETTINGS_JSON" \
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

            cloudflare: {
                zone_id: $cf_zone_id,
                zone_name: $cf_zone_name,
                status: $cf_status,
                paused: $cf_paused,
                plan: $cf_plan,
                is_pro_or_higher: ($cf_plan | test("(?i)pro|business|enterprise")),
                name_servers: $cf_ns,
                settings: $cf_settings
            },

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

            dropins: $dropins
        }') || { warn "$VHOST: failed to build report"; return 1; }

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
