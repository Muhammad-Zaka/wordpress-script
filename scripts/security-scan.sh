#!/bin/bash
#
# security-scan.sh
# Free replacement for the Wordfence CLI scans (Wordfence CLI was discontinued; the free
# version reached end of life on 14 Oct 2026).
#
#   Vulnerabilities  installed core/plugin/theme versions (via WP-CLI) checked against the
#                    free WPVulnerability database (https://www.wpvulnerability.net)
#   Modified files   WP-CLI checksums: core files and wordpress.org plugins compared with the originals
#   Malware          ClamAV with Linux Malware Detect (maldet) signatures, one scan for all sites
#
# Reports go to the same folders the dashboard reads, with Slack alerts when findings change.
#
# Usage:
#   security-scan.sh                 # all WordPress vhosts
#   security-scan.sh site1 site2     # only these vhosts
#   security-scan.sh --no-slack      # no Slack messages
#   security-scan.sh --notify-all    # alert for every site with findings, even if unchanged
#   security-scan.sh --no-malware    # skip the ClamAV scan (vulnerabilities + checksums only)
#
# Needs: wp (WP-CLI), jq, curl, php; for malware: clamscan (ClamAV) and, recommended, maldet signatures.
# Slack settings in ~/.site-setup/creds: slack_webhook_url, slack_bot_token, slack_channel_id

set -uo pipefail

SCRIPT_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
VHOST_CONFIG_DIR="/usr/local/lsws/conf/vhosts"
CREDS_FILE="$HOME/.site-setup/creds"
WP_CLI="/usr/local/bin/wp"
LOCK_FILE="/var/lock/security-scan.lock"

# Where the dashboard reads reports (one file per vhost, latest scan)
MALWARE_REPORT_DIR="/nas/metrics/public_html/malware-reports"
VULN_REPORT_DIR="/nas/metrics/public_html/vuln-reports"
STATUS_DIR="/nas/metrics/public_html/security-status"
HISTORY_DIR="/nas/metrics/security-history"
HISTORY_DAYS=30
KEEP_LOCAL_COPY=1                       # also write /home/<vhost>/{malware,vuln}-scan.csv
REPORT_OWNER="root:nogroup"
REPORT_MODE="0640"

# Vulnerability database
VULN_API="https://www.wpvulnerability.net"
VULN_CACHE_DIR="/var/cache/security-scan"
VULN_CACHE_HOURS=12                     # reuse API answers this long (many sites share plugins)
API_DELAY=0.2

# Malware scan (ClamAV)
CLAMSCAN="clamscan"
CLAM_DB_DIR="/var/lib/clamav"           # ClamAV's own signatures (kept fresh by freshclam)
MALDET_SIGS_DIR="/usr/local/maldetect/sigs"   # Linux Malware Detect signatures (much better for PHP web shells)
CLAM_TIMEOUT=14400                      # one scan for all sites
CLAM_OPTS=(--recursive --infected --no-summary --max-filesize=25M --max-scansize=100M)

# What the malware scan does with wp-content/uploads
#   php-only  skip media, but scan PHP/script files hidden in uploads (default)
#   skip      don't scan uploads at all
#   full      scan everything
UPLOADS_MODE="php-only"

WP_TIMEOUT=300

# ---------------------------------------------------------------------------
# Arguments / setup
# ---------------------------------------------------------------------------
SLACK=1 NOTIFY_ALL=0 MALWARE=1
TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-slack)   SLACK=0 ;;
        --notify-all) NOTIFY_ALL=1 ;;
        --no-malware) MALWARE=0 ;;
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)           echo "Unknown option: $1" >&2; exit 1 ;;
        *)            TARGETS+=("$1") ;;
    esac
    shift
done

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

for cmd in jq curl php timeout flock md5sum sudo; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: required command not found: $cmd" >&2; exit 1; }
done
[[ -x "$WP_CLI" ]] || { echo "ERROR: WP-CLI not found at $WP_CLI" >&2; exit 1; }

if [[ $MALWARE -eq 1 ]] && ! command -v "$CLAMSCAN" >/dev/null 2>&1; then
    warn "ClamAV ($CLAMSCAN) is not installed - skipping the malware scan. See README for setup."
    MALWARE=0
fi

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another scan is already running ($LOCK_FILE). Exiting."; exit 0; }

