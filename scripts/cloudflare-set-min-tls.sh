#!/bin/bash
#
# cloudflare-set-min-tls.sh
# Raises Cloudflare's "Minimum TLS Version" to 1.2 (or another version) for many zones.
#
# Safe by default: it only REPORTS what would change. Add --apply to make changes.
# Zones already at or above the target (e.g. 1.3) are left alone unless --exact is given.
#
# Which zones:
#   (default)          every WordPress vhost on this server (same discovery as wordpress-metrics.sh)
#   --all-zones        every zone in the Cloudflare account
#   domain1 domain2    only these domains
#
# Options:
#   --apply            actually change the setting (otherwise dry run)
#   --version X        target minimum TLS version: 1.0 | 1.1 | 1.2 | 1.3   (default 1.2)
#   --exact            set exactly X even if the zone is currently higher (allows lowering 1.3 -> 1.2)
#   --log FILE         where to write the CSV audit log (default ./min-tls-<timestamp>.csv)
#
# Examples:
#   ./cloudflare-set-min-tls.sh                       # dry run for all vhosts on this server
#   ./cloudflare-set-min-tls.sh --apply               # apply to all vhosts on this server
#   ./cloudflare-set-min-tls.sh --all-zones --apply   # apply to every zone in the account
#   ./cloudflare-set-min-tls.sh example.com --apply   # one site
#
# Rollback: the audit log has the previous value of every zone that was changed.
#   ./cloudflare-set-min-tls.sh --rollback min-tls-20261027-224500.csv --apply
#
# Credentials (~/.site-setup/creds): cf_token="..." (needs Zone Settings: EDIT + Zone: Read)
#                                    or cf_email + cf_key (global key)

set -uo pipefail

VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"
CREDS_FILE="$HOME/.site-setup/creds"
CF_TIMEOUT=20
CF_DELAY=0.25

APPLY=0
TARGET="1.2"
EXACT=0
ALL_ZONES=0
ROLLBACK=""
LOG_FILE="./min-tls-$(date +%Y%m%d-%H%M%S).csv"
DOMAINS=()

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)     APPLY=1 ;;
        --exact)     EXACT=1 ;;
        --all-zones) ALL_ZONES=1 ;;
        --version)   TARGET="${2:-}"; shift ;;
        --log)       LOG_FILE="${2:-}"; shift ;;
        --rollback)  ROLLBACK="${2:-}"; shift ;;
        -h|--help)   usage 0 ;;
        -*)          echo "Unknown option: $1" >&2; usage 1 ;;
        *)           DOMAINS+=("$1") ;;
    esac
    shift
done

case "$TARGET" in 1.0|1.1|1.2|1.3) ;; *) echo "Invalid --version '$TARGET' (use 1.0, 1.1, 1.2 or 1.3)" >&2; exit 1 ;; esac

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
    local method="$1" path="$2" body="${3:-}"
    sleep "$CF_DELAY"
    if [[ -n "$body" ]]; then
        curl -sS --max-time "$CF_TIMEOUT" --retry 2 --retry-delay 2 -X "$method" \
            -H "Content-Type: application/json" "${CF_AUTH[@]}" --data "$body" \
            "https://api.cloudflare.com/client/v4/$path"
    else
        curl -sS --max-time "$CF_TIMEOUT" --retry 2 --retry-delay 2 -X "$method" \
            -H "Content-Type: application/json" "${CF_AUTH[@]}" \
            "https://api.cloudflare.com/client/v4/$path"
    fi
}
cf_ok()  { jq -e '.success == true' <<< "$1" >/dev/null 2>&1; }
cf_err() { jq -r '[.errors[]? | "\(.code) \(.message)"] | join("; ") | if . == "" then "invalid response" else . end' <<< "$1" 2>/dev/null || echo "invalid response"; }

zone_candidates() {
    local name="${1#www.}"
    while [[ "$name" == *.* ]]; do echo "$name"; name="${name#*.}"; done
}

# Prints "zone_id<TAB>zone_name" for a domain, or nothing
find_zone() {
    local c resp
    while read -r c; do
        resp=$(cf GET "zones?name=$c") || continue
        if cf_ok "$resp" && [[ $(jq '.result | length' <<< "$resp") -gt 0 ]]; then
            jq -r '.result[0] | "\(.id)\t\(.name)"' <<< "$resp"
            return 0
        fi
    done < <(zone_candidates "$1")
    return 1
}

# ---------------------------------------------------------------------------
# Build the list of zones: lines of "zone_id<TAB>zone_name<TAB>target"
# ---------------------------------------------------------------------------
ZONES=()
NOT_FOUND=()

