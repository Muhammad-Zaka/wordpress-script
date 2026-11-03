#!/bin/bash
#
# cloudflare-zone-ids.sh
# Lists the Cloudflare Zone ID and Account ID for every site on this server.
#
# Usage:
#   cloudflare-zone-ids.sh                    # all vhosts, table on screen + CSV file
#   cloudflare-zone-ids.sh --wordpress-only   # only vhosts with a wp-config.php
#   cloudflare-zone-ids.sh --csv FILE         # CSV location (default ./cloudflare-zones-<date>.csv)
#   cloudflare-zone-ids.sh --json             # print JSON instead of the table
#   cloudflare-zone-ids.sh site1 site2        # only these vhosts
#
# Credentials (~/.site-setup/creds): cf_token="..." (Zone: Read) or cf_email + cf_key (global key)

set -uo pipefail

VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"
CREDS_FILE="$HOME/.site-setup/creds"
CF_TIMEOUT=20
CF_DELAY=0.15

WP_ONLY=0 JSON=0
CSV_FILE="./cloudflare-zones-$(date +%Y%m%d-%H%M%S).csv"
TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --wordpress-only) WP_ONLY=1 ;;
        --json)           JSON=1 ;;
        --csv)            CSV_FILE="${2:-}"; shift ;;
        -h|--help)        sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)               echo "Unknown option: $1" >&2; exit 1 ;;
        *)                TARGETS+=("$1") ;;
    esac
    shift
done

for cmd in jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required" >&2; exit 1; }
done

cf_token="" cf_email="" cf_key=""
# shellcheck disable=SC1090
[[ -f "$CREDS_FILE" ]] && source "$CREDS_FILE"
if [[ -n "${cf_token:-}" ]]; then
    CF_AUTH=(-H "Authorization: Bearer $cf_token")
elif [[ -n "${cf_email:-}" && -n "${cf_key:-}" ]]; then
    CF_AUTH=(-H "X-Auth-Email: $cf_email" -H "X-Auth-Key: $cf_key")
else
    echo "ERROR: no Cloudflare credentials in $CREDS_FILE" >&2
    exit 1
fi

cf_get() {
    sleep "$CF_DELAY"
    curl -sS --max-time "$CF_TIMEOUT" --retry 2 --retry-delay 2 \
        -H "Content-Type: application/json" "${CF_AUTH[@]}" \
        "https://api.cloudflare.com/client/v4/$1"
}

# www.blog.example.co.uk -> blog.example.co.uk, example.co.uk, co.uk
zone_candidates() {
    local name="${1#www.}"
    while [[ "$name" == *.* ]]; do echo "$name"; name="${name#*.}"; done
}

if [[ ${#TARGETS[@]} -gt 0 ]]; then
    DIRS=(); for t in "${TARGETS[@]}"; do DIRS+=("$VHOST_CONFIG_DIR/$t"); done
else
    DIRS=("$VHOST_CONFIG_DIR"/*)
fi

ROWS="[]"
for VHOST_DIR in "${DIRS[@]}"; do
    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue
    VHOST="${VHOST_DIR##*/}"
    IS_WP=false
    [[ -f "/home/$VHOST/public_html/wp-config.php" ]] && IS_WP=true
    [[ $WP_ONLY -eq 1 && $IS_WP == false ]] && continue

    # Domain: first vhAliases entry, otherwise the vhost name
    DOMAIN=$(grep -E '^\s*vhAliases\s+' "$VHOST_DIR/vhconf.conf" | head -n 1 \
        | sed -E 's/^[[:space:]]*vhAliases[[:space:]]+//' | tr ',' '\n' | tr -d ' \t"\r' \
        | grep -v -e '^$' -e '^\*$' -e '\$' | head -n 1)
    DOMAIN="${DOMAIN:-$VHOST}"
    DOMAIN="${DOMAIN#www.}"

    ZONE='{}' NOTE="no Cloudflare zone found"
    while read -r CANDIDATE; do
        RESP=$(cf_get "zones?name=$CANDIDATE") || { NOTE="Cloudflare request failed"; break; }
        if jq -e '.success == true and (.result | length) > 0' <<< "$RESP" >/dev/null 2>&1; then
            ZONE=$(jq -c '.result[0] | {zone_name: .name, zone_id: .id, account_id: .account.id,
                                        account_name: .account.name, plan: .plan.name, status: .status}' <<< "$RESP")
            NOTE=""
            break
        elif jq -e '.success == false' <<< "$RESP" >/dev/null 2>&1; then
            NOTE="API error: $(jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ")' <<< "$RESP")"
            break
        fi
    done < <(zone_candidates "$DOMAIN")

    ROWS=$(jq -c --arg vhost "$VHOST" --arg domain "$DOMAIN" --argjson wp "$IS_WP" --arg note "$NOTE" --argjson z "$ZONE" \
        '. + [{vhost: $vhost, domain: $domain, wordpress: $wp} + $z + {note: $note}]' <<< "$ROWS")
done

# CSV
jq -r '["vhost","domain","wordpress","zone_name","zone_id","account_id","account_name","plan","status","note"],
       (.[] | [.vhost, .domain, .wordpress, .zone_name, .zone_id, .account_id, .account_name, .plan, .status, .note])
       | map(if . == null then "" else . end) | @csv' <<< "$ROWS" > "$CSV_FILE"

if [[ $JSON -eq 1 ]]; then
    jq . <<< "$ROWS"
else
    printf '%-24s %-30s %-34s %-34s %s\n' "VHOST" "DOMAIN" "ZONE ID" "ACCOUNT ID" "ACCOUNT / NOTE"
    jq -r '.[] | [.vhost, .domain, (.zone_id // "-"), (.account_id // "-"),
                  (if .note != "" then .note else (.account_name // "") end)] | @tsv' <<< "$ROWS" |
        while IFS=$'\t' read -r V D Z A N; do
            printf '%-24s %-30s %-34s %-34s %s\n' "$V" "$D" "$Z" "$A" "$N"
        done
fi

TOTAL=$(jq 'length' <<< "$ROWS")
FOUND=$(jq '[.[] | select(.zone_id != null)] | length' <<< "$ROWS")
ACCOUNTS=$(jq '[.[] | .account_id | select(. != null)] | unique | length' <<< "$ROWS")
echo >&2
echo "Sites: $TOTAL   With a Cloudflare zone: $FOUND   Cloudflare accounts: $ACCOUNTS" >&2
echo "CSV: $CSV_FILE" >&2
