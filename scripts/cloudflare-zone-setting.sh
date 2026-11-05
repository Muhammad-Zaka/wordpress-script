#!/bin/bash
#
# cloudflare-zone-setting.sh
# Checks and changes one Cloudflare zone setting (e.g. 0-RTT) across many zones.
#
# Safe by default: only REPORTS what would change. Add --apply to make changes.
#
# Usage:
#   cloudflare-zone-setting.sh SETTING VALUE [options] [domain ...]
#
#   cloudflare-zone-setting.sh 0rtt on                       # dry run: WordPress vhosts on this server
#   cloudflare-zone-setting.sh 0rtt on --apply               # enable 0-RTT on them
#   cloudflare-zone-setting.sh 0rtt on --all-zones --apply   # every zone in the Cloudflare account
#   cloudflare-zone-setting.sh 0rtt on example.com --apply   # specific domains
#   cloudflare-zone-setting.sh early_hints on --apply        # any other on/off zone setting
#   cloudflare-zone-setting.sh --rollback cf-0rtt-20261105-081500.csv --apply
#
# SETTING is the Cloudflare setting id (0rtt, http3, early_hints, brotli, always_use_https, ...).
# VALUE is what the API expects: usually on/off, sometimes a word or a number.
#
# Options:
#   --apply        make the changes (otherwise dry run)
#   --all-zones    every zone in the account instead of the vhosts on this server
#   --log FILE     CSV audit log (default ./cf-<setting>-<timestamp>.csv)
#
# Credentials (~/.site-setup/creds): cf_token="..." (needs Zone Settings: EDIT + Zone: Read)
#                                    or cf_email + cf_key (global key)

set -uo pipefail

VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"
CREDS_FILE="$HOME/.site-setup/creds"
CF_TIMEOUT=20
CF_DELAY=0.25

APPLY=0 ALL_ZONES=0 ROLLBACK="" LOG_FILE=""
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)     APPLY=1 ;;
        --all-zones) ALL_ZONES=1 ;;
        --log)       LOG_FILE="${2:-}"; shift ;;
        --rollback)  ROLLBACK="${2:-}"; shift ;;
        -h|--help)   sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "Unknown option: $1" >&2; exit 1 ;;
        *)           POS+=("$1") ;;
    esac
    shift
done

