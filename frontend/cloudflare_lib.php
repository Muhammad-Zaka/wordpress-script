<?php
/**
 * Cloudflare presentation helpers: grouping zone settings and rulesets into
 * sections (SSL/TLS, WAF, Rules, Speed, Cache, Network) and summarising rules.
 */

const CF_SECTIONS = [
    'ssl'     => ['SSL/TLS',  'shield-lock'],
    'waf'     => ['WAF & Security', 'bricks'],
    'rules'   => ['Rules',    'signpost-split'],
    'speed'   => ['Speed',    'lightning-charge'],
    'cache'   => ['Cache',    'database'],
    'network' => ['Network',  'diagram-3'],
    'other'   => ['Other',    'three-dots'],
];

/** Zone setting id => [section, label] */
const CF_SETTING_CATALOG = [
    // SSL/TLS
    'ssl'                      => ['ssl', 'Encryption mode'],
    'min_tls_version'          => ['ssl', 'Minimum TLS version'],
    'tls_1_3'                  => ['ssl', 'TLS 1.3'],
    'always_use_https'         => ['ssl', 'Always Use HTTPS'],
    'automatic_https_rewrites' => ['ssl', 'Automatic HTTPS Rewrites'],
    'opportunistic_encryption' => ['ssl', 'Opportunistic Encryption'],
    'security_header'          => ['ssl', 'HSTS'],
    'tls_client_auth'          => ['ssl', 'TLS client auth'],
    'ciphers'                  => ['ssl', 'Cipher suites'],
    'ssl_recommender'          => ['ssl', 'SSL/TLS Recommender'],
    'origin_max_http_version'  => ['network', 'Max HTTP version to origin'],
    // WAF & security
    'security_level'           => ['waf', 'Security level'],
    'challenge_ttl'            => ['waf', 'Challenge passage'],
    'browser_check'            => ['waf', 'Browser Integrity Check'],
    'waf'                      => ['waf', 'Legacy WAF'],
    'privacy_pass'             => ['waf', 'Privacy Pass'],
    'hotlink_protection'       => ['waf', 'Hotlink Protection'],
    'email_obfuscation'        => ['waf', 'Email Address Obfuscation'],
    'server_side_exclude'      => ['waf', 'Server-side Excludes'],
    'replace_insecure_js'      => ['waf', 'Replace insecure JS libraries'],
    // Speed
    'brotli'                   => ['speed', 'Brotli'],
    'early_hints'              => ['speed', 'Early Hints'],
    'http2'                    => ['speed', 'HTTP/2'],
    'http3'                    => ['speed', 'HTTP/3 (QUIC)'],
    '0rtt'                     => ['speed', '0-RTT Connection Resumption'],
    'h2_prioritization'        => ['speed', 'Enhanced HTTP/2 Prioritization'],
    'rocket_loader'            => ['speed', 'Rocket Loader'],
    'speed_brain'              => ['speed', 'Speed Brain'],
    'fonts'                    => ['speed', 'Cloudflare Fonts'],
    'mirage'                   => ['speed', 'Mirage'],
    'polish'                   => ['speed', 'Polish (image optimisation)'],
    'webp'                     => ['speed', 'Polish WebP'],
    'image_resizing'           => ['speed', 'Image Resizing'],
    'automatic_platform_optimization' => ['speed', 'APO for WordPress'],
    'prefetch_preload'         => ['speed', 'Prefetch preload'],
    'minify'                   => ['speed', 'Auto Minify (deprecated)'],
    'response_buffering'       => ['speed', 'Response buffering'],
    // Cache
    'cache_level'              => ['cache', 'Caching level'],
    'browser_cache_ttl'        => ['cache', 'Browser cache TTL'],
    'edge_cache_ttl'           => ['cache', 'Edge cache TTL'],
    'always_online'            => ['cache', 'Always Online'],
    'development_mode'         => ['cache', 'Development Mode'],
    'sort_query_string_for_cache' => ['cache', 'Query string sort'],
    'cache_deception_armor'    => ['cache', 'Cache Deception Armor'],
    'crawlhints'               => ['cache', 'Crawler Hints'],
    // Network
    'ipv6'                     => ['network', 'IPv6 compatibility'],
    'websockets'               => ['network', 'WebSockets'],
    'pseudo_ipv4'              => ['network', 'Pseudo IPv4'],
    'ip_geolocation'           => ['network', 'IP Geolocation'],
    'true_client_ip_header'    => ['network', 'True-Client-IP header'],
    'opportunistic_onion'      => ['network', 'Onion Routing'],
    'max_upload'               => ['network', 'Maximum upload size'],
    'nel'                      => ['network', 'Network Error Logging'],
    'visitor_ip'               => ['network', 'Visitor IP header'],
    'orange_to_orange'         => ['network', 'Orange-to-Orange'],
    'cname_flattening'         => ['network', 'CNAME flattening'],
    'email_routing'            => ['network', 'Email Routing'],
];

