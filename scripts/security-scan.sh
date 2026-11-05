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
#   Database         posts/options: obfuscated scripts, hidden iframes, hidden links (embeds and code samples ignored)
#   Suspicious code  PHP using obfuscation/backdoor patterns (eval of decoded data, request-driven calls, ...)
#   Audit            new admins, open registration, site address changes, PHP in uploads, world-writable
#                    files, exposed backups/logs, wp-config.php/.htaccess changes
#   Recent changes   PHP files changed in the last few days (information only)
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

SCRIPT_VERSION="1.2.0"

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
CLAM_OPTS=(--recursive --infected --no-summary --scan-archive=no --max-filesize=10M --max-scansize=20M)
# Only scan file types that malware lives in (regex on the file name). Empty = scan every file (much slower).
# The second part also catches double extensions used to hide PHP, e.g. shell.php.jpg
CLAM_INCLUDE='(\.(php[0-9]?|phtml|pht|phar|inc|js|html?|htaccess|user\.ini|svg|ico|sh|pl|py|cgi)$|\.(php[0-9]?|phtml|phar)\.[^/]*$)'
# Folders skipped by ClamAV and the code checks: caches and backup plugins' archives (huge, not executable)
SKIP_DIR_NAMES=(cache updraft ai1wm-backups wpvividbackups backup backups backup-db 'backwpup-*' node_modules .git)

# What the malware scan does with wp-content/uploads
#   php-only  skip media, but scan PHP/script files hidden in uploads (default)
#   skip      don't scan uploads at all
#   full      scan everything
UPLOADS_MODE="php-only"

WP_TIMEOUT=300

# Extra checks
STATE_DIR="/nas/metrics/public_html/security-scans"   # baselines: admin accounts, key file hashes (root-only)
ADMIN_NEW_DAYS=30                       # flag administrator accounts this new
KEYFILE_CHANGE_DAYS=7                   # flag wp-config.php/.htaccess changes for this many days
RECENT_DAYS=3                           # list PHP files changed in the last N days (information only)
LIST_LIMIT=50                           # max rows per check per site
# Never report these, in any check. Globs relative to the site's public_html (e.g. 'wp-content/cache/*').
IGNORE_FILES=(
    'wp-admin/cookie.txt'
)
IGNORE_SILENCE_IS_GOLDEN=1              # skip index.php files with no code (empty, or only <?php + comments like "Silence is golden")
PATTERN_TIMEOUT=900                     # seconds for the suspicious-code search per site
# Options skipped by the database check (regex on option_name): caches that legitimately hold JS
DB_IGNORE_OPTIONS='^(_site)?_transient_|^rocket_|^wpseo|^elementor_|_cache$'
# Post types skipped by the database check (WordPress's own embed cache, revisions, Customizer drafts...)
DB_SKIP_POST_TYPES="'revision','nav_menu_item','oembed_cache','customize_changeset','user_request','wp_global_styles'"
# Suspicious PHP patterns: "label::PCRE"
SUSPICIOUS_PATTERNS=(
    'eval of decoded data::eval\s*\(\s*(base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|strrev|rawurldecode|hex2bin)\s*\('
    'nested decoding::(base64_decode|gzinflate|gzuncompress|str_rot13)\s*\(\s*(base64_decode|gzinflate|gzuncompress|str_rot13|strrev)\s*\('
    'code run from request data::\b(eval|assert|system|exec|shell_exec|passthru|popen|proc_open)\s*\(\s*(stripslashes\s*\(\s*)?\$_(POST|GET|REQUEST|COOKIE|SERVER)'
    'function name taken from request::\$_(POST|GET|REQUEST|COOKIE)\s*\[[^\]]{1,40}\]\s*\('
    'include of a non-PHP file::\b(include|require)(_once)?\s*\(?\s*['"'"'"][^'"'"'"]+\.(ico|png|jpe?g|gif|txt|css|svg)['"'"'"]'
    'long hex-escaped string::(\\x[0-9a-fA-F]{2}){40,}'
)

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
# Baselines hold admin logins/emails: keep them root-only (the folder is inside a web root)
install -d -m 0700 "$STATE_DIR"; chmod 0700 "$STATE_DIR"

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
# (grep -c prints "0" AND exits 1 when nothing matches, so never chain it with "|| echo 0")
count_rows() { [[ -s "$1" ]] || { echo 0; return 0; }; tail -n +2 "$1" | grep -c '[^[:space:]]'; return 0; }
# Findings of one type in a report, not counting "(more)" notes
count_src() { grep "^$1," "$2" | grep -vc "^$1,\"(more)\""; return 0; }
# "recent" rows are information only, so they don't count as a change worth alerting on
fingerprint() { [[ -s "$1" ]] || { echo "empty"; return 0; }; tail -n +2 "$1" | { grep -v '^recent,' || true; } | sort | md5sum | cut -d' ' -f1; }

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

