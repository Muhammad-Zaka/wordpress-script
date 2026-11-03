#!/bin/bash
#
# cloudflare-plugin-keys.sh
# Sets the API token used by the Cloudflare WordPress plugin on every site, choosing the token
# by the Cloudflare account that owns the site's zone.
#
# Safe by default: shows what would change. Add --apply to update the sites.
#
# Usage:
#   cloudflare-plugin-keys.sh                   # dry run, all WordPress vhosts
#   cloudflare-plugin-keys.sh --apply           # update the plugin settings
#   cloudflare-plugin-keys.sh site1 --apply     # only these vhosts
#   cloudflare-plugin-keys.sh --no-verify       # skip checking tokens against Cloudflare first
#   cloudflare-plugin-keys.sh --rollback FILE --apply   # restore the values saved by an earlier --apply
#
# Key file (~/.site-setup/cloudflare-plugin-keys, chmod 600), one Cloudflare account per line:
#   # account_id                        api_token                                 email (optional)
#   9f1e2d3c4b5a69788776655443322110    AbCdEf0123456789AbCdEf0123456789AbCdEf01
#   1234567890abcdef1234567890abcdef    ZyXwVu9876543210ZyXwVu9876543210ZyXwVu98  ops@example.com
#
# The zone/account lookup uses the usual credentials in ~/.site-setup/creds (cf_token or cf_email + cf_key).

set -uo pipefail

VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"
CREDS_FILE="$HOME/.site-setup/creds"
KEYS_FILE="$HOME/.site-setup/cloudflare-plugin-keys"
BACKUP_DIR="$HOME/.site-setup/cloudflare-plugin-backups"   # previous plugin values, for --rollback
WP_CLI="/usr/local/bin/wp"
PLUGIN_SLUG="cloudflare"
KEY_OPTION="cloudflare_api_key"
EMAIL_OPTION="cloudflare_api_email"
CF_TIMEOUT=20
CF_DELAY=0.15
WP_TIMEOUT=120

APPLY=0 VERIFY=1 ROLLBACK=""
TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)     APPLY=1 ;;
        --no-verify) VERIFY=0 ;;
        --rollback)  ROLLBACK="${2:-}"; shift ;;
        -h|--help)   sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)          echo "Unknown option: $1" >&2; exit 1 ;;
        *)           TARGETS+=("$1") ;;
    esac
    shift
done

for cmd in jq curl sudo timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd is required" >&2; exit 1; }
done
[[ -x "$WP_CLI" ]] || { echo "ERROR: WP-CLI not found at $WP_CLI" >&2; exit 1; }

mask() { local v="$1"; [[ -z "$v" ]] && echo "(empty)" || echo "…${v: -4}"; }

# Run WP-CLI as the site owner without loading plugins/themes
site_wp() {
    local vhost="$1"; shift
    timeout "$WP_TIMEOUT" sudo -u "$vhost" "$WP_CLI" --path="/home/$vhost/public_html" \
        --no-color --skip-plugins --skip-themes "$@"
}