/** Ruleset phase => [section, label] */
const CF_PHASES = [
    'http_request_firewall_custom'    => ['waf',   'WAF custom rules'],
    'http_ratelimit'                  => ['waf',   'Rate limiting rules'],
    'http_request_firewall_managed'   => ['waf',   'Managed rules'],
    'http_request_sbfm'               => ['waf',   'Super Bot Fight Mode rules'],
    'ddos_l7'                         => ['waf',   'HTTP DDoS overrides'],
    'http_request_cache_settings'     => ['cache', 'Cache rules'],
    'http_request_dynamic_redirect'   => ['rules', 'Redirect rules'],
    'http_request_transform'          => ['rules', 'URL rewrite rules'],
    'http_request_late_transform'     => ['rules', 'Request header transform rules'],
    'http_response_headers_transform' => ['rules', 'Response header transform rules'],
    'http_config_settings'            => ['rules', 'Configuration rules'],
    'http_request_origin'             => ['rules', 'Origin rules'],
    'http_response_compression'       => ['rules', 'Compression rules'],
    'http_custom_errors'              => ['rules', 'Custom error rules'],
    'http_request_snippets'           => ['rules', 'Snippets rules'],
    'http_request_cloud_connector'    => ['rules', 'Cloud Connector rules'],
];

const CF_BOT_LABELS = [
    'fight_mode'                      => 'Bot Fight Mode',
    'enable_js'                       => 'JavaScript detections',
    'ai_bots_protection'              => 'Block AI bots',
    'crawler_protection'              => 'AI Labyrinth',
    'is_robots_txt_managed'           => 'Managed robots.txt',
    'sbfm_definitely_automated'       => 'SBFM: definitely automated',
    'sbfm_likely_automated'           => 'SBFM: likely automated',
    'sbfm_verified_bots'              => 'SBFM: verified bots',
    'sbfm_static_resource_protection' => 'SBFM: static resource protection',
    'optimize_wordpress'              => 'SBFM: optimise for WordPress',
    'auto_update_model'               => 'Auto-update model',
    'using_latest_model'              => 'Using latest model',
    'suppress_session_score'          => 'Suppress session score',
];

function humanize_key(string $k): string
{
    return ucfirst(str_replace('_', ' ', $k));
}

function human_duration($s): string
{
    if (!is_numeric($s)) return (string) $s;
    $s = (int) $s;
    if ($s === 0) return '0';
    foreach ([['y', 31536000], ['d', 86400], ['h', 3600], ['m', 60]] as [$u, $n]) {
        if ($s >= $n && $s % $n === 0) return ($s / $n) . $u;
    }
    return $s . 's';
}

/**
 * Returns [display string, state] where state is on | off | value.
 */
