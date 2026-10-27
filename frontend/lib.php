<?php
/**
 * Shared loading, normalisation and evaluation logic for the dashboard.
 */

$config = require __DIR__ . '/config.php';
require_once __DIR__ . '/cloudflare_lib.php';

// ---------------------------------------------------------------------------
// Optional basic auth
// ---------------------------------------------------------------------------
if (!empty($config['auth']['user'])) {
    $u = $_SERVER['PHP_AUTH_USER'] ?? '';
    $p = $_SERVER['PHP_AUTH_PW'] ?? '';
    if (!hash_equals($config['auth']['user'], $u) || !password_verify($p, $config['auth']['password_hash'])) {
        header('WWW-Authenticate: Basic realm="WordPress Fleet"');
        http_response_code(401);
        exit('Authentication required');
    }
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------
function h($v): string
{
    return htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');
}

function human_age(int $seconds): string
{
    if ($seconds < 3600)  return max(0, (int) floor($seconds / 60)) . 'm ago';
    if ($seconds < 86400) return (int) floor($seconds / 3600) . 'h ago';
    return (int) floor($seconds / 86400) . 'd ago';
}

function human_bytes($bytes): string
{
    if ($bytes === null || $bytes === '') return '—';
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    $b = (float) $bytes;
    while ($b >= 1024 && $i < count($units) - 1) { $b /= 1024; $i++; }
    return round($b, $i ? 1 : 0) . ' ' . $units[$i];
}

function fmt_value($v): string
{
    if ($v === null) return '—';
    if (is_bool($v)) return $v ? 'on' : 'off';
    if (is_array($v)) return json_encode($v, JSON_UNESCAPED_SLASHES);
    return (string) $v;
}

function valid_slug(string $s): bool
{
    return (bool) preg_match('/^[A-Za-z0-9._-]+$/', $s) && $s[0] !== '.';
}

// ---------------------------------------------------------------------------
// Wordfence CSV
// ---------------------------------------------------------------------------
function load_wordfence(string $slug, array $config): array
{
    $file = rtrim($config['malware_dir'], '/') . '/' . $slug . '.csv';
    $result = ['available' => false, 'issues' => 0, 'header' => [], 'rows' => [], 'scanned_at' => null];
    if (!valid_slug($slug) || !is_file($file) || !is_readable($file)) {
        return $result;
    }
    $rows = [];
    if (($fh = fopen($file, 'r')) !== false) {
        while (($row = fgetcsv($fh, 0, ',', '"', '\\')) !== false) {
            if (array_filter($row, fn($c) => trim((string) $c) !== '')) {
                $rows[] = $row;
            }
        }
        fclose($fh);
    }
    if ($config['wordfence_csv_has_header'] && $rows) {
        $result['header'] = array_shift($rows);
    }
    $result['available']  = true;
    $result['rows']       = $rows;
    $result['issues']     = count($rows);
    $result['scanned_at'] = filemtime($file);
    return $result;
}

// ---------------------------------------------------------------------------
// Cloudflare compliance
// ---------------------------------------------------------------------------
function cloudflare_compliance(array $site, array $config): array
{
    $settings = $site['cloudflare']['settings'] ?? [];
    $checks = [];
    $passed = $evaluated = $highFails = 0;

    foreach ($config['cloudflare_standard'] as $key => $rule) {
        $present = array_key_exists($key, $settings);
        $actual = $present ? $settings[$key] : null;
        if ($present && isset($rule['path']) && is_array($actual)) {
            $actual = $actual[$rule['path']] ?? null;
        }
        $expect = (array) $rule['expect'];
        $state = 'missing';
        if ($present) {
            $evaluated++;
            $ok = false;
            foreach ($expect as $e) {
                // Compare loosely so "on"/true and "1.2"/1.2 style values line up
                if ($actual === $e || fmt_value($actual) === fmt_value($e)) { $ok = true; break; }
            }
            $state = $ok ? 'pass' : 'fail';
            if ($ok) $passed++;
            elseif (($rule['severity'] ?? 'low') === 'high') $highFails++;
        }
        $checks[] = [
            'key'      => $key,
            'label'    => $rule['label'] ?? $key,
            'severity' => $rule['severity'] ?? 'low',
            'expect'   => implode(' / ', array_map('fmt_value', $expect)),
            'actual'   => $present ? fmt_value($actual) : null,
            'state'    => $state,
        ];
    }

    $score = $evaluated ? (int) round($passed / $evaluated * 100) : null;
    return [
        'checks'    => $checks,
        'passed'    => $passed,
        'evaluated' => $evaluated,
        'failed'    => $evaluated - $passed,
        'high_fails'=> $highFails,
        'score'     => $score,
        'compliant' => $evaluated > 0 && $passed === $evaluated,
    ];
}

// ---------------------------------------------------------------------------
// Health checks (one list used by both the dashboard and the site page)
// level: danger | warning | info
// ---------------------------------------------------------------------------
function health_checks(array $s, array $config): array
{
    $out = [];
    $add = function ($level, $label, $detail = '') use (&$out) {
        $out[] = ['level' => $level, 'label' => $label, 'detail' => $detail];
    };
    $env = $s['environment'] ?? [];

    if ($s['_stale'])                                    $add('warning', 'Report stale', 'Last collected ' . $s['_age']);
    if (!empty($s['errors']))                            $add('warning', 'Collector warnings', count($s['errors']) . ' warning(s) during collection');
    if ($s['_wf']['issues'] > 0)                         $add('danger', 'Wordfence issues', $s['_wf']['issues'] . ' finding(s)');
    if (($s['wordpress']['checksums'] ?? '') === 'failed') $add('danger', 'Core checksums failed', 'Core files modified or unexpected files present');
    if (!empty($s['cloudflare']['paused']))              $add('danger', 'Cloudflare paused', 'Traffic is bypassing Cloudflare');
    if (!empty($env['wp_debug_display']))                $add('danger', 'Debug output visible', 'WP_DEBUG with WP_DEBUG_DISPLAY on');
    if (array_key_exists('blog_public', $env) && !$env['blog_public']) $add('danger', 'Search engines blocked', '"Discourage search engines" is enabled');

    if ($s['wordpress']['update_available'] ?? false) {
        $v = $s['wordpress']['updates'][0]['version'] ?? '';
        $add('warning', 'Core update', $v ? "WordPress $v available" : 'Update available');
    }
    if (($s['wordpress']['update_check_status'] ?? 'ok') === 'error') $add('warning', 'Core update check failed');
    if ($s['plugins']['updates_available'] > 0)          $add('warning', 'Plugin updates', $s['plugins']['updates_available'] . ' plugin(s)');
    if ($s['themes']['updates_available'] > 0)           $add('warning', 'Theme updates', $s['themes']['updates_available'] . ' theme(s)');
    if (!empty($env['php_version']) && version_compare($env['php_version'], $config['min_php_version'], '<'))
        $add('warning', 'Old PHP', 'PHP ' . $env['php_version'] . ' (min ' . $config['min_php_version'] . ')');
    if (($env['autoload_bytes'] ?? 0) > $config['max_autoload_bytes'])
        $add('warning', 'Large autoload', human_bytes($env['autoload_bytes']) . ' autoloaded options');
    $cfs = $s['cloudflare']['settings'] ?? [];
    if (($cfs['security_level'] ?? '') === 'under_attack') $add('warning', 'Under Attack mode on', 'All visitors are being challenged');
    if (($cfs['development_mode'] ?? '') === 'on')        $add('warning', 'Development mode on', 'Cloudflare cache is bypassed');
    foreach ($s['cloudflare']['ssl']['certificate_packs'] ?? [] as $cp) {
        if (($cp['status'] ?? '') !== 'active' && ($cp['status'] ?? '') !== '') {
            $add('danger', 'Edge certificate ' . $cp['status'], implode(', ', $cp['hosts'] ?? []));
        } elseif (!empty($cp['expires_on']) && strtotime($cp['expires_on']) < time() + 14 * 86400) {
            $add('danger', 'Edge certificate expiring', 'Expires ' . date('Y-m-d', strtotime($cp['expires_on'])));
        }
    }
    if (!empty($s['cloudflare']['fetch_errors']))         $add('info', 'Cloudflare data incomplete', count($s['cloudflare']['fetch_errors']) . ' API call(s) failed');
    if ($s['_cf']['high_fails'] > 0)                     $add('warning', 'Cloudflare non-compliant', $s['_cf']['high_fails'] . ' high-severity setting(s)');

    if (!empty($env['wp_debug']) && empty($env['wp_debug_display'])) $add('info', 'WP_DEBUG on');
    if (($env['admins'] ?? 0) > $config['max_admins'])  $add('info', 'Many admins', $env['admins'] . ' administrator accounts');
    if (array_key_exists('disallow_file_edit', $env) && !$env['disallow_file_edit']) $add('info', 'File editor enabled', 'DISALLOW_FILE_EDIT not set');
    if ($s['plugins']['inactive'] > 0)                   $add('info', 'Inactive plugins', $s['plugins']['inactive'] . ' installed but inactive');
    if (($env['cron_overdue'] ?? 0) > 0)                 $add('info', 'Overdue cron', $env['cron_overdue'] . ' event(s) over 1h late');

    return $out;
}

// ---------------------------------------------------------------------------
// Loading + normalising reports
// ---------------------------------------------------------------------------
function normalise_site(array $data, string $file, array $config): array
{
    $hidden = array_map('strtolower', $config['hidden_themes']);

    // Plugins: recompute counts from items so older reports (which counted drop-ins) are consistent
    $plugins = $data['plugins']['items'] ?? [];
    $regular = array_values(array_filter($plugins, fn($p) => !in_array($p['status'] ?? '', ['dropin', 'must-use'], true)));
    $data['plugins'] = [
        'items'             => $plugins,
        'total'             => count($regular),
        'active'            => count(array_filter($regular, fn($p) => in_array($p['status'] ?? '', ['active', 'active-network'], true))),
        'inactive'          => count(array_filter($regular, fn($p) => ($p['status'] ?? '') === 'inactive')),
        'must_use'          => count(array_filter($plugins, fn($p) => ($p['status'] ?? '') === 'must-use')),
        'updates_available' => count(array_filter($regular, fn($p) => ($p['update'] ?? '') === 'available')),
    ];

    $themes = array_values(array_filter($data['themes']['items'] ?? [], fn($t) => !in_array(strtolower($t['name'] ?? ''), $hidden, true)));
    $data['themes'] = [
        'items'             => $themes,
        'total'             => count($themes),
        'updates_available' => count(array_filter($themes, fn($t) => ($t['update'] ?? '') === 'available')),
        'active'            => array_values(array_filter($themes, fn($t) => ($t['status'] ?? '') === 'active'))[0]['name'] ?? null,
    ];

    $data['site']   = $data['site'] ?? basename($file, '.json');
    $data['domain'] = $data['domain'] ?? $data['site'];
    $data['errors'] = $data['errors'] ?? [];

    $generated = !empty($data['generated_at']) ? strtotime($data['generated_at']) : false;
    $ts = $generated ?: filemtime($file);
    $data['_ts']    = $ts;
    $data['_age']   = human_age(time() - $ts);
    $data['_stale'] = (time() - $ts) > $config['stale_after_hours'] * 3600;

    $plan = $data['cloudflare']['plan'] ?? 'none';
    $status = $data['cloudflare']['status'] ?? 'inactive';
    $data['_has_cf'] = strcasecmp($plan, 'none') !== 0 && strcasecmp($status, 'inactive') !== 0;

    $data['_wf']     = load_wordfence(basename($file, '.json'), $config);
    $data['_cf']     = cloudflare_compliance($data, $config);
    $data['_health'] = health_checks($data, $config);
    $data['_needs_update'] = ($data['wordpress']['update_available'] ?? false)
        || $data['plugins']['updates_available'] > 0
        || $data['themes']['updates_available'] > 0;

    return $data;
}

function load_site_file(string $file, array $config): ?array
{
    $data = json_decode((string) @file_get_contents($file), true);
    return is_array($data) ? normalise_site($data, $file, $config) : null;
}

/** @return array{0: array, 1: int, 2: array} [sites, hiddenCount, unreadableFiles] */
function load_sites(array $config): array
{
    $dir = rtrim($config['metrics_dir'], '/') . '/';
    $sites = [];
    $hidden = 0;
    $bad = [];
    foreach (glob($dir . '*.json') ?: [] as $file) {
        $site = load_site_file($file, $config);
        if ($site === null) { $bad[] = basename($file); continue; }
        if ($config['hide_sites_without_cloudflare'] && !$site['_has_cf']) { $hidden++; continue; }
        $sites[] = $site;
    }
    usort($sites, fn($a, $b) => strcmp($a['domain'], $b['domain']));
    return [$sites, $hidden, $bad];
}

function level_badge(string $level): string
{
    return ['danger' => 'danger', 'warning' => 'warning', 'info' => 'secondary'][$level] ?? 'secondary';
}