if [[ -z "$ROLLBACK" ]]; then
    [[ ${#POS[@]} -ge 2 ]] || { echo "Usage: $0 SETTING VALUE [--apply] [--all-zones] [domain ...]  (see --help)" >&2; exit 1; }
    SETTING="${POS[0]}"; VALUE="${POS[1]}"; DOMAINS=("${POS[@]:2}")
    [[ "$SETTING" =~ ^[a-z0-9_]+$ ]] || { echo "Invalid setting id: $SETTING" >&2; exit 1; }
else
    SETTING="" VALUE=""; DOMAINS=()
fi
LOG_FILE="${LOG_FILE:-./cf-${SETTING:-rollback}-$(date +%Y%m%d-%H%M%S).csv}"

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

cf() {  # cf METHOD PATH [JSON_BODY]
    local args=(-sS --max-time "$CF_TIMEOUT" --retry 2 --retry-delay 2 -X "$1" -H "Content-Type: application/json" "${CF_AUTH[@]}")
    [[ -n "${3:-}" ]] && args+=(--data "$3")
    sleep "$CF_DELAY"
    curl "${args[@]}" "https://api.cloudflare.com/client/v4/$2"
}
cf_ok()  { jq -e '.success == true' <<< "$1" >/dev/null 2>&1; }
cf_err() { jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ") | if . == "" then "invalid response" else . end' <<< "$1" 2>/dev/null || echo "invalid response"; }

# The API wants JSON: numbers and true/false unquoted, everything else as a string
to_json() { if [[ "$1" =~ ^-?[0-9]+$ || "$1" == "true" || "$1" == "false" ]]; then echo "$1"; else jq -nc --arg v "$1" '$v'; fi; }

zone_candidates() {
    local name="${1#www.}"
    while [[ "$name" == *.* ]]; do echo "$name"; name="${name#*.}"; done
}
find_zone() {
    local c resp
    while read -r c; do
        resp=$(cf GET "zones?name=$c") || continue
        if cf_ok "$resp" && [[ $(jq '.result | length' <<< "$resp") -gt 0 ]]; then
            jq -r '.result[0] | "\(.id)\t\(.name)"' <<< "$resp"; return 0
        fi
    done < <(zone_candidates "$1")
    return 1
}

# ---------------------------------------------------------------------------
# Zones to process: "zone_id<TAB>zone_name<TAB>setting<TAB>target_value_json"
# ---------------------------------------------------------------------------
ZONES=() NOT_FOUND=()
if [[ -n "$ROLLBACK" ]]; then
    [[ -f "$ROLLBACK" ]] || { echo "ERROR: rollback file not found: $ROLLBACK" >&2; exit 1; }
    # columns: timestamp,zone,zone_id,setting,old,new,result
    while IFS=, read -r _ts zname zid set old _new result; do
        [[ "$result" == "changed" ]] || continue
        ZONES+=("$zid"$'\t'"$zname"$'\t'"$set"$'\t'"$(to_json "$old")")
    done < <(tail -n +2 "$ROLLBACK")
    echo "Rollback: ${#ZONES[@]} zone(s) from $ROLLBACK"
elif [[ $ALL_ZONES -eq 1 ]]; then
    page=1
    while :; do
        resp=$(cf GET "zones?per_page=50&page=$page")
        cf_ok "$resp" || { echo "ERROR: listing zones failed: $(cf_err "$resp")" >&2; exit 1; }
        while IFS= read -r z; do ZONES+=("$z"$'\t'"$SETTING"$'\t'"$(to_json "$VALUE")"); done \
            < <(jq -r '.result[] | "\(.id)\t\(.name)"' <<< "$resp")
        [[ $page -ge $(jq -r '.result_info.total_pages // 1' <<< "$resp") ]] && break
        page=$((page + 1))
    done
else
    if [[ ${#DOMAINS[@]} -eq 0 ]]; then
        for VHOST_DIR in "$VHOST_CONFIG_DIR"/*; do
            [[ -f "$VHOST_DIR/vhconf.conf" ]] || continue
            VHOST="${VHOST_DIR##*/}"
            [[ -f "/home/$VHOST/public_html/wp-config.php" ]] || continue
            D=$(grep -E '^\s*vhAliases\s+' "$VHOST_DIR/vhconf.conf" | head -n 1 \
                | sed -E 's/^[[:space:]]*vhAliases[[:space:]]+//' | tr ',' '\n' | tr -d ' \t"\r' \
                | grep -v -e '^$' -e '^\*$' -e '\$' | head -n 1)
            DOMAINS+=("${D:-$VHOST}")
        done
    fi
    declare -A SEEN=()
    for d in "${DOMAINS[@]}"; do
        if z=$(find_zone "$d"); then
            zid="${z%%$'\t'*}"
            [[ -n "${SEEN[$zid]:-}" ]] && continue
            SEEN[$zid]=1
            ZONES+=("$z"$'\t'"$SETTING"$'\t'"$(to_json "$VALUE")")
        else
            NOT_FOUND+=("$d")
        fi
    done
fi

if [[ ${#ZONES[@]} -eq 0 ]]; then
    echo "No Cloudflare zones to process."
    [[ ${#NOT_FOUND[@]} -gt 0 ]] && echo "No zone found for: ${NOT_FOUND[*]}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Process
# ---------------------------------------------------------------------------
echo "Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo 'DRY RUN')   $([[ -n "$ROLLBACK" ]] && echo 'Restoring previous values' || echo "Setting: $SETTING = $VALUE")   Zones: ${#ZONES[@]}"
echo
printf '%-40s %-10s %-10s %s\n' "ZONE" "CURRENT" "TARGET" "RESULT"
echo "timestamp,zone,zone_id,setting,old,new,result" > "$LOG_FILE"
n_changed=0 n_would=0 n_ok=0 n_skip=0 n_err=0

for entry in "${ZONES[@]}"; do
    IFS=$'\t' read -r zid zname set want_json <<< "$entry"
    want=$(jq -r 'tostring' <<< "$want_json")
    current="?" result=""

    resp=$(cf GET "zones/$zid/settings/$set")
    if ! cf_ok "$resp"; then
        result="error: $(cf_err "$resp")"; n_err=$((n_err + 1))
    else
        current=$(jq -r '.result.value | if type == "string" or type == "number" or type == "boolean" then tostring else tojson end' <<< "$resp")
        editable=$(jq -r '.result.editable // true' <<< "$resp")

        if [[ "$current" == "$want" ]]; then
            result="ok (already $current)"; n_ok=$((n_ok + 1))
        elif [[ "$editable" == "false" ]]; then
            result="skipped: not editable on this zone's plan"; n_skip=$((n_skip + 1))
        else
            # 0-RTT only works with TLS 1.3
            if [[ "$set" == "0rtt" && "$want" == "on" && -z "$ROLLBACK" ]]; then
                tls=$(cf GET "zones/$zid/settings/tls_1_3")
                tls13=$(jq -r '.result.value // "unknown"' <<< "$tls")
                if [[ "$tls13" == "off" ]]; then
                    result="skipped: TLS 1.3 is off (0-RTT needs it)"; n_skip=$((n_skip + 1))
                fi
            fi
            if [[ -z "$result" ]]; then
                if [[ $APPLY -eq 0 ]]; then
                    result="would change"; n_would=$((n_would + 1))
                else
                    presp=$(cf PATCH "zones/$zid/settings/$set" "{\"value\":$want_json}")
                    if cf_ok "$presp" && [[ $(jq -r '.result.value | tostring' <<< "$presp") == "$want" ]]; then
                        result="changed"; n_changed=$((n_changed + 1))
                    else
                        result="error: $(cf_err "$presp")"; n_err=$((n_err + 1))
                    fi
                fi
            fi
        fi
    fi
    printf '%-40s %-10s %-10s %s\n' "$zname" "$current" "$want" "$result"
    q=$([[ "$result" == "changed" ]] && echo "changed" || echo "\"${result//\"/\'}\"")
    echo "$(date --iso-8601=seconds),$zname,$zid,$set,$current,$want,$q" >> "$LOG_FILE"
done

echo
if [[ $APPLY -eq 1 ]]; then
    echo "Changed: $n_changed   Already set: $n_ok   Skipped: $n_skip   Errors: $n_err"
else
    echo "Would change: $n_would   Already set: $n_ok   Skipped: $n_skip   Errors: $n_err"
    [[ $n_would -gt 0 ]] && echo "Run again with --apply to make these changes."
fi
[[ ${#NOT_FOUND[@]} -gt 0 ]] && echo "No Cloudflare zone found for: ${NOT_FOUND[*]}"
echo "Audit log: $LOG_FILE"
[[ $n_err -gt 0 ]] && exit 2
exit 0