function cf_setting_view(string $key, $v): array
{
    switch ($key) {
        case 'security_header':
            $h = $v['strict_transport_security'] ?? [];
            if (empty($h['enabled'])) return ['Off', 'off'];
            $bits = ['max-age ' . human_duration($h['max_age'] ?? 0)];
            if (!empty($h['include_subdomains'])) $bits[] = 'includeSubDomains';
            if (!empty($h['preload'])) $bits[] = 'preload';
            if (!empty($h['nosniff'])) $bits[] = 'nosniff';
            return ['On · ' . implode(' · ', $bits), 'on'];
        case 'minify':
            $on = array_keys(array_filter((array) $v, fn($x) => $x === 'on'));
            return $on ? [strtoupper(implode(', ', $on)), 'on'] : ['Off', 'off'];
        case 'automatic_platform_optimization':
            if (empty($v['enabled'])) return ['Off', 'off'];
            $bits = [];
            if (!empty($v['cache_by_device_type'])) $bits[] = 'cache by device';
            if (!empty($v['hostnames'])) $bits[] = implode(', ', $v['hostnames']);
            return ['On' . ($bits ? ' · ' . implode(' · ', $bits) : ''), 'on'];
        case 'browser_cache_ttl':
            return [(int) $v === 0 ? 'Respect existing headers' : human_duration($v), 'value'];
        case 'edge_cache_ttl':
        case 'challenge_ttl':
            return [human_duration($v), 'value'];
        case 'max_upload':
            return [$v . ' MB', 'value'];
        case 'ciphers':
            return [$v ? implode(', ', (array) $v) : 'Default', 'value'];
        case 'tls_1_3':
            return [$v === 'zrt' ? 'On (with 0-RTT)' : ucfirst((string) $v), $v === 'off' ? 'off' : 'on'];
        case 'security_level':
            return [ucwords(str_replace('_', ' ', (string) $v)), in_array($v, ['off', 'essentially_off'], true) ? 'off' : 'value'];
    }
    if (is_bool($v)) return [$v ? 'On' : 'Off', $v ? 'on' : 'off'];
    if ($v === 'on')  return ['On', 'on'];
    if ($v === 'off') return ['Off', 'off'];
    if (is_array($v)) {
        if (array_key_exists('enabled', $v)) return [$v['enabled'] ? 'On' : 'Off', $v['enabled'] ? 'on' : 'off'];
        if (array_key_exists('status', $v))  return [ucfirst((string) $v['status']), $v['status'] === 'off' ? 'off' : 'on'];
        return [json_encode($v, JSON_UNESCAPED_SLASHES), 'value'];
    }
    if ($v === null) return ['—', 'value'];
    return [ucfirst((string) $v), 'value'];
}

/** Group zone settings by section: section => [ [key, label, display, state], ... ] */
function cf_grouped_settings(array $settings): array
{
    $out = [];
    foreach ($settings as $key => $v) {
        [$section, $label] = CF_SETTING_CATALOG[$key] ?? ['other', humanize_key($key)];
        [$display, $state] = cf_setting_view($key, $v);
        $out[$section][] = ['key' => $key, 'label' => $label, 'display' => $display, 'state' => $state];
    }
    foreach ($out as &$rows) {
        usort($rows, fn($a, $b) => strcmp($a['label'], $b['label']));
    }
    return $out;
}

/** Group zone rulesets by section: section => [ [label, phase, rules], ... ] */
function cf_grouped_rulesets(array $rulesets): array
{
    $out = [];
    foreach ($rulesets as $rs) {
        $phase = $rs['phase'] ?? 'unknown';
        [$section, $label] = CF_PHASES[$phase] ?? ['rules', humanize_key($phase)];
        $out[$section][] = ['label' => $label, 'phase' => $phase, 'rules' => $rs['rules'] ?? [], 'last_updated' => $rs['last_updated'] ?? null];
    }
    return $out;
}

function cf_action_class(string $action): string
{
    return [
        'block' => 'danger', 'challenge' => 'warning', 'managed_challenge' => 'warning', 'js_challenge' => 'warning',
        'skip' => 'success', 'allow' => 'success', 'log' => 'secondary', 'execute' => 'primary',
    ][$action] ?? 'info';
}