# PHP evaluated in each site (plugins/themes not loaded): database injection search + admin/settings audit.
read -r -d '' AUDIT_PHP <<'PHP'
global $wpdb;
$limit = 5000;

// Iframes from these hosts (and WordPress's own oEmbed iframes) are normal embeds, not injections
$trusted = '~^(?:[a-z0-9-]+\.)*(youtube\.com|youtube-nocookie\.com|youtu\.be|vimeo\.com|google\.com|maps\.google\.com|spotify\.com|soundcloud\.com|twitter\.com|x\.com|instagram\.com|facebook\.com|tiktok\.com|dailymotion\.com|reddit\.com|pinterest\.com|giphy\.com|imgur\.com|wordpress\.com|wp\.com)$~i';
$obf = '~eval\s*\(|atob\s*\(|String\.fromCharCode|unescape\s*\(|new\s+Function\s*\(|(?:\\\\x[0-9a-f]{2}){12,}~i';

// Returns [label, matched text] for the first real injection sign, or null
$inspect = function ($html) use ($trusted, $obf) {
    // Code samples and comments are not executed
    $h = preg_replace('~<(pre|code)\b[^>]*>.*?</\1>~is', ' ', $html);
    $h = preg_replace('~<!--.*?-->~s', ' ', $h);
    // Drop WordPress oEmbed iframes and iframes from trusted hosts
    $h = preg_replace_callback('~<iframe\b[^>]*>~i', function ($m) use ($trusted) {
        if (preg_match('~class\s*=\s*["\'][^"\']*wp-embedded-content~i', $m[0])) return ' ';
        if (preg_match('~src\s*=\s*["\']?(?:https?:)?//([^/"\'\s>]+)~i', $m[0], $u) && preg_match($trusted, $u[1])) return ' ';
        return $m[0];
    }, $h);
    // 1. Obfuscated JavaScript inside <script> blocks
    if (preg_match_all('~<script\b[^>]*>(.*?)</script>~is', $h, $scripts)) {
        foreach ($scripts[1] as $js) {
            if (preg_match($obf, $js, $m)) return ['Obfuscated script', $m[0]];
            if (preg_match('~document\.write\s*\(\s*unescape|window\.location(?:\.href)?\s*=\s*atob~i', $js, $m)) return ['Obfuscated script', $m[0]];
        }
    }
    // 2. Obfuscated code in event handlers or javascript: links
    if (preg_match('~\son[a-z]+\s*=\s*["\'][^"\']*(?:eval\s*\(|atob\s*\(|fromCharCode|unescape\s*\()~i', $h, $m)) return ['Script in event handler', $m[0]];
    if (preg_match('~href\s*=\s*["\']\s*javascript:[^"\']*(?:eval|atob|fromCharCode|unescape)~i', $h, $m)) return ['javascript: link', $m[0]];
    // 3. Hidden or 0/1-pixel iframes (trusted embeds already removed)
    if (preg_match('~<iframe\b[^>]*(?:display\s*:\s*none|visibility\s*:\s*hidden|\bwidth\s*=\s*["\']?[01]["\'\s>]|\bheight\s*=\s*["\']?[01]["\'\s>])[^>]*>~i', $h, $m)) return ['Hidden iframe', $m[0]];
    // 4. Hidden links (classic SEO spam): link inside an invisible or off-screen element
    if (preg_match('~<(div|span|p)\b[^>]*style\s*=\s*["\'][^"\']*(?:display\s*:\s*none|visibility\s*:\s*hidden|(?:left|top|text-indent)\s*:\s*-\d{3,}px|font-size\s*:\s*0(?:px)?\s*[;"\'])[^"\']*["\'][^>]*>(?:(?!</\1>).){0,2000}?<a\s[^>]*href\s*=\s*["\']https?://~is', $h, $m)) return ['Hidden link', $m[0]];
    return null;
};
$snip = function ($text, $m) {
    $pos = stripos($text, $m);
    $s = substr($text, max(0, (int) $pos - 30), 160);
    return trim(preg_replace('/\s+/', ' ', $s));
};
// Cheap SQL pre-filter; the exact checks run in PHP above
$likes = ['<script', '<iframe', 'javascript:', 'onload=', 'onerror=', 'onmouseover=', 'display:none', 'display: none', 'visibility:hidden', 'visibility: hidden', '-9999px', 'font-size:0', 'font-size: 0'];
$where = function ($col) use ($wpdb, $likes) {
    return '(' . implode(' OR ', array_map(fn($l) => "$col LIKE '%" . esc_sql($wpdb->esc_like($l)) . "%'", $likes)) . ')';
};
$out = ['db' => [], 'admins' => [],
        'siteurl' => get_option('siteurl'), 'home' => get_option('home'),
        'users_can_register' => (int) get_option('users_can_register'), 'default_role' => (string) get_option('default_role')];