if [[ -n "$ROLLBACK" ]]; then
    [[ -f "$ROLLBACK" ]] || { echo "ERROR: rollback file not found: $ROLLBACK" >&2; exit 1; }
    # Audit log columns: timestamp,zone,zone_id,old,new,result
    while IFS=, read -r _ts zname zid old _new result; do
        [[ "$result" == "changed" ]] || continue
        ZONES+=("$zid"$'\t'"$zname"$'\t'"$old")
    done < <(tail -n +2 "$ROLLBACK")
    EXACT=1
    echo "Rollback: ${#ZONES[@]} zone(s) from $ROLLBACK"
elif [[ $ALL_ZONES -eq 1 ]]; then
    page=1
    while :; do
        resp=$(cf GET "zones?per_page=50&page=$page")
        cf_ok "$resp" || { echo "ERROR: listing zones failed: $(cf_err "$resp")" >&2; exit 1; }
        while IFS= read -r z; do ZONES+=("$z"$'\t'"$TARGET"); done < <(jq -r '.result[] | "\(.id)\t\(.name)"' <<< "$resp")
        total_pages=$(jq -r '.result_info.total_pages // 1' <<< "$resp")
        [[ $page -ge $total_pages ]] && break
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
            [[ -n "${SEEN[$zid]:-}" ]] && continue   # several vhosts can share one zone
            SEEN[$zid]=1
            ZONES+=("$z"$'\t'"$TARGET")
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
[[ $APPLY -eq 1 ]] && MODE="APPLY" || MODE="DRY RUN"
if [[ -n "$ROLLBACK" ]]; then
    echo "Mode: $MODE   Restoring previous values   Zones: ${#ZONES[@]}"
else
    echo "Mode: $MODE   Target minimum TLS: $TARGET$([[ $EXACT -eq 1 ]] && echo ' (exact)')   Zones: ${#ZONES[@]}"
fi
echo
printf '%-40s %-9s %-9s %s\n' "ZONE" "CURRENT" "TARGET" "RESULT"
printf '%-40s %-9s %-9s %s\n' "----" "-------" "------" "------"

echo "timestamp,zone,zone_id,old,new,result" > "$LOG_FILE"
n_changed=0 n_would=0 n_ok=0 n_err=0

for entry in "${ZONES[@]}"; do
    IFS=$'\t' read -r zid zname want <<< "$entry"
    resp=$(cf GET "zones/$zid/settings/min_tls_version")
    if ! cf_ok "$resp"; then
        result="error: $(cf_err "$resp")"
        printf '%-40s %-9s %-9s %s\n' "$zname" "?" "$want" "$result"
        echo "$(date --iso-8601=seconds),$zname,$zid,,$want,\"$result\"" >> "$LOG_FILE"
        n_err=$((n_err + 1))
        continue
    fi
    current=$(jq -r '.result.value' <<< "$resp")

    # Version strings compare correctly as numbers (1.0 < 1.1 < 1.2 < 1.3)
    if [[ "$current" == "$want" ]] || { [[ $EXACT -eq 0 ]] && awk "BEGIN{exit !($current >= $want)}"; }; then
        result="ok (already $current)"
        n_ok=$((n_ok + 1))
    elif [[ $APPLY -eq 0 ]]; then
        result="would change"
        n_would=$((n_would + 1))
    else
        presp=$(cf PATCH "zones/$zid/settings/min_tls_version" "{\"value\":\"$want\"}")
        if cf_ok "$presp" && [[ $(jq -r '.result.value' <<< "$presp") == "$want" ]]; then
            result="changed"
            n_changed=$((n_changed + 1))
        else
            result="error: $(cf_err "$presp")"
            n_err=$((n_err + 1))
        fi
    fi
    printf '%-40s %-9s %-9s %s\n' "$zname" "$current" "$want" "$result"
    echo "$(date --iso-8601=seconds),$zname,$zid,$current,$want,\"$result\"" >> "$LOG_FILE"
done

# The result column is quoted only when it has spaces; normalise "changed" for rollback parsing
sed -i 's/,"changed"$/,changed/' "$LOG_FILE"

echo
if [[ $APPLY -eq 1 ]]; then
    echo "Changed: $n_changed   Already compliant: $n_ok   Errors: $n_err"
else
    echo "Would change: $n_would   Already compliant: $n_ok   Errors: $n_err"
    [[ $n_would -gt 0 ]] && echo "Run again with --apply to make these changes."
fi
[[ ${#NOT_FOUND[@]} -gt 0 ]] && echo "No Cloudflare zone found for: ${NOT_FOUND[*]}"
echo "Audit log: $LOG_FILE"
[[ $n_err -gt 0 ]] && exit 2
exit 0
