# WordPress Fleet Metrics

Collects WordPress + Cloudflare metrics for every OpenLiteSpeed vhost and shows them in a PHP dashboard.

```
scripts/wordpress-metrics.sh   collector (run as root via cron) -> one JSON per site
scripts/security-scan.sh       vulnerability, modified-file and malware scans -> dashboard reports, Slack alerts
scripts/cloudflare-set-min-tls.sh  raise Cloudflare minimum TLS across zones
scripts/cloudflare-zone-ids.sh list Cloudflare Zone ID + Account ID for every site
scripts/cloudflare-plugin-keys.sh  set the Cloudflare WP plugin's API token per site, by account
frontend/config.php            paths, thresholds, Cloudflare standard, optional auth
frontend/lib.php               loading, normalising, health checks, compliance
frontend/index.php             fleet dashboard
frontend/site.php              per-site detail page
frontend/site_cloudflare.php   Cloudflare tab (SSL/TLS, WAF, Rules, Speed, Cache, Network, Standard)
frontend/cloudflare_lib.php    setting catalogue, rule phases, rule summaries
frontend/layout.php            shared page header/footer and design tokens (light + dark)
```

## Collector

```bash
sudo ./scripts/wordpress-metrics.sh              # all vhosts
sudo ./scripts/wordpress-metrics.sh athleticia   # one or more vhosts
```

Credentials in `~/.site-setup/creds` — either a scoped API token (preferred) or the legacy global key:

```bash
cf_token="..."                    # scoped API token (see permissions below)
# or
cf_email="..."; cf_key="..."
```

Without credentials the WordPress data is still collected; Cloudflare is skipped.

API token permissions (all **Read**, zone-level): Zone, Zone Settings, Zone WAF, Firewall Services,
SSL and Certificates, Cache Rules, Config Rules, Transform Rules, Dynamic URL Redirects, Origin Rules,
Page Rules, Bot Management, DNS, Email Routing Rules. Any call that fails is listed per site under
Cloudflare → Summary → "Not collected", so missing permissions are easy to spot.

### Cloudflare data collected per zone

| Section | Source |
|---|---|
| All zone settings | `GET /zones/{id}/settings` (one bulk call) + individual calls for settings not in bulk |
| SSL/TLS | universal SSL, edge certificate packs (CA, hosts, expiry), DNSSEC, Authenticated Origin Pulls, Total TLS |
| WAF & Security | bot management, leaked credentials detection, IP access rules, zone lockdown / UA rules |
| Rules | every zone ruleset: WAF custom, managed, rate limiting, cache, redirect, URL rewrite, header transforms, config, origin, compression, custom errors; legacy page rules |
| Cache / Speed | tiered cache, smart topology, regional tiered cache, cache reserve, Argo smart routing |

That's about 25 API calls per zone, throttled by `CF_DELAY` (default 0.15s) to stay under
Cloudflare's 1200 requests / 5 minutes limit.

Suggested cron (overlapping runs are prevented with a lock):

```
15 */6 * * * /path/to/scripts/wordpress-metrics.sh >> /var/log/wordpress-metrics.log 2>&1
```

## Security scans

Wordfence CLI was discontinued (no new licences; the free version reached end of life on
14 Oct 2026), so `scripts/security-scan.sh` replaces `wordfence-scan.sh` with free tools:

