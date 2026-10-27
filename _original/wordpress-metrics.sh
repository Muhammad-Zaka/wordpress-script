#!/bin/bash

set -uo pipefail

if [ -f ~/.site-setup/creds ]; then
    source ~/.site-setup/creds
else
    echo "Credentials file ~/.site-setup/creds not found. Exiting."
    exit 1
fi

# Check if required variables are set
if [ -z "$cf_email" ] || [ -z "$cf_key" ]; then
    echo "One or more required credentials are missing in ~/.site-setup/creds. Exiting."
    exit 1
fi
CLOUDFLARE_EMAIL="$cf_email"
CLOUDFLARE_API_KEY="$cf_key"

# OpenLiteSpeed vhost configuration directory
VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"

# Directory to store individual site JSON reports
DATA_DIR="/nas/wp-metrics-test1"

# WP-CLI executable
WP_CLI="/usr/local/bin/wp"

# Create the metrics directory
install -d -o root -g nogroup -m 0750 "$DATA_DIR"

# Verify dependencies
for cmd in jq curl sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -x "$WP_CLI" ]]; then
    echo "ERROR: WP-CLI not found at $WP_CLI" >&2
    exit 1
fi

# Loop through each OpenLiteSpeed vhost
for VHOST_DIR in "$VHOST_CONFIG_DIR"/*; do

    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue

    VHOST="${VHOST_DIR##*/}"
    VHCONF_FILE="$VHOST_DIR/vhconf.conf"

    # Extract the domain name from vhAliases in vhconf.conf
    VH_ALIAS_LINE=$(grep -E '^\s*vhAliases\s+' "$VHCONF_FILE" | head -n 1)
    if [[ -n "$VH_ALIAS_LINE" ]]; then
        PRIMARY_DOMAIN=$(echo "$VH_ALIAS_LINE" | sed -E 's/^[[:space:]]*vhAliases[[:space:]]+//' | tr ',' '\n' | head -n 1 | tr -d '[:space:]"\r')
    fi

    # Fallback to the vhost directory name if no vhAliases directive is found
    DOMAIN="${PRIMARY_DOMAIN:-$VHOST}"
    WEB_ROOT="/home/$VHOST/public_html"

    # Check if it is a WordPress site
    if [[ ! -f "$WEB_ROOT/wp-config.php" ]]; then
        echo "Skipping non-WordPress site: $VHOST"
        continue
    fi

    echo "Collecting WordPress metrics for domain: $DOMAIN (vhost: $VHOST)"

    # Run WP-CLI as the site owner
    wp() {
        sudo -u "$VHOST" "$WP_CLI" \
            --path="$WEB_ROOT" --no-color --quiet "$@" 2>&1
    }

    # Get core version
    if ! CORE_VERSION=$(wp core version); then
        echo "ERROR: Could not get core version for $VHOST" >&2
        continue
    fi

    # Check core updates
    CORE_STATUS="ok"
    CORE_UPDATES=$(wp core check-update --format=json) || {
        CORE_STATUS="error"
        CORE_UPDATES="[]"
    }

    if [[ -z "$CORE_UPDATES" ]]; then
        CORE_UPDATES="[]"
    fi

    if ! jq -e 'type == "array"' <<< "$CORE_UPDATES" >/dev/null 2>&1; then
        CORE_STATUS="error"
        CORE_UPDATES="[]"
    fi

    # Collect plugin data
    if ! PLUGINS=$(wp plugin list --format=json); then
        echo "ERROR: Plugin query failed for $VHOST" >&2
        continue
    fi

    if ! jq -e 'type == "array"' <<< "$PLUGINS" >/dev/null 2>&1; then
        echo "ERROR: Invalid plugin JSON for $VHOST" >&2
        continue
    fi

    # Collect theme data
    if ! THEMES=$(wp theme list --format=json); then
        echo "ERROR: Theme query failed for $VHOST" >&2
        continue
    fi

    if ! jq -e 'type == "array"' <<< "$THEMES" >/dev/null 2>&1; then
        echo "ERROR: Invalid theme JSON for $VHOST" >&2
        continue
    fi

    # Discover WordPress drop-ins
    DROPINS="[]"

    for NAME in \
        advanced-cache.php \
        object-cache.php \
        db.php \
        db-error.php \
        install.php \
        maintenance.php \
        php-error.php \
        fatal-error-handler.php
    do
        FILE="$WEB_ROOT/wp-content/$NAME"

        if [[ -f "$FILE" ]]; then
            SIZE=$(stat -c '%s' "$FILE")

            DROPINS=$(jq -c \
                --arg name "$NAME" \
                --argjson size "$SIZE" \
                '. + [{
                    "name": $name,
                    "status": "dropin",
                    "exists": true,
                    "size_bytes": $size
                }]' <<< "$DROPINS")
        fi
    done

    # --- Extract Cloudflare Credentials & Zone ID from vhconf.conf ---
    CF_PLAN="none"
    CF_ZONE_ID=""
    CF_STATUS="inactive"
    echo "$DOMAIN"
    echo "$CLOUDFLARE_EMAIL"

    if [[ -z "$CF_ZONE_ID" ]] && [[ -n "$CLOUDFLARE_EMAIL" && -n "$CLOUDFLARE_API_KEY" ]]; then
        ZONE_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
            -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
            -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
            -H "Content-Type: application/json")

        echo "$ZONE_RESPONSE"
        if jq -e '.success == true' <<< "$ZONE_RESPONSE" >/dev/null 2>&1; then
            CF_ZONE_ID=$(jq -r '.result[0].id // empty' <<< "$ZONE_RESPONSE")
        fi
    fi

    SETTINGS_JSON="{}"

    if [[ -n "$CF_ZONE_ID" && "$CF_ZONE_ID" != "null" ]] && [[ -n "$CLOUDFLARE_EMAIL" && -n "$CLOUDFLARE_API_KEY" ]]; then
        SUB_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID" \
            -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
            -H "X-Auth-Key: $CLOUDFLARE_API_KEY" \
            -H "Content-Type: application/json")

        if jq -e '.success == true' <<< "$SUB_RESPONSE" >/dev/null 2>&1; then
            RAW_PLAN=$(jq -r '.result.plan.name // "Free"' <<< "$SUB_RESPONSE")
            CF_PLAN=$(echo "$RAW_PLAN" | awk '{print $1}')
            CF_STATUS=$(jq -r '.result.status // "unknown"' <<< "$SUB_RESPONSE")
        fi

        # --- Fetch Cloudflare Advanced Settings (including APO) ---
        cf_settings=(
            "always_use_https" "mirage" "speed_brain" "rocket_loader"
            "http2" "h2_prioritization" "http3" "0rtt" "tls_1_3"
            "automatic_https_rewrites" "opportunistic_encryption"
            "email_obfuscation" "hotlink_protection" "early_hints" "browser_check"
            "automatic_platform_optimization"
        )

        for setting in "${cf_settings[@]}"; do
            SETTING_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/settings/$setting" \
                -H 'Content-Type: application/json' \
                -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
                -H "X-Auth-Key: $CLOUDFLARE_API_KEY")

            if jq -e '.success == true' <<< "$SETTING_RESP" >/dev/null 2>&1; then
                S_ID=$(jq -r '.result.id // "'$setting'"' <<< "$SETTING_RESP")

                # Check if setting value is a complex object/array (e.g. APO) vs scalar
                if jq -e '.result.value | type == "object" or type == "array"' <<< "$SETTING_RESP" >/dev/null 2>&1; then
                    S_VAL_JSON=$(jq -c '.result.value' <<< "$SETTING_RESP")
                    SETTINGS_JSON=$(jq -c --arg id "$S_ID" --argjson val "$S_VAL_JSON" '.[$id] = $val' <<< "$SETTINGS_JSON")
                else
                    S_VAL=$(jq -r '.result.value // "unknown"' <<< "$SETTING_RESP")
                    SETTINGS_JSON=$(jq -c --arg id "$S_ID" --arg val "$S_VAL" '.[$id] = $val' <<< "$SETTINGS_JSON")
                fi
            fi
        done

        # --- Fetch Cloudflare Email Routing Status ---
        ROUTING_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/email/routing" \
            -H 'Content-Type: application/json' \
            -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
            -H "X-Auth-Key: $CLOUDFLARE_API_KEY")

        if jq -e '.success == true' <<< "$ROUTING_RESP" >/dev/null 2>&1; then
            ROUTING_ENABLED=$(jq -r '.result.enabled // false' <<< "$ROUTING_RESP")
            SETTINGS_JSON=$(jq -c --argjson val "$ROUTING_ENABLED" '.["email_routing"] = $val' <<< "$SETTINGS_JSON")
        fi

        # --- Fetch Cloudflare SSL Setting Value ---
        SSL_RESP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/settings/ssl" \
            -H 'Content-Type: application/json' \
            -H "X-Auth-Email: $CLOUDFLARE_EMAIL" \
            -H "X-Auth-Key: $CLOUDFLARE_API_KEY")

        if jq -e '.success == true' <<< "$SSL_RESP" >/dev/null 2>&1; then
            SSL_VALUE=$(jq -r '.result.value // "unknown"' <<< "$SSL_RESP")
            SETTINGS_JSON=$(jq -c --arg val "$SSL_VALUE" '.["ssl"] = $val' <<< "$SETTINGS_JSON")
        fi
    fi

    # Build this site's JSON report
    REPORT=$(jq -n \
        --arg site "$VHOST" \
        --arg domain "$DOMAIN" \
        --arg path "$WEB_ROOT" \
        --arg owner "$VHOST" \
        --arg collected "$(date --iso-8601=seconds)" \
        --arg core_version "$CORE_VERSION" \
        --arg core_status "$CORE_STATUS" \
        --argjson core_updates "$CORE_UPDATES" \
        --argjson plugins "$PLUGINS" \
        --argjson themes "$THEMES" \
        --argjson dropins "$DROPINS" \
        --arg cf_zone_id "$CF_ZONE_ID" \
        --arg cf_status "$CF_STATUS" \
        --arg cf_plan "$CF_PLAN" \
        --argjson cf_settings "$SETTINGS_JSON" \
        '
        {
            site: $site,
            domain: $domain,
            site_path: $path,
            owner: $owner,
            generated_at: $collected,

            wordpress: {
                version: $core_version,
                update_check_status: $core_status,
                update_available: (
                    $core_status == "ok" and
                    ($core_updates | length) > 0
                ),
                updates: $core_updates
            },

            cloudflare: {
                zone_id: $cf_zone_id,
                status: $cf_status,
                plan: $cf_plan,
                is_pro_or_higher: ($cf_plan | test("(?i)pro|business|enterprise")),
                settings: $cf_settings
            },

            plugins: {
                total: ($plugins | length),
                active: (
                    [$plugins[] | select(.status == "active")]
                    | length
                ),
                updates_available: (
                    [$plugins[] | select(.update == "available")]
                    | length
                ),
                items: $plugins
            },

            themes: {
                total: ($themes | length),
                updates_available: (
                    [$themes[] | select(.update == "available")]
                    | length
                ),
                items: $themes
            },

            dropins: $dropins
        }')

    if [[ -z "$REPORT" ]]; then
        echo "ERROR: Failed to build report for $VHOST" >&2
        continue
    fi

    # Write atomically so PHP never reads a partially written report
    OUTPUT_FILE="$DATA_DIR/$VHOST.json"
    TEMP_FILE=$(mktemp "$DATA_DIR/.${VHOST}.XXXXXX") || continue

    if printf '%s\n' "$REPORT" > "$TEMP_FILE"; then
        chown root:nogroup "$TEMP_FILE"
        chmod 0640 "$TEMP_FILE"
        mv -f -- "$TEMP_FILE" "$OUTPUT_FILE"
        echo "Saved: $OUTPUT_FILE"
    else
        rm -f -- "$TEMP_FILE"
        echo "ERROR: Could not save report for $VHOST" >&2
    fi

done

echo "WordPress metrics collection completed."