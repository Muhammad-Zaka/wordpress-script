<?php
/**
 * Dashboard configuration.
 * Paths can be overridden with environment variables (handy for local testing):
 *   WPM_METRICS_DIR, WPM_MALWARE_DIR
 */

return [
    // Where wordpress-metrics.sh writes one JSON file per site
    'metrics_dir' => getenv('WPM_METRICS_DIR') ?: '/nas/wp-metrics-test1/',

    // Wordfence scan CSVs (one per site, named <vhost>.csv)
    'malware_dir' => getenv('WPM_MALWARE_DIR') ?: '/nas/metrics/public_html/malware-reports/',

    // Backup report CSVs (one per site, named <vhost>.csv)
    'backups_dir' => getenv('WPM_BACKUPS_DIR') ?: '/nas/metrics/public_html/backups/',

    // Flag a site when its newest backup of a type is older than N days.
    // The first type listed is shown in the dashboard's Backups column.
    'backup_max_age_days' => [
        'Database'         => 2,
        'Database Archive' => 2,
    ],

    // Set true if the Wordfence CSVs always start with a header row.
    // With false, ANY non-empty row counts as an issue (the original behaviour).
    'wordfence_csv_has_header' => false,

    // A report older than this is flagged as stale
    'stale_after_hours' => 26,

    // Hide sites with no active Cloudflare zone (the original behaviour).
    // Hidden sites are still counted and mentioned on the dashboard.
    'hide_sites_without_cloudflare' => true,

    // Themes excluded from counts/update alerts (e.g. bundled default themes)
    'hidden_themes' => ['twentytwentyfive'],

    // Health thresholds
    'min_php_version'     => '8.1',
    'max_admins'          => 3,
    'max_autoload_bytes'  => 1024 * 1024, // 1 MB

    // Optional HTTP Basic Auth for the dashboard. Leave user empty to disable.
    // Generate a hash with: php -r 'echo password_hash("yourpassword", PASSWORD_DEFAULT);'
    'auth' => [
        'user'          => '',
        'password_hash' => '',
    ],

    /**
     * Cloudflare standard: the settings every zone should have.
     *   expect   => a value, or a list of acceptable values
     *   path     => (optional) key inside an object value, e.g. APO's "enabled"
     *   severity => high | medium | low   (high failures make a zone non-compliant)
     *   skip_plans => (optional) Cloudflare plans the rule doesn't apply to, e.g. ['Free']
     * Settings missing from a report (older script versions) show as "not collected"
     * and are not counted against the zone.
     */
    'cloudflare_standard' => [
        'ssl'                             => ['label' => 'SSL/TLS mode',              'expect' => ['strict', 'full'], 'severity' => 'high'],
        'always_use_https'                => ['label' => 'Always Use HTTPS',          'expect' => 'on',  'severity' => 'high'],
        'min_tls_version'                 => ['label' => 'Minimum TLS version',       'expect' => ['1.2', '1.3'], 'severity' => 'high'],
        'tls_1_3'                         => ['label' => 'TLS 1.3',                   'expect' => ['on', 'zrt'], 'severity' => 'medium'],
        'automatic_https_rewrites'        => ['label' => 'Automatic HTTPS Rewrites',  'expect' => 'on',  'severity' => 'medium'],
        'opportunistic_encryption'        => ['label' => 'Opportunistic Encryption',  'expect' => 'on',  'severity' => 'low'],
        'http3'                           => ['label' => 'HTTP/3 (QUIC)',             'expect' => 'on',  'severity' => 'low'],
        '0rtt'                            => ['label' => '0-RTT',                     'expect' => 'on',  'severity' => 'low'],
        'early_hints'                     => ['label' => 'Early Hints',               'expect' => 'on',  'severity' => 'low'],
        'speed_brain'                     => ['label' => 'Speed Brain',               'expect' => 'on',  'severity' => 'low'],
        'rocket_loader'                   => ['label' => 'Rocket Loader',             'expect' => 'on',  'severity' => 'low'],
        'brotli'                          => ['label' => 'Brotli',                    'expect' => 'on',  'severity' => 'low'],
        'email_obfuscation'               => ['label' => 'Email Obfuscation',         'expect' => 'on',  'severity' => 'low'],
        'hotlink_protection'              => ['label' => 'Hotlink Protection',        'expect' => 'on',  'severity' => 'low'],
        'browser_check'                   => ['label' => 'Browser Integrity Check',   'expect' => 'on',  'severity' => 'medium'],
        'development_mode'                => ['label' => 'Development Mode',          'expect' => 'off', 'severity' => 'medium'],
        'automatic_platform_optimization' => ['label' => 'APO for WordPress',         'expect' => true,  'path' => 'enabled', 'severity' => 'medium', 'skip_plans' => ['Free']],
        'email_routing'                   => ['label' => 'Email Routing',             'expect' => true,  'severity' => 'low'],
    ],
];