| Check | How |
|---|---|
| Known vulnerabilities | installed core/plugin/theme versions (WP-CLI) matched against the free [WPVulnerability](https://www.wpvulnerability.net) database; answers cached 12h |
| Modified files | `wp core verify-checksums` and `wp plugin verify-checksums --all` (wordpress.org plugins) |
| Malware | one ClamAV scan for all sites using Linux Malware Detect (maldet) signatures |

WP-CLI runs with `--skip-plugins --skip-themes`, so a compromised site's code is never executed.

Additional checks (all in the same run and report):

| Check | What it flags |
|---|---|
| Database | posts and options containing injected scripts (`eval(`, `atob(`, `fromCharCode`, `base64_decode`...), hidden iframes and hidden links. Options matching `DB_IGNORE_OPTIONS` (caches) are skipped |
| Suspicious code | PHP with `eval(base64_decode(...))`-style obfuscation, nested decoding, code run from `$_POST/$_GET`, includes of `.ico/.png/.txt` files, long hex-escaped strings (patterns in `SUSPICIOUS_PATTERNS`) |
| Audit | administrators added since the first scan (or registered in the last 30 days), open registration with an admin/editor default role, `siteurl`/`home` pointing elsewhere, PHP files in uploads, world-writable files, backups/logs/`.git`/`.env` in the web root, changes to `wp-config.php` / `.htaccess` / `.user.ini` |
| Recently changed | PHP files changed in the last 3 days, for review only (never alerts) |

Baselines for admins and key file hashes are kept in `/var/lib/security-scan/<vhost>/`. The first run
records the baseline; later runs flag what changed.

```bash
sudo ./scripts/security-scan.sh                 # all WordPress vhosts
sudo ./scripts/security-scan.sh athleticia      # one or more vhosts
sudo ./scripts/security-scan.sh --no-malware    # vulnerabilities + checksums only (fast)
sudo ./scripts/security-scan.sh --no-slack
sudo ./scripts/security-scan.sh --notify-all    # alert for every site with findings, not just changes
```

One-time setup for the malware scan (Debian/Ubuntu):

```bash
sudo apt install clamav clamav-freshclam          # ClamAV + automatic signature updates
cd /tmp && wget https://www.rfxn.com/downloads/maldetect-current.tar.gz
tar xzf maldetect-current.tar.gz && cd maldetect-*/ && sudo ./install.sh   # installs maldet + daily signature updates
sudo maldet -u                                    # fetch the latest maldet signatures now
```

ClamAV needs roughly 1-1.5 GB of free RAM while it loads signatures. Without ClamAV installed the
script still runs the vulnerability and checksum checks.

The malware scan skips media in `wp-content/uploads` (the slow part) but still scans PHP and other
script files there. Set `UPLOADS_MODE` at the top of the script to `skip` or `full` to change that.

Per site it writes:

| File | Used by |
|---|---|
| `/nas/metrics/public_html/malware-reports/<vhost>.csv` | dashboard: malware + modified files (`source,file,detection`) |
| `/nas/metrics/public_html/vuln-reports/<vhost>.csv` | dashboard: vulnerabilities (`type,slug,installed_version,vulnerability,severity,fixed_in,link`) |
| `/nas/metrics/public_html/security-status/<vhost>.json` | dashboard: scan time, failures |
| `/nas/metrics/security-history/<vhost>/<date>-{malware,vuln}.csv` | history, kept 30 days |
| `/home/<vhost>/{malware,vuln}-scan.csv` | the original locations |

A check that fails keeps the previous report (the dashboard shows the failure instead of "clean").
Slack alerts are sent only when a site's findings change, with the CSVs attached, plus one summary
per run. Slack settings go in `~/.site-setup/creds`:

```bash
slack_webhook_url="https://hooks.slack.com/services/..."
slack_bot_token="xoxb-..."        # optional, to attach CSVs (scope: files:write, bot in channel)
slack_channel_id="C0123456789"    # channel ID, not #name
```

Suggested cron: `30 2 * * * /path/to/scripts/security-scan.sh >> /var/log/security-scan.log 2>&1`

## Cloudflare Zone and Account IDs

```bash
./scripts/cloudflare-zone-ids.sh                    # all vhosts: table on screen + CSV file
./scripts/cloudflare-zone-ids.sh --wordpress-only   # only WordPress sites
./scripts/cloudflare-zone-ids.sh --json             # JSON instead of the table
./scripts/cloudflare-zone-ids.sh --csv zones.csv    # choose the CSV path
```

The CSV has: vhost, domain, wordpress, zone_name, zone_id, account_id, account_name, plan, status, note.
Subdomain sites resolve to their parent zone. Needs only Zone: Read.

## Cloudflare plugin API tokens

`scripts/cloudflare-plugin-keys.sh` sets `cloudflare_api_key` (and optionally `cloudflare_api_email`) for the
Cloudflare WordPress plugin on every site, using the token of the Cloudflare account that owns the site's zone.

Key file `~/.site-setup/cloudflare-plugin-keys` (`chmod 600`), one account per line:

```
# account_id                          api_token                                  email (optional)
9f1e2d3c4b5a69788776655443322110      AbCdEf0123456789AbCdEf0123456789AbCdEf01
1234567890abcdef1234567890abcdef      ZyXwVu9876543210ZyXwVu9876543210ZyXwVu98   ops@example.com
```

```bash
sudo ./scripts/cloudflare-plugin-keys.sh                 # dry run
sudo ./scripts/cloudflare-plugin-keys.sh --apply         # update the sites
sudo ./scripts/cloudflare-plugin-keys.sh athleticia --apply
sudo ./scripts/cloudflare-plugin-keys.sh --rollback ~/.site-setup/cloudflare-plugin-backups/<stamp>.tsv --apply
```

Before writing, each token is checked with Cloudflare (active, and able to see the site's zone); sites
without the plugin, without a zone, or whose account has no token are skipped. Tokens are passed to
WP-CLI on stdin (never on the command line), logs show only the last 4 characters, and the previous
values are saved in `~/.site-setup/cloudflare-plugin-backups/` (mode 600) for rollback.

## Raising Cloudflare minimum TLS

`scripts/cloudflare-set-min-tls.sh` sets "Minimum TLS Version" to 1.2 across zones. It is a dry run
unless you pass `--apply`, never lowers a zone that is already higher (e.g. 1.3) unless `--exact` is
given, and writes a CSV audit log that can be replayed with `--rollback`.

```bash
./scripts/cloudflare-set-min-tls.sh                         # dry run: WordPress vhosts on this server
./scripts/cloudflare-set-min-tls.sh --apply                 # apply to those zones
./scripts/cloudflare-set-min-tls.sh --all-zones --apply     # every zone in the Cloudflare account
./scripts/cloudflare-set-min-tls.sh example.com --apply     # specific domains
./scripts/cloudflare-set-min-tls.sh --rollback min-tls-20261027-224500.csv --apply
```

Needs **Zone Settings: Edit** on the API token (the global key works as-is).

## Frontend

Deploy the `frontend/` folder. Paths default to `/nas/...` and can be overridden in `config.php`
or with `WPM_METRICS_DIR` / `WPM_MALWARE_DIR` / `WPM_VULN_DIR` / `WPM_WF_STATUS_DIR` environment variables.

Backups are read from `/nas/metrics/public_html/backups/<vhost>.csv` (columns: File Name, Backup Date,
Backup Type, Extension). Backups are informational only (Backups tab and dashboard column); they don't raise warnings.
`backup_max_age_days` in `config.php` sets which types the 30-day strip expects and the age shown as
"older than N days" in the tab. Override the folder
with `WPM_BACKUPS_DIR`.

The Cloudflare standard lives in `config.php` → `cloudflare_standard`. Each rule has an expected
value (or list of values) and a severity; any `high` failure marks the zone as non-compliant.
Add `'skip_plans' => ['Free']` to a rule for features a plan doesn't include (APO is set up this way).

Local preview against the sample data:

```bash
cd frontend && WPM_METRICS_DIR=../metrics/wordpress php -S localhost:8000
```

The CMS tab lists every top-level folder in the document root with permissions, owner and a
best-guess of what it contains (WordPress with version, Joomla, Drupal, Magento, PrestaShop, OpenCart,
Laravel, PHP, static HTML), plus the WordPress folders and key files (`wp-config.php`, `.htaccess`, ...).
World-writable entries and entries not owned by the site user are highlighted.

## Report format (schema v2, script 2.2)

New top-level keys compared to v1: `schema_version`, `script_version`, `aliases`, `errors`,
`environment` (PHP/MySQL versions, debug flags, admins, autoload size, cron, disk usage),
`wordpress.checksums`, `cloudflare.zone_name / paused / name_servers`. Script 2.1 adds
`cloudflare.ssl`, `cloudflare.cache`, `cloudflare.speed`, `cloudflare.security`, `cloudflare.rulesets`,
`cloudflare.ruleset_names`, `cloudflare.page_rules`, `cloudflare.fetch_errors`, and stores all zone settings.
Script 2.2 adds `docroot` (folders and key files with mode, owner, group, modified, detected CMS). The dashboard reads
v1 reports too; the new fields simply show as "not collected" until the script is re-run.
