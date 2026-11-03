#!/bin/bash
#
# wordfence-scan.sh
# Runs Wordfence CLI vulnerability + malware scans for every WordPress vhost,
# stores the reports for the dashboard, and alerts Slack when findings change.
#
# Usage:
#   wordfence-scan.sh                 # all WordPress vhosts
#   wordfence-scan.sh site1 site2     # only these vhosts
#   wordfence-scan.sh --no-slack      # scan and store reports, no Slack messages
#   wordfence-scan.sh --notify-all    # alert for every site with findings, even if unchanged
#
# Slack settings live in ~/.site-setup/creds (never in this file):
#   slack_webhook_url="https://hooks.slack.com/services/..."   # messages
#   slack_bot_token="xoxb-..."                                 # optional: attach the CSV reports
#   slack_channel_id="C0123456789"                             # channel ID (not #name) for attachments
# The bot needs the files:write scope and must be a member of the channel.

set -uo pipefail

SCRIPT_VERSION="2.1.0"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"
CREDS_FILE="$HOME/.site-setup/creds"
WORDFENCE="wordfence"
LOCK_FILE="/var/lock/wordfence-scan.lock"

# Where the dashboard reads reports (one file per vhost, latest scan)
MALWARE_REPORT_DIR="/nas/metrics/public_html/malware-reports"
VULN_REPORT_DIR="/nas/metrics/public_html/vuln-reports"
STATUS_DIR="/nas/metrics/public_html/wordfence-status"
# Dated copies of every scan, kept for HISTORY_DAYS
HISTORY_DIR="/nas/metrics/wordfence-history"
HISTORY_DAYS=30
# Also keep the reports in /home/<vhost>/ as before (1 = yes)
KEEP_LOCAL_COPY=1

REPORT_OWNER="root:nogroup"
REPORT_MODE="0640"

SCAN_TIMEOUT=3600     # seconds per scan per site

# What the malware scan does with wp-content/uploads (usually the slowest part: thousands of media files)
#   php-only  skip media, but still scan PHP/script files hidden in uploads (default: fast, keeps backdoor detection)
#   skip      don't scan uploads at all
#   full      scan everything, like the original script
UPLOADS_MODE="php-only"

# Scan arguments (same as the original script)
VULN_ARGS=(vuln-scan -q --output-format csv)
MALWARE_ARGS=(malware-scan -q -x "index.php" --no-cache --output-format csv)
# MALWARE_ARGS=(malware-scan -q -x "index.php" --exclude-files-pattern ".*\.html$" --no-cache --output-format csv)

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
SLACK=1
NOTIFY_ALL=0
TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-slack)   SLACK=0 ;;
        --notify-all) NOTIFY_ALL=1 ;;
        -h|--help)    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           echo "Unknown option: $1" >&2; exit 1 ;;
        *)            TARGETS+=("$1") ;;
    esac
    shift
done

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

for cmd in jq curl timeout flock md5sum "$WORDFENCE"; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command not found: $cmd" >&2; exit 1; }
done

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another scan is already running ($LOCK_FILE). Exiting."; exit 0; }

slack_webhook_url="" slack_bot_token="" slack_channel_id=""
# shellcheck disable=SC1090
[[ -f "$CREDS_FILE" ]] && source "$CREDS_FILE"
if [[ $SLACK -eq 1 && -z "$slack_webhook_url" && ( -z "$slack_bot_token" || -z "$slack_channel_id" ) ]]; then
    warn "No Slack settings in $CREDS_FILE - running without notifications."
    SLACK=0
fi