# Write an option from a variable via STDIN, so the token never appears in the process list
set_option() {
    local vhost="$1" option="$2" value="$3"
    printf '%s' "$value" | site_wp "$vhost" option update "$option" >/dev/null 2>"$WORK/err"
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077

# ---------------------------------------------------------------------------
# Rollback mode: restore values from a backup file written by --apply
# ---------------------------------------------------------------------------
if [[ -n "$ROLLBACK" ]]; then
    [[ -f "$ROLLBACK" ]] || { echo "ERROR: backup file not found: $ROLLBACK" >&2; exit 1; }
    echo "Restoring plugin settings from $ROLLBACK $([[ $APPLY -eq 1 ]] || echo '(dry run - add --apply)')"
    n=0
    while IFS=$'\t' read -r VHOST OLD_KEY OLD_EMAIL; do
        [[ -z "$VHOST" || "$VHOST" == \#* ]] && continue
        [[ "$OLD_KEY" == "<empty>" ]] && OLD_KEY=""
        [[ "$OLD_EMAIL" == "<empty>" ]] && OLD_EMAIL=""
        if [[ $APPLY -eq 1 ]]; then
            set_option "$VHOST" "$KEY_OPTION" "$OLD_KEY" && echo "  $VHOST: key restored to $(mask "$OLD_KEY")" \
                || echo "  $VHOST: FAILED - $(head -c 200 "$WORK/err")"
            [[ "$OLD_EMAIL" != "-" ]] && set_option "$VHOST" "$EMAIL_OPTION" "$OLD_EMAIL"
        else
            echo "  $VHOST: would restore key $(mask "$OLD_KEY")"
        fi
        n=$((n + 1))
    done < "$ROLLBACK"
    echo "$n site(s)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Load credentials and the account -> token map
# ---------------------------------------------------------------------------
cf_token="" cf_email="" cf_key=""
# shellcheck disable=SC1090
[[ -f "$CREDS_FILE" ]] && source "$CREDS_FILE"
if [[ -n "${cf_token:-}" ]]; then
    CF_AUTH=(-H "Authorization: Bearer $cf_token")
elif [[ -n "${cf_email:-}" && -n "${cf_key:-}" ]]; then
    CF_AUTH=(-H "X-Auth-Email: $cf_email" -H "X-Auth-Key: $cf_key")
else
    echo "ERROR: no Cloudflare credentials in $CREDS_FILE (needed to look up each site's account)" >&2
    exit 1
fi

[[ -f "$KEYS_FILE" ]] || { echo "ERROR: key file not found: $KEYS_FILE" >&2; exit 1; }
if [[ $(stat -c '%a' "$KEYS_FILE") != "600" && $(stat -c '%a' "$KEYS_FILE") != "400" ]]; then
    echo "WARNING: $KEYS_FILE is readable by others - run: chmod 600 $KEYS_FILE" >&2
fi

declare -A TOKEN EMAIL TOKEN_OK
while read -r ACC TOK MAIL _; do
    # Tolerate Windows line endings and quoted values
    ACC="${ACC//$'\r'/}"; TOK="${TOK//$'\r'/}"; MAIL="${MAIL//$'\r'/}"
    TOK="${TOK#[\"\']}"; TOK="${TOK%[\"\']}"; MAIL="${MAIL#[\"\']}"; MAIL="${MAIL%[\"\']}"
    [[ -z "$ACC" || "$ACC" == \#* ]] && continue
    if [[ ! "$ACC" =~ ^[0-9a-f]{32}$ ]]; then echo "WARNING: skipping key file line - '$ACC' is not an account ID" >&2; continue; fi
    [[ -n "$TOK" ]] || { echo "WARNING: no token for account $ACC" >&2; continue; }
    TOKEN[$ACC]="$TOK"
    EMAIL[$ACC]="${MAIL:-}"
done < "$KEYS_FILE"
[[ ${#TOKEN[@]} -gt 0 ]] || { echo "ERROR: no accounts in $KEYS_FILE" >&2; exit 1; }

cf_get() {   # cf_get PATH [TOKEN]  (default: lookup credentials)
    sleep "$CF_DELAY"
    if [[ -n "${2:-}" ]]; then
        curl -sS --max-time "$CF_TIMEOUT" --retry 2 -H "Authorization: Bearer $2" "https://api.cloudflare.com/client/v4/$1"
    else
        curl -sS --max-time "$CF_TIMEOUT" --retry 2 -H "Content-Type: application/json" "${CF_AUTH[@]}" "https://api.cloudflare.com/client/v4/$1"
    fi
}
cf_ok() { jq -e '.success == true' <<< "$1" >/dev/null 2>&1; }

zone_candidates() {
    local name="${1#www.}"
    while [[ "$name" == *.* ]]; do echo "$name"; name="${name#*.}"; done
}

# Check each token is active before pushing it anywhere
for ACC in "${!TOKEN[@]}"; do
    if [[ $VERIFY -eq 0 ]]; then TOKEN_OK[$ACC]=1; continue; fi
    TOK="${TOKEN[$ACC]}"
    # User-owned tokens verify at /user/tokens/verify, account-owned tokens at /accounts/<id>/tokens/verify
    RESP=$(cf_get "user/tokens/verify" "$TOK")
    if ! { cf_ok "$RESP" && [[ $(jq -r '.result.status' <<< "$RESP") == "active" ]]; }; then
        RESP=$(cf_get "accounts/$ACC/tokens/verify" "$TOK")
    fi
    if cf_ok "$RESP" && [[ $(jq -r '.result.status' <<< "$RESP") == "active" ]]; then
        TOKEN_OK[$ACC]=1
    else
        TOKEN_OK[$ACC]=0
        HINT=""
        [[ "$TOK" =~ ^[0-9a-f]{37}$ ]] && HINT=" - this looks like a Global API Key, not an API token"
        [[ ${#TOK} -ne 40 && -z "$HINT" ]] && HINT=" - it is ${#TOK} characters long; API tokens are 40"
        echo "WARNING: token for account $ACC (…${TOK: -4}) is not valid/active ($(jq -r '[.errors[]?.message] | join("; ")' <<< "$RESP" 2>/dev/null))$HINT - its sites will be skipped" >&2
    fi
done

# ---------------------------------------------------------------------------
# Sites
# ---------------------------------------------------------------------------
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    DIRS=(); for t in "${TARGETS[@]}"; do DIRS+=("$VHOST_CONFIG_DIR/$t"); done
else
    DIRS=("$VHOST_CONFIG_DIR"/*)
fi

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/$STAMP.tsv"
LOG_FILE="./cloudflare-plugin-keys-$STAMP.csv"
echo "vhost,domain,zone_id,account_id,old_key,new_key,result" > "$LOG_FILE"
if [[ $APPLY -eq 1 ]]; then
    install -d -m 0700 "$BACKUP_DIR"
    printf '# vhost\told %s\told %s  (written %s)\n' "$KEY_OPTION" "$EMAIL_OPTION" "$STAMP" > "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE"
fi

echo "Mode: $([[ $APPLY -eq 1 ]] && echo APPLY || echo 'DRY RUN')   Accounts in key file: ${#TOKEN[@]}"
echo
printf '%-22s %-28s %-34s %-10s %-10s %s\n' "VHOST" "DOMAIN" "ACCOUNT ID" "CURRENT" "NEW" "RESULT"
n_changed=0 n_would=0 n_same=0 n_skip=0 n_err=0

for VHOST_DIR in "${DIRS[@]}"; do
    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue
    VHOST="${VHOST_DIR##*/}"
    [[ -f "/home/$VHOST/public_html/wp-config.php" ]] || continue

    DOMAIN=$(grep -E '^\s*vhAliases\s+' "$VHOST_DIR/vhconf.conf" | head -n 1 \
        | sed -E 's/^[[:space:]]*vhAliases[[:space:]]+//' | tr ',' '\n' | tr -d ' \t"\r' \
        | grep -v -e '^$' -e '^\*$' -e '\$' | head -n 1)
    DOMAIN="${DOMAIN:-$VHOST}"; DOMAIN="${DOMAIN#www.}"

    ZID="" ACC="" OLD="" NEW="" RESULT=""
    report() {
        printf '%-22s %-28s %-34s %-10s %-10s %s\n' "$VHOST" "$DOMAIN" "${ACC:--}" "$(mask "$OLD")" "$( [[ -n "$NEW" ]] && mask "$NEW" || echo -)" "$RESULT"
        printf '%s,%s,%s,%s,%s,%s,"%s"\n' "$VHOST" "$DOMAIN" "$ZID" "$ACC" "$(mask "$OLD")" "$( [[ -n "$NEW" ]] && mask "$NEW")" "$RESULT" >> "$LOG_FILE"
    }

    # Is the Cloudflare plugin installed?
    if ! site_wp "$VHOST" plugin is-installed "$PLUGIN_SLUG" >/dev/null 2>&1; then
        RESULT="skipped: Cloudflare plugin not installed"; n_skip=$((n_skip + 1)); report; continue
    fi

    # Zone -> account
    while read -r C; do
        RESP=$(cf_get "zones?name=$C") || break
        if cf_ok "$RESP" && [[ $(jq '.result | length' <<< "$RESP") -gt 0 ]]; then
            ZID=$(jq -r '.result[0].id' <<< "$RESP"); ACC=$(jq -r '.result[0].account.id' <<< "$RESP"); break
        fi
    done < <(zone_candidates "$DOMAIN")
    OLD=$(site_wp "$VHOST" option get "$KEY_OPTION" 2>/dev/null)

    if [[ -z "$ACC" ]]; then
        RESULT="skipped: no Cloudflare zone found"; n_skip=$((n_skip + 1)); report; continue
    fi
    if [[ -z "${TOKEN[$ACC]:-}" ]]; then
        RESULT="skipped: no token for this account in key file"; n_skip=$((n_skip + 1)); report; continue
    fi
    if [[ "${TOKEN_OK[$ACC]}" != "1" ]]; then
        RESULT="skipped: token for this account is not valid"; n_skip=$((n_skip + 1)); report; continue
    fi
    NEW="${TOKEN[$ACC]}"

    # The token must be able to see this zone, or the plugin won't work
    if [[ $VERIFY -eq 1 ]] && ! cf_ok "$(cf_get "zones/$ZID" "$NEW")"; then
        RESULT="skipped: token has no access to zone $ZID"; n_skip=$((n_skip + 1)); report; continue
    fi

    WANT_EMAIL="${EMAIL[$ACC]}"
    OLD_EMAIL=$(site_wp "$VHOST" option get "$EMAIL_OPTION" 2>/dev/null)
    if [[ "$OLD" == "$NEW" && ( -z "$WANT_EMAIL" || "$OLD_EMAIL" == "$WANT_EMAIL" ) ]]; then
        RESULT="ok (already set)"; n_same=$((n_same + 1)); report; continue
    fi

    if [[ $APPLY -eq 0 ]]; then
        RESULT="would update$([[ -n "$WANT_EMAIL" && "$OLD_EMAIL" != "$WANT_EMAIL" ]] && echo " (and email)")"
        n_would=$((n_would + 1)); report; continue
    fi

    # "<empty>" marks a value that was blank, "-" an email we didn't touch (tabs would collapse empty fields)
    printf '%s\t%s\t%s\n' "$VHOST" "${OLD:-<empty>}" "$([[ -n "$WANT_EMAIL" ]] && echo "${OLD_EMAIL:-<empty>}" || echo -)" >> "$BACKUP_FILE"
    if set_option "$VHOST" "$KEY_OPTION" "$NEW" && [[ "$(site_wp "$VHOST" option get "$KEY_OPTION" 2>/dev/null)" == "$NEW" ]]; then
        RESULT="updated"
        if [[ -n "$WANT_EMAIL" && "$OLD_EMAIL" != "$WANT_EMAIL" ]]; then
            set_option "$VHOST" "$EMAIL_OPTION" "$WANT_EMAIL" && RESULT="updated (key + email)" || RESULT="updated key; email FAILED"
        fi
        n_changed=$((n_changed + 1))
    else
        RESULT="FAILED: $(head -c 150 "$WORK/err" | tr '\n' ' ')"; n_err=$((n_err + 1))
    fi
    report
done

echo
if [[ $APPLY -eq 1 ]]; then
    echo "Updated: $n_changed   Already set: $n_same   Skipped: $n_skip   Errors: $n_err"
    echo "Previous values saved to $BACKUP_FILE (restore with --rollback $BACKUP_FILE --apply)"
else
    echo "Would update: $n_would   Already set: $n_same   Skipped: $n_skip"
    [[ $n_would -gt 0 ]] && echo "Run again with --apply to make these changes."
fi
echo "Log (keys masked): $LOG_FILE"
[[ $n_err -gt 0 ]] && exit 2
exit 0
