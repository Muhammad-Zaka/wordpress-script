# WordPress Fleet Metrics

Collects WordPress + Cloudflare metrics for every OpenLiteSpeed vhost and shows them in a PHP dashboard.

```
scripts/wordpress-metrics.sh   collector (run as root via cron) -> one JSON per site
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

## Frontend

Deploy the `frontend/` folder. Paths default to `/nas/...` and can be overridden in `config.php`
or with `WPM_METRICS_DIR` / `WPM_MALWARE_DIR` environment variables.

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