/** One-line human summary of what a rule does beyond its action */
function cf_rule_summary(array $r, array $names): string
{
    $a = $r['action'] ?? '';
    $p = $r['action_parameters'] ?? [];
    $parts = [];

    if (!empty($r['ratelimit'])) {
        $rl = $r['ratelimit'];
        $parts[] = ($rl['requests_per_period'] ?? '?') . ' req / ' . human_duration($rl['period'] ?? 0)
            . (!empty($rl['characteristics']) ? ' per ' . implode(' + ', $rl['characteristics']) : '')
            . (isset($rl['mitigation_timeout']) ? ', block ' . human_duration($rl['mitigation_timeout']) : '');
    }

    switch ($a) {
        case 'execute':
            $id = $p['id'] ?? '';
            $parts[] = 'Deploys ' . ($names[$id] ?? $id) . (!empty($p['overrides']) ? ' (with overrides)' : '');
            break;
        case 'skip':
            if (($p['ruleset'] ?? '') === 'current') $parts[] = 'remaining custom rules';
            if (!empty($p['phases']))   $parts[] = 'phases: ' . implode(', ', array_map(fn($x) => CF_PHASES[$x][1] ?? $x, $p['phases']));
            if (!empty($p['products'])) $parts[] = 'products: ' . implode(', ', $p['products']);
            if (!empty($p['rulesets'])) $parts[] = 'rulesets: ' . implode(', ', array_map(fn($x) => $names[$x] ?? $x, $p['rulesets']));
            if (!empty($p['rules']))    $parts[] = 'specific managed rules';
            break;
        case 'redirect':
            $f = $p['from_value'] ?? [];
            $t = $f['target_url']['value'] ?? $f['target_url']['expression'] ?? '?';
            $parts[] = ($f['status_code'] ?? 302) . ' → ' . $t . (!empty($f['preserve_query_string']) ? ' (keep query)' : '');
            break;
        case 'set_cache_settings':
            if (array_key_exists('cache', $p)) $parts[] = $p['cache'] ? 'Eligible for cache' : 'Bypass cache';
            if (!empty($p['edge_ttl']))    $parts[] = 'edge TTL ' . str_replace('_', ' ', $p['edge_ttl']['mode'] ?? '') . (isset($p['edge_ttl']['default']) ? ' ' . human_duration($p['edge_ttl']['default']) : '');
            if (!empty($p['browser_ttl'])) $parts[] = 'browser TTL ' . str_replace('_', ' ', $p['browser_ttl']['mode'] ?? '') . (isset($p['browser_ttl']['default']) ? ' ' . human_duration($p['browser_ttl']['default']) : '');
            if (!empty($p['cache_key']))   $parts[] = 'custom cache key';
            break;
        case 'rewrite':
            if (!empty($p['uri']['path']))  $parts[] = 'path → ' . ($p['uri']['path']['value'] ?? $p['uri']['path']['expression'] ?? '');
            if (!empty($p['uri']['query'])) $parts[] = 'query → ' . ($p['uri']['query']['value'] ?? $p['uri']['query']['expression'] ?? '');
            foreach ($p['headers'] ?? [] as $hname => $hv) {
                $parts[] = ($hv['operation'] ?? 'set') . ' ' . $hname . (isset($hv['value']) ? ': ' . $hv['value'] : '');
            }
            break;
        case 'route':
            if (!empty($p['host_header'])) $parts[] = 'Host: ' . $p['host_header'];
            if (!empty($p['origin']))      $parts[] = 'origin ' . trim(($p['origin']['host'] ?? '') . ':' . ($p['origin']['port'] ?? ''), ':');
            if (!empty($p['sni']['value'])) $parts[] = 'SNI ' . $p['sni']['value'];
            break;
        case 'set_config':
            foreach ($p as $k => $v) $parts[] = $k . '=' . (is_array($v) ? json_encode($v) : (is_bool($v) ? ($v ? 'on' : 'off') : $v));
            break;
        case 'compress_response':
            $parts[] = implode(', ', array_column($p['algorithms'] ?? [], 'name'));
            break;
        case 'serve_error':
            $parts[] = 'status ' . ($p['status_code'] ?? '?');
            break;
    }
    return implode(' · ', array_filter($parts));
}

function cf_rule_counts(array $s): array
{
    $c = ['total' => 0, 'enabled' => 0];
    foreach ($s['cloudflare']['rulesets'] ?? [] as $rs) {
        foreach ($rs['rules'] ?? [] as $r) {
            $c['total']++;
            if (!empty($r['enabled'])) $c['enabled']++;
        }
    }
    foreach ($s['cloudflare']['page_rules'] ?? [] as $pr) {
        $c['total']++;
        if (($pr['status'] ?? '') === 'active') $c['enabled']++;
    }
    return $c;
}
