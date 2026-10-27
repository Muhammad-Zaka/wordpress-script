# WordPress Fleet Metrics

Collects WordPress + Cloudflare metrics for every OpenLiteSpeed vhost and shows them in a PHP dashboard.

```
scripts/wordpress-metrics.sh   collector (run as root via cron) -> one JSON per site
frontend/config.php            paths, thresholds, Cloudflare standard, optional auth
frontend/lib.php               loading, normalising, health checks, compliance
frontend/index.php             fleet dashboard
frontend/site.php              per-site detail page
frontend/layout.php            shared page header/footer
```

## Collector

```bash
sudo ./scripts/wordpress-metrics.sh              # all vhosts
sudo ./scripts/wordpress-metrics.sh athleticia   # one or more vhosts
```

Credentials in `~/.site-setup/creds` — either a scoped API token (preferred) or the legacy global key:

```bash
cf_token="..."                    # Zone:Read + Zone Settings:Read
# or
cf_email="..."; cf_key="..."
```

Without credentials the WordPress data is still collected; Cloudflare is skipped.

Suggested cron (overlapping runs are prevented with a lock):

```
15 */6 * * * /path/to/scripts/wordpress-metrics.sh >> /var/log/wordpress-metrics.log 2>&1
```

## Frontend

Deploy the `frontend/` folder. Paths default to `/nas/...` and can be overridden in `config.php`
or with `WPM_METRICS_DIR` / `WPM_MALWARE_DIR` environment variables.

The Cloudflare standard lives in `config.php` → `cloudflare_standard`. Each rule has an expected
value (or list of values) and a severity; any `high` failure marks the zone as non-compliant.

Local preview against the sample data:

```bash
cd frontend && WPM_METRICS_DIR=../metrics/wordpress php -S localhost:8000
```

## Report format (schema v2)

New top-level keys compared to v1: `schema_version`, `script_version`, `aliases`, `errors`,
`environment` (PHP/MySQL versions, debug flags, admins, autoload size, cron, disk usage),
`wordpress.checksums`, `cloudflare.zone_name / paused / name_servers`. The dashboard reads
v1 reports too; the new fields simply show as "not collected" until the script is re-run.