$rows = $wpdb->get_results("SELECT ID, post_type, post_status, post_title, post_content FROM {$wpdb->posts}
    WHERE post_type NOT IN (__SKIPTYPES__) AND " . $where('post_content') . " LIMIT $limit");
foreach ((array) $rows as $r) {
    if ($hit = $inspect($r->post_content)) {
        $out['db'][] = ['where' => "post #{$r->ID} ({$r->post_type}, {$r->post_status}): " . mb_substr($r->post_title, 0, 60),
                        'detail' => $hit[0] . ': ' . $snip($r->post_content, $hit[1])];
    }
}
$rows = $wpdb->get_results("SELECT option_name, option_value FROM {$wpdb->options} WHERE " . $where('option_value') . " LIMIT $limit");
foreach ((array) $rows as $r) {
    if (preg_match('~__IGNORE__~', $r->option_name)) continue;
    if ($hit = $inspect($r->option_value)) {
        $out['db'][] = ['where' => "option {$r->option_name}", 'detail' => $hit[0] . ': ' . $snip($r->option_value, $hit[1])];
    }
}
foreach (get_users(['role' => 'administrator', 'fields' => ['user_login', 'user_email', 'user_registered']]) as $u) {
    $out['admins'][] = ['login' => $u->user_login, 'email' => $u->user_email, 'registered' => $u->user_registered];
}
echo "\n__SEC__" . wp_json_encode($out);
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

# is_ignored ROOT LOCATION -> 0 if a finding at this location should not be reported
is_ignored() {
    local root="${1%/}" loc="$2" g f
    loc="${loc%%:[0-9]*}"                       # "file.php:12" -> "file.php"
    loc="${loc%/}"
    for g in "${IGNORE_FILES[@]}"; do
        # shellcheck disable=SC2053
        [[ "$loc" == $g ]] && return 0
    done
    if [[ "$IGNORE_SILENCE_IS_GOLDEN" == "1" && "${loc##*/}" == "index.php" ]]; then
        f="$root/$loc"
        # Ignore index.php files with no code: empty, whitespace only, or <?php followed only by comments
        # (e.g. "Silence is golden") and an optional ?>. Anything with code is still reported, since
        # attackers often append backdoors to these placeholders. A "?>" inside a // comment ends PHP
        # mode, so it is not allowed there.
        if [[ -f "$f" && $(stat -c %s "$f" 2>/dev/null || echo 9999) -le 1024 ]]; then
            if ! grep -q '[^[:space:]]' "$f" 2>/dev/null \
                || grep -Pzq '\A(?:\xEF\xBB\xBF)?\s*<\?php(?:\s|//(?:(?!\?>)[^\n])*|#(?:(?!\?>)[^\n])*|/\*(?:(?!\*/)[\s\S])*\*/)*(?:\?>\s*)?\z' "$f" 2>/dev/null; then
                return 0
            fi
        fi
    fi
    return 1
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
declare -A VULN_STATE VULN_ERR MAL_STATE MAL_ERR EXTRA_ERR DOMAIN_FOR_SITE
MAL_HEADER="source,file,detection"
VULN_HEADER="type,slug,installed_version,vulnerability,severity,fixed_in,link"

for VHOST_DIR in "${DIRS[@]}"; do
    [[ -d "$VHOST_DIR" && -f "$VHOST_DIR/vhconf.conf" ]] || continue
    VHOST="${VHOST_DIR##*/}"
    WEB_ROOT="/home/$VHOST/public_html"
    [[ -f "$WEB_ROOT/wp-config.php" ]] || { log "Skipping non-WordPress vhost: $VHOST"; continue; }
    SITES+=("$VHOST")
    log "Checking $VHOST"
    EXTRA_ERR[$VHOST]=""
    D=$(grep -E '^\s*vhAliases\s+' "$VHOST_DIR/vhconf.conf" | head -n 1 | sed -E 's/^[[:space:]]*vhAliases[[:space:]]+//' \
        | tr ',' '\n' | tr -d ' \t"\r' | grep -v -e '^$' -e '^\*$' -e '\$' | head -n 1)
    D="${D#www.}"; DOMAIN_FOR_SITE[$VHOST]="$D"

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
            is_ignored "$WEB_ROOT" "$FILE" && continue
            printf 'checksum,%s,%s\n' "$(csv_field "$FILE")" "$(csv_field "Core: $MSG")" >> "$MAL_OUT"
        done
    wp plugin verify-checksums --all --format=json 2>/dev/null |
        jq -r '.[]? | [.plugin_name, .file, .message] | @tsv' 2>/dev/null |
        while IFS=$'\t' read -r PL FILE MSG; do
            is_ignored "$WEB_ROOT" "wp-content/plugins/$PL/$FILE" && continue
            printf 'checksum,%s,%s\n' "$(csv_field "wp-content/plugins/$PL/$FILE")" "$(csv_field "Plugin $PL: $MSG")" >> "$MAL_OUT"
        done

    # Paths to inspect (same rules as the malware scan for uploads)
    mapfile -d '' SCAN_PATHS < <(malware_targets "$WEB_ROOT")
    SCAN_DIRS=() SCAN_FILES=()
    for P in "${SCAN_PATHS[@]}"; do [[ -d "$P" ]] && SCAN_DIRS+=("$P") || SCAN_FILES+=("$P"); done
    if [[ $MALWARE -eq 1 ]]; then
        printf '%s\0' "${SCAN_PATHS[@]}" >> "$WORK/clam-targets"
    fi
    STATE="$STATE_DIR/$VHOST"; install -d -m 0700 "$STATE"
    NOW=$(date +%s)
    add_row() { is_ignored "$WEB_ROOT" "$2" && return 0; printf '%s,%s,%s\n' "$1" "$(csv_field "$2")" "$(csv_field "$3")" >> "$MAL_OUT"; }
    rel() { printf '%s' "${1#"$WEB_ROOT/"}"; }

    GREP_SKIP=(); FIND_SKIP=()
    for N in "${SKIP_DIR_NAMES[@]}"; do GREP_SKIP+=(--exclude-dir="$N"); FIND_SKIP+=(-name "$N" -o); done
    unset 'FIND_SKIP[${#FIND_SKIP[@]}-1]'

    # --- Suspicious code patterns ---
    : > "$WORK/pat"
    for ENTRY in "${SUSPICIOUS_PATTERNS[@]}"; do
        LABEL="${ENTRY%%::*}" RE="${ENTRY#*::}"
        {
            [[ ${#SCAN_DIRS[@]} -gt 0 ]] && timeout "$PATTERN_TIMEOUT" grep -rnoIP -m 3 \
                --include='*.php' --include='*.php[0-9]' --include='*.phtml' --include='*.inc' \
                "${GREP_SKIP[@]}" -e "$RE" -- "${SCAN_DIRS[@]}" 2>/dev/null
            [[ ${#SCAN_FILES[@]} -gt 0 ]] && timeout "$PATTERN_TIMEOUT" grep -noIP -m 3 -H -e "$RE" -- "${SCAN_FILES[@]}" 2>/dev/null
        } | while IFS= read -r LINE; do
            [[ "$LINE" =~ ^([^:]+):([0-9]+):(.*)$ ]] || continue
            printf '%s\t%s\n' "$(rel "${BASH_REMATCH[1]}"):${BASH_REMATCH[2]}" "$LABEL: ${BASH_REMATCH[3]:0:100}"
        done >> "$WORK/pat"
    done
    sort -u "$WORK/pat" | head -n "$LIST_LIMIT" | while IFS=$'\t' read -r F D; do add_row pattern "$F" "$D"; done
    N=$(sort -u "$WORK/pat" | wc -l); [[ $N -gt $LIST_LIMIT ]] && add_row pattern "(more)" "$((N - LIST_LIMIT)) more matches not listed"

    # --- Recently changed PHP files (information only, never alerts) ---
    find "${SCAN_PATHS[@]}" -type d \( "${FIND_SKIP[@]}" \) -prune -o -type f \( -name '*.php' -o -name '*.php[0-9]' -o -name '*.phtml' \) \
        -mtime -"$RECENT_DAYS" -printf '%T@\t%p\n' 2>/dev/null | sort -rn > "$WORK/recent"
    head -n "$LIST_LIMIT" "$WORK/recent" | while IFS=$'\t' read -r T F; do
        add_row recent "$(rel "$F")" "Changed $(date -d "@${T%.*}" '+%Y-%m-%d %H:%M')"
    done
    N=$(wc -l < "$WORK/recent"); [[ $N -gt $LIST_LIMIT ]] && add_row recent "(more)" "$((N - LIST_LIMIT)) more files changed"

    # --- Database + admin/settings audit (one WP-CLI call) ---
    AUDIT_CODE="${AUDIT_PHP//__IGNORE__/$DB_IGNORE_OPTIONS}"
    AUDIT_OUT=$(wp eval "${AUDIT_CODE//__SKIPTYPES__/$DB_SKIP_POST_TYPES}" 2>"$WORK/err")
    AUDIT=$(grep -o '__SEC__.*' <<< "$AUDIT_OUT" | tail -n 1 | sed 's/^__SEC__//')
    if jq -e 'type == "object"' <<< "$AUDIT" >/dev/null 2>&1; then
        jq -r --argjson n "$LIST_LIMIT" '.db[:$n][] | [.where, .detail] | @tsv' <<< "$AUDIT" |
            while IFS=$'\t' read -r W D; do add_row database "$W" "$D"; done
        N=$(jq '.db | length' <<< "$AUDIT"); [[ $N -gt $LIST_LIMIT ]] && add_row database "(more)" "$((N - LIST_LIMIT)) more not listed"

        # Administrators: flagged when added after the first scan (first_seen > 0) or registered recently.
        # Accounts present on the first scan form the baseline (first_seen = 0). Wording stays the same
        # between runs so an unchanged situation doesn't re-alert.
        BASE="$STATE/admins.tsv"; NEWBASE="$WORK/admins.tsv"; : > "$NEWBASE"
        while IFS=$'\t' read -r LOGIN EMAIL REG; do
            FIRST=$(awk -F'\t' -v l="$LOGIN" '$1 == l {print $3}' "$BASE" 2>/dev/null)
            if [[ -z "$FIRST" ]]; then
                [[ -f "$BASE" ]] && FIRST=$NOW || FIRST=0
            fi
            REG_TS=$(date -d "$REG" +%s 2>/dev/null || echo 0)
            if [[ "$FIRST" != "0" && $((NOW - FIRST)) -lt $((ADMIN_NEW_DAYS * 86400)) ]]; then
                add_row audit "user $LOGIN" "Administrator added $(date -d "@$FIRST" +%F) ($EMAIL)"
            elif [[ $((NOW - REG_TS)) -lt $((ADMIN_NEW_DAYS * 86400)) ]]; then
                add_row audit "user $LOGIN" "Administrator registered recently: ${REG%% *} ($EMAIL)"
            fi
            printf '%s\t%s\t%s\n' "$LOGIN" "$EMAIL" "$FIRST" >> "$NEWBASE"
        done < <(jq -r '.admins[] | [.login, .email, .registered] | @tsv' <<< "$AUDIT")
        cp "$NEWBASE" "$BASE"

        # Site address hijack and open registration as admin/editor
        DOM_RE="^https?://(www\.)?${DOMAIN_FOR_SITE[$VHOST]//./\\.}(/|$)"
        for KEY in siteurl home; do
            URL=$(jq -r ".$KEY // \"\"" <<< "$AUDIT")
            [[ -n "${DOMAIN_FOR_SITE[$VHOST]}" && -n "$URL" && ! "$URL" =~ $DOM_RE ]] && add_row audit "option $KEY" "Site address is $URL (expected ${DOMAIN_FOR_SITE[$VHOST]})"
        done
        if [[ $(jq -r '.users_can_register' <<< "$AUDIT") == "1" ]]; then
            ROLE=$(jq -r '.default_role' <<< "$AUDIT")
            case "$ROLE" in
                administrator|editor|shop_manager) add_row audit "option default_role" "Anyone can register and becomes '$ROLE'" ;;
                *) add_row audit "option users_can_register" "Open registration is on (new users get '$ROLE')" ;;
            esac
        fi
    else
        EXTRA_ERR[$VHOST]="database/admin check failed: $(head -c 200 "$WORK/err" | tr '\n' ' ')"
    fi

    # --- Files: PHP in uploads, world-writable, exposed backups/logs, key file changes ---
    UP="$WEB_ROOT/wp-content/uploads"
    if [[ -d "$UP" ]]; then
        find -H "$UP" -type f \( -iname '*.php*' -o -iname '*.phtml' -o -iname '*.phar' \) 2>/dev/null |
            while IFS= read -r F; do
                is_ignored "$WEB_ROOT" "$(rel "$F")" && continue
                echo "$F"
            done | head -n "$LIST_LIMIT" | while IFS= read -r F; do add_row audit "$(rel "$F")" "PHP file in uploads"; done
    fi
    find "$WEB_ROOT" -xdev ! -type l -perm -0002 2>/dev/null | head -n "$LIST_LIMIT" |
        while IFS= read -r F; do add_row audit "$(rel "$F")" "World-writable ($(stat -c '%a' "$F"))"; done
    find "$WEB_ROOT" -maxdepth 3 \( -path "$UP" -prune \) -o \( -type f \( -iname '*.sql' -o -iname '*.sql.gz' -o -iname '*.sql.zip' \
        -o -iname '*.tar' -o -iname '*.tar.gz' -o -iname '*.tgz' -o -iname '*.bak' -o -iname '*.old' -o -iname '*.save' -o -name '*~' \
        -o -name '.env' -o -iname 'phpinfo.php' -o -iname 'info.php' -o -iname 'adminer*.php' -o -name 'debug.log' -o -name 'error_log' \
        -o -iname 'wp-config.php.*' \) -print \) -o \( -type d -name '.git' -print -prune \) 2>/dev/null | head -n "$LIST_LIMIT" |
        while IFS= read -r F; do
            if [[ -d "$F" ]]; then add_row audit "$(rel "$F")/" "Folder that should not be in the web root (e.g. exposes source history)"
            else add_row audit "$(rel "$F")" "Sensitive file in the web root ($(du -h "$F" 2>/dev/null | cut -f1))"; fi
        done

    HASHES="$STATE/keyfiles.tsv"; NEWH="$WORK/keyfiles.tsv"; : > "$NEWH"
    for KF in wp-config.php .htaccess .user.ini index.php wp-content/.htaccess wp-content/uploads/.htaccess; do
        [[ -f "$WEB_ROOT/$KF" ]] || continue
        SUM=$(sha256sum "$WEB_ROOT/$KF" | cut -d' ' -f1)
        read -r OLDSUM CHANGED < <(awk -F'\t' -v f="$KF" '$1 == f {print $2, $3}' "$HASHES" 2>/dev/null)
        if [[ -n "${OLDSUM:-}" && "$OLDSUM" != "$SUM" ]]; then CHANGED=$NOW; fi
        [[ -z "${CHANGED:-}" ]] && CHANGED=0
        if [[ "$CHANGED" != "0" && $((NOW - CHANGED)) -lt $((KEYFILE_CHANGE_DAYS * 86400)) ]]; then
            add_row audit "$KF" "Changed since the previous scan (detected $(date -d "@$CHANGED" '+%Y-%m-%d %H:%M'))"
        fi
        printf '%s\t%s\t%s\n' "$KF" "$SUM" "$CHANGED" >> "$NEWH"
        OLDSUM="" CHANGED=""
    done
    cp "$NEWH" "$HASHES"
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
    FILTER_ARGS=()
    [[ -n "$CLAM_INCLUDE" ]] && FILTER_ARGS+=(--include="$CLAM_INCLUDE")
    SKIP_RE=$(printf '%s|' "${SKIP_DIR_NAMES[@]}" | sed -e 's/|$//' -e 's/\./\\./g' -e 's/\*/[^\/]*/g')
    FILTER_ARGS+=(--exclude-dir="/(${SKIP_RE})(/|$)")
    timeout "$CLAM_TIMEOUT" "$CLAMSCAN" "${CLAM_OPTS[@]}" "${FILTER_ARGS[@]}" "${DB_ARGS[@]}" --file-list="$WORK/clam-list" \
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
                is_ignored "$ROOT" "${PATH_HIT#"$ROOT"}" || \
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
n_malware=0 n_modified=0 n_vuln=0 n_errors=0 n_suspicious=0 n_audit=0
SUMMARY_LINES=()

for VHOST in "${SITES[@]}"; do
    MAL_OUT="$WORK/$VHOST-malware.csv"
    VULN_OUT="$WORK/$VHOST-vuln.csv"
    if [[ $MALWARE -eq 1 && "$CLAM_STATE" != "ok" ]]; then
        MAL_STATE[$VHOST]="$CLAM_STATE"
        MAL_ERR[$VHOST]="ClamAV $([[ $CLAM_STATE == timeout ]] && echo "stopped after ${CLAM_TIMEOUT}s" || echo failed): $(tail -c 250 "$WORK/clam.err" 2>/dev/null)"
        # ClamAV didn't finish: keep the previous run's malware detections alongside anything found this time
        if [[ -f "$MALWARE_REPORT_DIR/$VHOST.csv" ]]; then
            { grep '^malware,' "$MALWARE_REPORT_DIR/$VHOST.csv"; grep '^malware,' "$MAL_OUT"; } | sort -u > "$WORK/mal-merge"
            grep -v '^malware,' "$MAL_OUT" > "$WORK/mal-rest"; cat "$WORK/mal-rest" "$WORK/mal-merge" > "$MAL_OUT"
        fi
    fi

    MALWARE_HITS=$(count_src malware "$MAL_OUT")
    MODIFIED=$(count_src checksum "$MAL_OUT")
    DBHITS=$(count_src database "$MAL_OUT")
    PATTERNS=$(count_src pattern "$MAL_OUT")
    AUDITS=$(count_src audit "$MAL_OUT")
    RECENT=$(count_src recent "$MAL_OUT")
    VULNS=$(count_rows "$VULN_OUT")

    MAL_CHANGED=0 VULN_CHANGED=0
    [[ "$(fingerprint "$MAL_OUT")" != "$(fingerprint "$MALWARE_REPORT_DIR/$VHOST.csv")" ]] && MAL_CHANGED=1
    [[ "$(fingerprint "$VULN_OUT")" != "$(fingerprint "$VULN_REPORT_DIR/$VHOST.csv")" ]] && VULN_CHANGED=1

    # Always publish: the other checks are current. If ClamAV failed, its rows were carried over above.
    publish "$MAL_OUT" "$MALWARE_REPORT_DIR/$VHOST.csv"
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
        --argjson db "$DBHITS" --argjson pat "$PATTERNS" --argjson aud "$AUDITS" --argjson rec "$RECENT" --arg xe "${EXTRA_ERR[$VHOST]}" \
        --arg vs "${VULN_STATE[$VHOST]}" --arg ve "${VULN_ERR[$VHOST]}" --argjson vc "$VULNS" \
        '{site: $site, scanned_at: $at, scanner: "security-scan", script_version: $v,
          malware: {state: (if $ms == "ok" then "ok" else $ms end), findings: ($mh + $mm + $db + $pat + $aud), malware: $mh, modified_files: $mm,
                    database: $db, suspicious_code: $pat, audit: $aud, recently_changed: $rec, checks_log: (if $xe == "" then null else $xe end),
                    clamav: $clam, clamav_seconds: $csecs, uploads_mode: $up, log: (if $me == "" then null else $me end)},
          vuln: {state: (if $vs == "partial" then "ok" else $vs end), findings: $vc, partial: ($vs == "partial"),
                 log: (if $ve == "" then null else $ve end)}}' > "$WORK/status.json" \
        && publish "$WORK/status.json" "$STATUS_DIR/$VHOST.json"

    log "$VHOST: $MALWARE_HITS malware, $MODIFIED modified, $DBHITS database, $PATTERNS suspicious code, $AUDITS audit, $VULNS vulnerabilit$([[ $VULNS -eq 1 ]] && echo y || echo ies) ($RECENT PHP files changed recently)"
    [[ -n "${EXTRA_ERR[$VHOST]}" ]] && log "    ${EXTRA_ERR[$VHOST]}"
    [[ -n "${VULN_ERR[$VHOST]}" ]] && log "    vulnerabilities: ${VULN_ERR[$VHOST]}"
    [[ -n "${MAL_ERR[$VHOST]}" ]] && log "    malware: ${MAL_ERR[$VHOST]}"

    [[ $MALWARE_HITS -gt 0 ]] && n_malware=$((n_malware + 1))
    [[ $MODIFIED -gt 0 ]] && n_modified=$((n_modified + 1))
    [[ $((DBHITS + PATTERNS)) -gt 0 ]] && n_suspicious=$((n_suspicious + 1))
    [[ $AUDITS -gt 0 ]] && n_audit=$((n_audit + 1))
    [[ $VULNS -gt 0 ]] && n_vuln=$((n_vuln + 1))
    if [[ "${MAL_STATE[$VHOST]}" != "ok" || "${VULN_STATE[$VHOST]}" == "error" ]]; then
        n_errors=$((n_errors + 1))
        SUMMARY_LINES+=("• $VHOST: check failed - ${VULN_ERR[$VHOST]}${MAL_ERR[$VHOST]:+ ${MAL_ERR[$VHOST]}}")
    fi
    if [[ $((MALWARE_HITS + MODIFIED + DBHITS + PATTERNS + AUDITS + VULNS)) -gt 0 ]]; then
        LINE="• $VHOST:"
        [[ $MALWARE_HITS -gt 0 ]] && LINE+=" $MALWARE_HITS malware,"
        [[ $MODIFIED -gt 0 ]] && LINE+=" $MODIFIED modified,"
        [[ $DBHITS -gt 0 ]] && LINE+=" $DBHITS database,"
        [[ $PATTERNS -gt 0 ]] && LINE+=" $PATTERNS suspicious code,"
        [[ $AUDITS -gt 0 ]] && LINE+=" $AUDITS audit,"
        [[ $VULNS -gt 0 ]] && LINE+=" $VULNS vulnerabilit$([[ $VULNS -eq 1 ]] && echo y || echo ies),"
        SUMMARY_LINES+=("${LINE%,}")
    fi

    PARTS=() ATTACH=()
    if [[ $((MALWARE_HITS + MODIFIED + DBHITS + PATTERNS + AUDITS)) -gt 0 && ( $MAL_CHANGED -eq 1 || $NOTIFY_ALL -eq 1 ) ]]; then
        [[ $MALWARE_HITS -gt 0 ]] && PARTS+=(":rotating_light: *$MALWARE_HITS malware detection(s)*")
        [[ $DBHITS -gt 0 ]] && PARTS+=(":rotating_light: *$DBHITS suspicious item(s) in the database* (injected scripts/hidden links)")
        [[ $PATTERNS -gt 0 ]] && PARTS+=(":mag: *$PATTERNS suspicious code pattern(s)* (obfuscated or backdoor-like PHP)")
        [[ $MODIFIED -gt 0 ]] && PARTS+=(":mag: *$MODIFIED file(s) differ from the official WordPress/plugin versions*")
        [[ $AUDITS -gt 0 ]] && PARTS+=(":clipboard: *$AUDITS audit finding(s)* (admins, permissions, exposed files, settings)")
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

SUMMARY="Security scan finished: ${#SITES[@]} site(s), $n_malware with malware, $n_suspicious with suspicious code/database content, $n_modified with modified files, $n_audit with audit findings, $n_vuln with vulnerabilities, $n_errors with errors$([[ $MALWARE -eq 0 ]] && echo ' (malware scan skipped)')."
log "$SUMMARY"
[[ ${#SUMMARY_LINES[@]} -gt 0 ]] && slack_message "$SUMMARY"$'\n'"$(printf '%s\n' "${SUMMARY_LINES[@]}")"

[[ $n_errors -gt 0 ]] && exit 2
exit 0