for d in "$MALWARE_REPORT_DIR" "$VULN_REPORT_DIR" "$STATUS_DIR" "$HISTORY_DIR"; do
    install -d -m 0755 "$d"
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Slack
# ---------------------------------------------------------------------------
# Plain message: webhook if set, otherwise chat.postMessage with the bot token
slack_message() {
    local text="$1" resp
    [[ $SLACK -eq 1 ]] || return 0
    if [[ -n "$slack_webhook_url" ]]; then
        resp=$(curl -sS --max-time 20 -H 'Content-Type: application/json' \
            --data "$(jq -nc --arg t "$text" '{text: $t}')" "$slack_webhook_url")
        [[ "$resp" == "ok" ]] || warn "Slack webhook failed: $resp"
    else
        resp=$(curl -sS --max-time 20 -H "Authorization: Bearer $slack_bot_token" \
            -H 'Content-Type: application/json; charset=utf-8' \
            --data "$(jq -nc --arg c "$slack_channel_id" --arg t "$text" '{channel: $c, text: $t}')" \
            https://slack.com/api/chat.postMessage)
        jq -e '.ok' <<< "$resp" >/dev/null 2>&1 || warn "Slack chat.postMessage failed: $resp"
    fi
}

# Message with files attached (Slack's current upload flow; files.upload was retired).
# Falls back to a plain message if no bot token/channel is configured or the upload fails.
slack_files() {
    local text="$1"; shift
    local files_json="[]" f resp url id
    [[ $SLACK -eq 1 ]] || return 0
    if [[ -z "$slack_bot_token" || -z "$slack_channel_id" ]]; then
        slack_message "$text"
        return
    fi
    for f in "$@"; do
        [[ -s "$f" ]] || continue
        resp=$(curl -sS --max-time 30 -H "Authorization: Bearer $slack_bot_token" \
            -F "filename=$(basename "$f")" -F "length=$(stat -c %s "$f")" \
            https://slack.com/api/files.getUploadURLExternal)
        url=$(jq -r '.upload_url // empty' <<< "$resp" 2>/dev/null)
        id=$(jq -r '.file_id // empty' <<< "$resp" 2>/dev/null)
        if [[ -z "$url" || -z "$id" ]]; then
            warn "Slack getUploadURLExternal failed: $resp"
            continue
        fi
        if ! curl -sS --max-time 120 -o /dev/null -w '%{http_code}' -F "file=@$f" "$url" | grep -q '^200$'; then
            warn "Slack upload of $(basename "$f") failed"
            continue
        fi
        files_json=$(jq -c --arg id "$id" --arg t "$(basename "$f")" '. + [{id: $id, title: $t}]' <<< "$files_json")
    done
    if [[ "$files_json" == "[]" ]]; then
        slack_message "$text"
        return
    fi
    resp=$(curl -sS --max-time 30 -H "Authorization: Bearer $slack_bot_token" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data "$(jq -nc --argjson files "$files_json" --arg c "$slack_channel_id" --arg t "$text" \
            '{files: $files, channel_id: $c, initial_comment: $t}')" \
        https://slack.com/api/files.completeUploadExternal)
    if ! jq -e '.ok' <<< "$resp" >/dev/null 2>&1; then
        warn "Slack completeUploadExternal failed: $resp"
        slack_message "$text"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
count_rows() { [[ -s "$1" ]] && grep -c '[^[:space:]]' "$1" || echo 0; }

# Order-independent fingerprint of a report, to tell whether findings changed
fingerprint() { [[ -s "$1" ]] && sort "$1" | md5sum | cut -d' ' -f1 || echo "empty"; }

# Run one scan: run_scan OUT_FILE WORDFENCE_ARGS... -- PATHS...
# Prints "exit_code seconds". The report file always exists afterwards.
run_scan() {
    local out="$1"; shift
    local args=() start code
    while [[ $# -gt 0 && "$1" != "--" ]]; do args+=("$1"); shift; done
    shift
    start=$(date +%s)
    : > "$out"
    timeout "$SCAN_TIMEOUT" "$WORDFENCE" "${args[@]}" --output-path "$out" "$@" > "$WORK/scan.log" 2>&1
    code=$?
    [[ -f "$out" ]] || : > "$out"
    echo "$code $(( $(date +%s) - start ))"
}

# Paths for the malware scan (NUL-separated), leaving out wp-content/uploads according to UPLOADS_MODE
malware_targets() {
    local root="$1" uploads="$1/wp-content/uploads"
    if [[ "$UPLOADS_MODE" == "full" || ! -e "$uploads" ]]; then
        printf '%s\0' "$root"
        return
    fi
    find -H "$root" -mindepth 1 -maxdepth 1 ! -name wp-content -print0                 # everything but wp-content
    [[ -d "$root/wp-content" ]] && \
        find -H "$root/wp-content" -mindepth 1 -maxdepth 1 ! -name uploads -print0     # wp-content but uploads
    if [[ "$UPLOADS_MODE" == "php-only" ]]; then
        # Executable code has no business in uploads; *.php* also catches tricks like shell.php.jpg
        find -H "$uploads" -type f \( -iname '*.php*' -o -iname '*.phtml' -o -iname '*.pht' -o -iname '*.phar' \
            -o -iname '*.inc' -o -iname '*.cgi' -o -iname '*.pl' -o -iname '*.py' -o -iname '*.sh' \
            -o -name '.htaccess' -o -name '.user.ini' \) -print0 2>/dev/null
    fi
}

# Copy a report into place atomically (so the dashboard never reads a half-written file)
publish() {
    local src="$1" dest="$2" tmp
    tmp=$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX") || return 1
    cp "$src" "$tmp" && chown "$REPORT_OWNER" "$tmp" 2>/dev/null; chmod "$REPORT_MODE" "$tmp"
    mv -f "$tmp" "$dest"
}

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    DIRS=(); for t in "${TARGETS[@]}"; do DIRS+=("$VHOST_CONFIG_DIR/$t"); done
else
    DIRS=("$VHOST_CONFIG_DIR"/*)
fi

TODAY=$(date +%F)
n_sites=0 n_malware=0 n_vuln=0 n_errors=0
SUMMARY_LINES=()

for VHOST_DIR in "${DIRS[@]}"; do
    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue
    VHOST="${VHOST_DIR##*/}"
    WEB_ROOT="/home/$VHOST/public_html"
    if [[ ! -f "$WEB_ROOT/wp-config.php" ]]; then
        log "Skipping non-WordPress vhost: $VHOST"
        continue
    fi
    n_sites=$((n_sites + 1))
    log "Scanning $VHOST"

    MAL_OUT="$WORK/$VHOST-malware.csv"
    VULN_OUT="$WORK/$VHOST-vuln.csv"

    read -r VULN_CODE VULN_SECS < <(run_scan "$VULN_OUT" "${VULN_ARGS[@]}" -- "$WEB_ROOT")
    VULN_LOG=$(tail -c 500 "$WORK/scan.log")
    mapfile -d '' MAL_TARGETS < <(malware_targets "$WEB_ROOT")
    if [[ "$UPLOADS_MODE" != "full" && -e "$WEB_ROOT/wp-content/uploads" ]]; then
        UP_FILES=0
        for t in "${MAL_TARGETS[@]}"; do [[ "$t" == "$WEB_ROOT/wp-content/uploads/"* ]] && UP_FILES=$((UP_FILES + 1)); done
        log "  uploads: $([[ "$UPLOADS_MODE" == "skip" ]] && echo "skipped" || echo "media skipped, $UP_FILES script file(s) included")"
    fi
    read -r MAL_CODE MAL_SECS < <(run_scan "$MAL_OUT" "${MALWARE_ARGS[@]}" -- "${MAL_TARGETS[@]}")
    MAL_LOG=$(tail -c 500 "$WORK/scan.log")

    MAL_COUNT=$(count_rows "$MAL_OUT")
    VULN_COUNT=$(count_rows "$VULN_OUT")

    # A non-zero exit with an empty report usually means the scan itself failed
    # (licence, timeout = 124, unreadable path). With findings, Wordfence may also exit non-zero.
    MAL_STATE="ok" VULN_STATE="ok"
    [[ "$MAL_CODE" -ne 0 && "$MAL_COUNT" -eq 0 ]] && MAL_STATE="error"
    [[ "$VULN_CODE" -ne 0 && "$VULN_COUNT" -eq 0 ]] && VULN_STATE="error"
    [[ "$MAL_CODE" -eq 124 ]] && MAL_STATE="timeout"
    [[ "$VULN_CODE" -eq 124 ]] && VULN_STATE="timeout"

    # Compare with the previous published report before replacing it
    MAL_CHANGED=0 VULN_CHANGED=0
    [[ "$(fingerprint "$MAL_OUT")" != "$(fingerprint "$MALWARE_REPORT_DIR/$VHOST.csv")" ]] && MAL_CHANGED=1
    [[ "$(fingerprint "$VULN_OUT")" != "$(fingerprint "$VULN_REPORT_DIR/$VHOST.csv")" ]] && VULN_CHANGED=1

    # Publish for the dashboard. A failed scan keeps the previous report instead of showing "clean".
    [[ "$MAL_STATE" == "ok" ]]  && publish "$MAL_OUT"  "$MALWARE_REPORT_DIR/$VHOST.csv"
    [[ "$VULN_STATE" == "ok" ]] && publish "$VULN_OUT" "$VULN_REPORT_DIR/$VHOST.csv"

    # Dated history copies
    install -d -m 0750 "$HISTORY_DIR/$VHOST"
    cp "$MAL_OUT"  "$HISTORY_DIR/$VHOST/$TODAY-malware.csv"
    cp "$VULN_OUT" "$HISTORY_DIR/$VHOST/$TODAY-vuln.csv"

    # Original locations in the site's home folder
    if [[ "$KEEP_LOCAL_COPY" == "1" ]]; then
        cp "$MAL_OUT"  "/home/$VHOST/malware-scan.csv"
        cp "$VULN_OUT" "/home/$VHOST/vuln-scan.csv"
    fi

    # Status file for the dashboard (scan time, counts, failures)
    jq -n \
        --arg site "$VHOST" --arg at "$(date --iso-8601=seconds)" --arg v "$SCRIPT_VERSION" \
        --argjson mc "$MAL_COUNT" --argjson mcode "$MAL_CODE" --argjson ms "$MAL_SECS" --arg mstate "$MAL_STATE" --arg mlog "$MAL_LOG" \
        --argjson vc "$VULN_COUNT" --argjson vcode "$VULN_CODE" --argjson vs "$VULN_SECS" --arg vstate "$VULN_STATE" --arg vlog "$VULN_LOG" \
        '{site: $site, scanned_at: $at, script_version: $v,
          malware: {state: $mstate, findings: $mc, exit_code: $mcode, seconds: $ms, log: (if $mstate == "ok" then null else $mlog end)},
          vuln:    {state: $vstate, findings: $vc, exit_code: $vcode, seconds: $vs, log: (if $vstate == "ok" then null else $vlog end)}}' \
        > "$WORK/status.json" && publish "$WORK/status.json" "$STATUS_DIR/$VHOST.json"

    log "  malware: $MAL_COUNT finding(s) [$MAL_STATE, exit $MAL_CODE, ${MAL_SECS}s]   vulnerabilities: $VULN_COUNT [$VULN_STATE, exit $VULN_CODE, ${VULN_SECS}s]"

    # Counters + summary
    [[ "$MAL_COUNT" -gt 0 ]] && n_malware=$((n_malware + 1))
    [[ "$VULN_COUNT" -gt 0 ]] && n_vuln=$((n_vuln + 1))
    if [[ "$MAL_STATE" != "ok" || "$VULN_STATE" != "ok" ]]; then
        n_errors=$((n_errors + 1))
        SUMMARY_LINES+=("• $VHOST: scan failed (malware: $MAL_STATE, vulnerabilities: $VULN_STATE)")
    fi
    if [[ "$MAL_COUNT" -gt 0 || "$VULN_COUNT" -gt 0 ]]; then
        SUMMARY_LINES+=("• $VHOST: $MAL_COUNT malware, $VULN_COUNT vulnerabilit$([[ $VULN_COUNT -eq 1 ]] && echo y || echo ies)")
    fi

    # Alert when findings are new or changed (or always with --notify-all)
    ATTACH=()
    MSG_PARTS=()
    if [[ "$MAL_COUNT" -gt 0 && ( $MAL_CHANGED -eq 1 || $NOTIFY_ALL -eq 1 ) ]]; then
        MSG_PARTS+=(":rotating_light: *$MAL_COUNT malware finding(s)*")
        cp "$MAL_OUT" "$WORK/$VHOST-malware-scan.csv"; ATTACH+=("$WORK/$VHOST-malware-scan.csv")
    fi
    if [[ "$VULN_COUNT" -gt 0 && ( $VULN_CHANGED -eq 1 || $NOTIFY_ALL -eq 1 ) ]]; then
        MSG_PARTS+=(":warning: *$VULN_COUNT vulnerable plugin/theme/core item(s)*, update needed")
        cp "$VULN_OUT" "$WORK/$VHOST-vuln-scan.csv"; ATTACH+=("$WORK/$VHOST-vuln-scan.csv")
    fi
    if [[ ${#MSG_PARTS[@]} -gt 0 ]]; then
        TEXT="*$VHOST*"
        for p in "${MSG_PARTS[@]}"; do TEXT+=$'\n'"$p"; done
        slack_files "$TEXT" "${ATTACH[@]}"
    elif [[ "$MAL_COUNT" -eq 0 && "$VULN_COUNT" -eq 0 && "$MAL_STATE" == "ok" && "$VULN_STATE" == "ok" ]]; then
        log "  clean"
    fi
done

# Prune old history
find "$HISTORY_DIR" -type f -name '*.csv' -mtime +"$HISTORY_DAYS" -delete 2>/dev/null

# Run summary
SUMMARY="Wordfence scan finished: $n_sites site(s) scanned, $n_malware with malware, $n_vuln with vulnerabilities, $n_errors failed."
log "$SUMMARY"
if [[ ${#SUMMARY_LINES[@]} -gt 0 ]]; then
    slack_message "$SUMMARY"$'\n'"$(printf '%s\n' "${SUMMARY_LINES[@]}")"
fi

[[ $n_errors -gt 0 ]] && exit 2
exit 0