slack_webhook_url="" slack_bot_token="" slack_channel_id=""
# shellcheck disable=SC1090
[[ -f "$CREDS_FILE" ]] && source "$CREDS_FILE"
if [[ $SLACK -eq 1 && -z "$slack_webhook_url" && ( -z "$slack_bot_token" || -z "$slack_channel_id" ) ]]; then
    warn "No Slack settings in $CREDS_FILE - running without notifications."
    SLACK=0
fi

for d in "$MALWARE_REPORT_DIR" "$VULN_REPORT_DIR" "$STATUS_DIR" "$HISTORY_DIR" "$VULN_CACHE_DIR"; do
    install -d -m 0755 "$d"
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Slack (message via webhook or bot; files via Slack's current external upload flow)
# ---------------------------------------------------------------------------
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

slack_files() {
    local text="$1"; shift
    local files_json="[]" f resp url id
    [[ $SLACK -eq 1 ]] || return 0
    if [[ -z "$slack_bot_token" || -z "$slack_channel_id" ]]; then slack_message "$text"; return; fi
    for f in "$@"; do
        [[ -s "$f" ]] || continue
        resp=$(curl -sS --max-time 30 -H "Authorization: Bearer $slack_bot_token" \
            -F "filename=$(basename "$f")" -F "length=$(stat -c %s "$f")" \
            https://slack.com/api/files.getUploadURLExternal)
        url=$(jq -r '.upload_url // empty' <<< "$resp" 2>/dev/null)
        id=$(jq -r '.file_id // empty' <<< "$resp" 2>/dev/null)
        if [[ -z "$url" || -z "$id" ]]; then warn "Slack getUploadURLExternal failed: $resp"; continue; fi
        curl -sS --max-time 120 -o /dev/null -w '%{http_code}' -F "file=@$f" "$url" | grep -q '^200$' \
            || { warn "Slack upload of $(basename "$f") failed"; continue; }
        files_json=$(jq -c --arg id "$id" --arg t "$(basename "$f")" '. + [{id: $id, title: $t}]' <<< "$files_json")
    done
    [[ "$files_json" == "[]" ]] && { slack_message "$text"; return; }
    resp=$(curl -sS --max-time 30 -H "Authorization: Bearer $slack_bot_token" \
        -H 'Content-Type: application/json; charset=utf-8' \
        --data "$(jq -nc --argjson files "$files_json" --arg c "$slack_channel_id" --arg t "$text" \
            '{files: $files, channel_id: $c, initial_comment: $t}')" \
        https://slack.com/api/files.completeUploadExternal)
    jq -e '.ok' <<< "$resp" >/dev/null 2>&1 || { warn "Slack completeUploadExternal failed: $resp"; slack_message "$text"; }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Rows excluding the header line
count_rows() { [[ -s "$1" ]] && { tail -n +2 "$1" | grep -c '[^[:space:]]'; } || echo 0; }
fingerprint() { [[ -s "$1" ]] && tail -n +2 "$1" | sort | md5sum | cut -d' ' -f1 || echo "empty"; }

publish() {
    local src="$1" dest="$2" tmp
    tmp=$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX") || return 1
    cp "$src" "$tmp"; chown "$REPORT_OWNER" "$tmp" 2>/dev/null; chmod "$REPORT_MODE" "$tmp"
    mv -f "$tmp" "$dest"
}

csv_field() { local v="${1//\"/\"\"}"; printf '"%s"' "$v"; }

# Fetch (or reuse cached) WPVulnerability data: vuln_data TYPE SLUG -> prints cache file path
vuln_data() {
    local type="$1" slug="$2" f
    [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] || { echo ""; return; }
    f="$VULN_CACHE_DIR/$type-$slug.json"
    if [[ ! -s "$f" ]] || [[ -n $(find "$f" -mmin +$((VULN_CACHE_HOURS * 60)) 2>/dev/null) ]]; then
        sleep "$API_DELAY"
        if curl -sS --max-time 20 --retry 2 -o "$f.tmp" "$VULN_API/$type/$slug/" && jq -e . "$f.tmp" >/dev/null 2>&1; then
            mv -f "$f.tmp" "$f"
        else
            rm -f "$f.tmp"
            [[ -s "$f" ]] || { echo "ERR"; return; }    # no fresh data and no older cache
        fi
    fi
    echo "$f"
}

# PHP matcher: reads items TSV (type, slug, version, datafile) and writes vulnerability CSV rows.
cat > "$WORK/match.php" <<'PHP'
<?php
$ops = ['lt' => '<', 'le' => '<=', 'gt' => '>', 'ge' => '>=', 'eq' => '=='];
$sev = ['c' => 'critical', 'h' => 'high', 'm' => 'medium', 'l' => 'low', 'n' => 'none'];
$out = fopen('php://stdout', 'w');
foreach (file($argv[1], FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    [$type, $slug, $version, $file] = array_pad(explode("\t", $line), 4, '');
    $j = json_decode((string) @file_get_contents($file), true);
    $list = $j['data']['vulnerability'] ?? [];
    if (!is_array($list) || $version === '') continue;
    foreach ($list as $v) {
        $op = $v['operator'] ?? [];
        $hit = true;
        if (!empty($op['min_version']) && isset($ops[$op['min_operator'] ?? '']))
            $hit = $hit && version_compare($version, $op['min_version'], $ops[$op['min_operator']]);
        if (!empty($op['max_version']) && isset($ops[$op['max_operator'] ?? '']))
            $hit = $hit && version_compare($version, $op['max_version'], $ops[$op['max_operator']]);
        if (empty($op['min_version']) && empty($op['max_version']) && empty($op['unfixed']) && $type !== 'core') $hit = false;
        if (!$hit) continue;
        $fixed = !empty($op['unfixed']) && $op['unfixed'] !== '0' ? 'No fix yet'
               : (($op['max_operator'] ?? '') === 'lt' ? $op['max_version'] : (!empty($op['max_version']) ? 'after ' . $op['max_version'] : ''));
        $cvss = $v['impact']['cvss'] ?? [];
        $severity = strtolower((string) ($cvss['severity'] ?? ''));
        $severity = $sev[$severity] ?? $severity;
        if ($severity === '' && isset($cvss['score'])) $severity = 'CVSS ' . $cvss['score'];
        $src = $v['source'][0] ?? [];
        $title = $v['name'] ?? ($src['name'] ?? 'Vulnerability');
        $link = $src['link'] ?? '';
        fputcsv($out, [$type, $slug, $version, $title, $severity, $fixed, $link], ',', '"', '');
    }
}
PHP

# Paths for the malware scan (NUL-separated), leaving out wp-content/uploads according to UPLOADS_MODE
malware_targets() {
    local root="$1" uploads="$1/wp-content/uploads"
    if [[ "$UPLOADS_MODE" == "full" || ! -e "$uploads" ]]; then printf '%s\0' "$root"; return; fi
    find -H "$root" -mindepth 1 -maxdepth 1 ! -name wp-content -print0
    [[ -d "$root/wp-content" ]] && find -H "$root/wp-content" -mindepth 1 -maxdepth 1 ! -name uploads -print0
    if [[ "$UPLOADS_MODE" == "php-only" ]]; then
        find -H "$uploads" -type f \( -iname '*.php*' -o -iname '*.phtml' -o -iname '*.pht' -o -iname '*.phar' \
            -o -iname '*.inc' -o -iname '*.cgi' -o -iname '*.pl' -o -iname '*.py' -o -iname '*.sh' \
            -o -name '.htaccess' -o -name '.user.ini' \) -print0 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Phase 1: per site - vulnerabilities and checksums
# ---------------------------------------------------------------------------
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    DIRS=(); for t in "${TARGETS[@]}"; do DIRS+=("$VHOST_CONFIG_DIR/$t"); done
else
    DIRS=("$VHOST_CONFIG_DIR"/*)
fi

SITES=()
declare -A VULN_STATE VULN_ERR MAL_STATE MAL_ERR
MAL_HEADER="source,file,detection"
VULN_HEADER="type,slug,installed_version,vulnerability,severity,fixed_in,link"

for VHOST_DIR in "${DIRS[@]}"; do
    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue
    VHOST="${VHOST_DIR##*/}"
    WEB_ROOT="/home/$VHOST/public_html"
    [[ -f "$WEB_ROOT/wp-config.php" ]] || { log "Skipping non-WordPress vhost: $VHOST"; continue; }
    SITES+=("$VHOST")
    log "Checking $VHOST"

    # Never load plugins/themes while inspecting a possibly infected site
    wp() { timeout "$WP_TIMEOUT" sudo -u "$VHOST" "$WP_CLI" --path="$WEB_ROOT" --no-color --skip-plugins --skip-themes "$@"; }

    # --- Vulnerabilities ---
    VULN_OUT="$WORK/$VHOST-vuln.csv"; echo "$VULN_HEADER" > "$VULN_OUT"
    ITEMS="$WORK/$VHOST-items.tsv"; : > "$ITEMS"
    VULN_STATE[$VHOST]="ok"; VULN_ERR[$VHOST]=""
    CORE_V=$(wp core version 2>"$WORK/err") || { VULN_STATE[$VHOST]="error"; VULN_ERR[$VHOST]="wp core version: $(head -c 200 "$WORK/err")"; }
    [[ -n "$CORE_V" ]] && printf 'core\twordpress\t%s\t%s\n' "$CORE_V" "$(vuln_data core "$CORE_V")" >> "$ITEMS"
    for KIND in plugin theme; do
        LIST=$(wp "$KIND" list --fields=name,version,status --format=json 2>"$WORK/err") \
            || { VULN_STATE[$VHOST]="error"; VULN_ERR[$VHOST]="wp $KIND list: $(head -c 200 "$WORK/err")"; continue; }
        while IFS=$'\t' read -r SLUG VER; do
            [[ -n "$VER" ]] || continue
            DATA=$(vuln_data "$KIND" "$SLUG")
            [[ "$DATA" == "ERR" ]] && { VULN_STATE[$VHOST]="partial"; VULN_ERR[$VHOST]="vulnerability database unreachable for some items"; continue; }
            [[ -n "$DATA" ]] && printf '%s\t%s\t%s\t%s\n' "$KIND" "$SLUG" "$VER" "$DATA" >> "$ITEMS"
        done < <(jq -r '.[] | select(.status != "dropin" and .status != "must-use") | [.name, .version] | @tsv' <<< "$LIST" 2>/dev/null)
    done
    php "$WORK/match.php" "$ITEMS" >> "$VULN_OUT" 2>>"$WORK/$VHOST-php.err" || VULN_STATE[$VHOST]="error"

    # --- Modified files (checksums) ---
    MAL_OUT="$WORK/$VHOST-malware.csv"; echo "$MAL_HEADER" > "$MAL_OUT"
    MAL_STATE[$VHOST]="ok"; MAL_ERR[$VHOST]=""
    wp core verify-checksums 2>&1 >/dev/null | sed -n 's/^Warning: \(File .*\): \(.*\)$/\1\t\2/p' |
        while IFS=$'\t' read -r MSG FILE; do
            printf 'checksum,%s,%s\n' "$(csv_field "$FILE")" "$(csv_field "Core: $MSG")" >> "$MAL_OUT"
        done
    wp plugin verify-checksums --all --format=json 2>/dev/null |
        jq -r '.[]? | [.plugin_name, .file, .message] | @tsv' 2>/dev/null |
        while IFS=$'\t' read -r PL FILE MSG; do
            printf 'checksum,%s,%s\n' "$(csv_field "wp-content/plugins/$PL/$FILE")" "$(csv_field "Plugin $PL: $MSG")" >> "$MAL_OUT"
        done

    # Targets for the shared malware scan
    if [[ $MALWARE -eq 1 ]]; then
        malware_targets "$WEB_ROOT" >> "$WORK/clam-targets"
    fi
done

if [[ ${#SITES[@]} -eq 0 ]]; then log "No WordPress sites found."; exit 0; fi

# ---------------------------------------------------------------------------
# Phase 2: one ClamAV scan over all sites (loading signatures once is much faster)
# ---------------------------------------------------------------------------
CLAM_STATE="skipped" CLAM_SECS=0
if [[ $MALWARE -eq 1 && -s "$WORK/clam-targets" ]]; then
    DB_ARGS=()
    [[ -d "$CLAM_DB_DIR" ]] && DB_ARGS+=(--database="$CLAM_DB_DIR")
    for sig in "$MALDET_SIGS_DIR"/rfxn.{ndb,hdb,yara} "$MALDET_SIGS_DIR"/custom.{ndb,hdb,yara}; do
        [[ -s "$sig" ]] && DB_ARGS+=(--database="$sig")
    done
    [[ -d "$MALDET_SIGS_DIR" ]] || warn "maldet signatures not found in $MALDET_SIGS_DIR - ClamAV's own signatures catch far fewer PHP web shells."
    tr '\0' '\n' < "$WORK/clam-targets" > "$WORK/clam-list"
    log "Malware scan: $(wc -l < "$WORK/clam-list") paths across ${#SITES[@]} site(s)"
    START=$(date +%s)
    timeout "$CLAM_TIMEOUT" "$CLAMSCAN" "${CLAM_OPTS[@]}" "${DB_ARGS[@]}" --file-list="$WORK/clam-list" \
        > "$WORK/clam.out" 2> "$WORK/clam.err"
    CODE=$?
    CLAM_SECS=$(( $(date +%s) - START ))
    case "$CODE" in
        0|1) CLAM_STATE="ok" ;;          # 0 = clean, 1 = found something
        124) CLAM_STATE="timeout" ;;
        *)   CLAM_STATE="error" ;;
    esac
    log "Malware scan finished in ${CLAM_SECS}s ($CLAM_STATE)"
    [[ "$CLAM_STATE" != "ok" ]] && warn "clamscan: $(tail -c 400 "$WORK/clam.err")"

    # "path: Signature FOUND" -> per-site rows
    sed -n 's/^\(.*\): \(.*\) FOUND$/\1\t\2/p' "$WORK/clam.out" | while IFS=$'\t' read -r PATH_HIT SIG; do
        for VHOST in "${SITES[@]}"; do
            ROOT="/home/$VHOST/public_html/"
            if [[ "$PATH_HIT" == "$ROOT"* ]]; then
                printf 'malware,%s,%s\n' "$(csv_field "${PATH_HIT#"$ROOT"}")" "$(csv_field "$SIG")" >> "$WORK/$VHOST-malware.csv"
                break
            fi
        done
    done
fi

# ---------------------------------------------------------------------------
# Phase 3: publish reports, status and alerts
# ---------------------------------------------------------------------------
TODAY=$(date +%F)
n_malware=0 n_modified=0 n_vuln=0 n_errors=0
SUMMARY_LINES=()

for VHOST in "${SITES[@]}"; do
    MAL_OUT="$WORK/$VHOST-malware.csv"
    VULN_OUT="$WORK/$VHOST-vuln.csv"
    if [[ $MALWARE -eq 1 && "$CLAM_STATE" != "ok" ]]; then
        MAL_STATE[$VHOST]="$CLAM_STATE"; MAL_ERR[$VHOST]="ClamAV: $(tail -c 300 "$WORK/clam.err" 2>/dev/null)"
    fi

    MALWARE_HITS=$(grep -c '^malware,' "$MAL_OUT")
    MODIFIED=$(grep -c '^checksum,' "$MAL_OUT")
    VULNS=$(count_rows "$VULN_OUT")

    MAL_CHANGED=0 VULN_CHANGED=0
    [[ "$(fingerprint "$MAL_OUT")" != "$(fingerprint "$MALWARE_REPORT_DIR/$VHOST.csv")" ]] && MAL_CHANGED=1
    [[ "$(fingerprint "$VULN_OUT")" != "$(fingerprint "$VULN_REPORT_DIR/$VHOST.csv")" ]] && VULN_CHANGED=1

    # A failed check keeps the previous report rather than showing "clean"
    [[ "${MAL_STATE[$VHOST]}" == "ok" ]] && publish "$MAL_OUT" "$MALWARE_REPORT_DIR/$VHOST.csv"
    [[ "${VULN_STATE[$VHOST]}" != "error" ]] && publish "$VULN_OUT" "$VULN_REPORT_DIR/$VHOST.csv"

    install -d -m 0750 "$HISTORY_DIR/$VHOST"
    cp "$MAL_OUT" "$HISTORY_DIR/$VHOST/$TODAY-malware.csv"
    cp "$VULN_OUT" "$HISTORY_DIR/$VHOST/$TODAY-vuln.csv"
    if [[ "$KEEP_LOCAL_COPY" == "1" ]]; then
        cp "$MAL_OUT" "/home/$VHOST/malware-scan.csv"
        cp "$VULN_OUT" "/home/$VHOST/vuln-scan.csv"
    fi

    jq -n --arg site "$VHOST" --arg at "$(date --iso-8601=seconds)" --arg v "$SCRIPT_VERSION" \
        --arg ms "${MAL_STATE[$VHOST]}" --arg me "${MAL_ERR[$VHOST]}" --argjson mh "$MALWARE_HITS" --argjson mm "$MODIFIED" \
        --arg clam "$CLAM_STATE" --argjson csecs "$CLAM_SECS" --arg up "$UPLOADS_MODE" \
        --arg vs "${VULN_STATE[$VHOST]}" --arg ve "${VULN_ERR[$VHOST]}" --argjson vc "$VULNS" \
        '{site: $site, scanned_at: $at, scanner: "security-scan", script_version: $v,
          malware: {state: (if $ms == "ok" then "ok" else $ms end), findings: ($mh + $mm), malware: $mh, modified_files: $mm,
                    clamav: $clam, clamav_seconds: $csecs, uploads_mode: $up, log: (if $me == "" then null else $me end)},
          vuln: {state: (if $vs == "partial" then "ok" else $vs end), findings: $vc, partial: ($vs == "partial"),
                 log: (if $ve == "" then null else $ve end)}}' > "$WORK/status.json" \
        && publish "$WORK/status.json" "$STATUS_DIR/$VHOST.json"

    log "$VHOST: $MALWARE_HITS malware, $MODIFIED modified file(s), $VULNS vulnerabilit$([[ $VULNS -eq 1 ]] && echo y || echo ies)"
    [[ -n "${VULN_ERR[$VHOST]}" ]] && log "    vulnerabilities: ${VULN_ERR[$VHOST]}"
    [[ -n "${MAL_ERR[$VHOST]}" ]] && log "    malware: ${MAL_ERR[$VHOST]}"

    [[ $MALWARE_HITS -gt 0 ]] && n_malware=$((n_malware + 1))
    [[ $MODIFIED -gt 0 ]] && n_modified=$((n_modified + 1))
    [[ $VULNS -gt 0 ]] && n_vuln=$((n_vuln + 1))
    if [[ "${MAL_STATE[$VHOST]}" != "ok" || "${VULN_STATE[$VHOST]}" == "error" ]]; then
        n_errors=$((n_errors + 1))
        SUMMARY_LINES+=("• $VHOST: check failed - ${VULN_ERR[$VHOST]}${MAL_ERR[$VHOST]:+ ${MAL_ERR[$VHOST]}}")
    fi
    if [[ $((MALWARE_HITS + MODIFIED + VULNS)) -gt 0 ]]; then
        SUMMARY_LINES+=("• $VHOST: $MALWARE_HITS malware, $MODIFIED modified file(s), $VULNS vulnerabilit$([[ $VULNS -eq 1 ]] && echo y || echo ies)")
    fi

    PARTS=() ATTACH=()
    if [[ $((MALWARE_HITS + MODIFIED)) -gt 0 && ( $MAL_CHANGED -eq 1 || $NOTIFY_ALL -eq 1 ) ]]; then
        [[ $MALWARE_HITS -gt 0 ]] && PARTS+=(":rotating_light: *$MALWARE_HITS malware detection(s)*")
        [[ $MODIFIED -gt 0 ]] && PARTS+=(":mag: *$MODIFIED file(s) differ from the official WordPress/plugin versions*")
        cp "$MAL_OUT" "$WORK/$VHOST-malware-scan.csv"; ATTACH+=("$WORK/$VHOST-malware-scan.csv")
    fi
    if [[ $VULNS -gt 0 && ( $VULN_CHANGED -eq 1 || $NOTIFY_ALL -eq 1 ) ]]; then
        PARTS+=(":warning: *$VULNS known vulnerabilit$([[ $VULNS -eq 1 ]] && echo y || echo ies)* in installed core/plugins/themes, update needed")
        cp "$VULN_OUT" "$WORK/$VHOST-vuln-scan.csv"; ATTACH+=("$WORK/$VHOST-vuln-scan.csv")
    fi
    if [[ ${#PARTS[@]} -gt 0 ]]; then
        TEXT="*$VHOST*"; for p in "${PARTS[@]}"; do TEXT+=$'\n'"$p"; done
        slack_files "$TEXT" "${ATTACH[@]}"
    fi
done

find "$HISTORY_DIR" -type f -name '*.csv' -mtime +"$HISTORY_DAYS" -delete 2>/dev/null

SUMMARY="Security scan finished: ${#SITES[@]} site(s), $n_malware with malware, $n_modified with modified files, $n_vuln with vulnerabilities, $n_errors with errors$([[ $MALWARE -eq 0 ]] && echo ' (malware scan skipped)')."
log "$SUMMARY"
[[ ${#SUMMARY_LINES[@]} -gt 0 ]] && slack_message "$SUMMARY"$'\n'"$(printf '%s\n' "${SUMMARY_LINES[@]}")"

[[ $n_errors -gt 0 ]] && exit 2
exit 0
