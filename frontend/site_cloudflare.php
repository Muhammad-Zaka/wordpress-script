<?php
/**
 * Cloudflare tab of site.php. Expects: $s (site), $cfd (cloudflare data), $cf (compliance), $config.
 */
$names    = $cfd['ruleset_names'] ?? [];
$settings = cf_grouped_settings($cfd['settings'] ?? []);
$rulesets = cf_grouped_rulesets($cfd['rulesets'] ?? []);
$full     = array_key_exists('rulesets', $cfd);
$sslx     = $cfd['ssl'] ?? [];
$cachex   = $cfd['cache'] ?? [];
$speedx   = $cfd['speed'] ?? [];
$secx     = $cfd['security'] ?? [];

// Extra (non zone-setting) rows per section, same shape as cf_grouped_settings rows
$row = function (string $label, $value, ?string $key = null) {
    [$display, $state] = cf_setting_view($key ?? '', $value);
    return ['key' => $key ?? '', 'label' => $label, 'display' => $display, 'state' => $state];
};
$extra = ['ssl' => [], 'waf' => [], 'speed' => [], 'cache' => []];
if (array_key_exists('universal_ssl', $sslx))              $extra['ssl'][] = $row('Universal SSL', (bool) $sslx['universal_ssl']);
if (array_key_exists('authenticated_origin_pulls', $sslx)) $extra['ssl'][] = $row('Authenticated Origin Pulls', (bool) $sslx['authenticated_origin_pulls']);
if (array_key_exists('dnssec', $sslx))                     $extra['ssl'][] = $row('DNSSEC', $sslx['dnssec'] === 'active' ? true : ($sslx['dnssec'] === 'disabled' ? false : $sslx['dnssec']));
if (isset($sslx['total_tls']))                             $extra['ssl'][] = $row('Total TLS', $sslx['total_tls']);
foreach (['tiered_caching' => 'Tiered Cache', 'smart_tiered_cache' => 'Smart Tiered Cache topology', 'regional_tiered_cache' => 'Regional Tiered Cache', 'cache_reserve' => 'Cache Reserve'] as $k => $label) {
    if (array_key_exists($k, $cachex)) $extra['cache'][] = $row($label, $cachex[$k]);
}
if (array_key_exists('argo_smart_routing', $speedx)) $extra['speed'][] = $row('Argo Smart Routing', $speedx['argo_smart_routing']);
foreach ($secx['bot_management'] ?? [] as $k => $v) {
    if (is_array($v)) continue;
    $label = CF_BOT_LABELS[$k] ?? humanize_key($k);
    $extra['waf'][] = is_string($v) && !in_array($v, ['on', 'off'], true)
        ? ['key' => $k, 'label' => $label, 'display' => ucfirst(str_replace('_', ' ', $v)), 'state' => in_array($v, ['disabled', 'off'], true) ? 'off' : 'on']
        : $row($label, $v, $k);
}
if (array_key_exists('leaked_credential_checks', $secx)) $extra['waf'][] = $row('Leaked credentials detection', (bool) $secx['leaked_credential_checks']);

// Per-section counts for the nav
$count = function (string $sec) use ($settings, $extra, $rulesets) {
    $on = 0;
    foreach (array_merge($settings[$sec] ?? [], $extra[$sec] ?? []) as $r) if ($r['state'] !== 'off') $on++;
    $rules = 0;
    foreach ($rulesets[$sec] ?? [] as $g) foreach ($g['rules'] as $r) if (!empty($r['enabled'])) $rules++;
    return [$on, $rules];
};
$pageRules = $cfd['page_rules'] ?? [];
$accessRules = $secx['ip_access_rules'] ?? [];

function cf_settings_table(array $rows, string $title): void
{
    if (!$rows) return; ?>
    <section class="panel">
        <div class="panel-head"><h3 class="t-h2 m-0"><?= h($title) ?></h3></div>
        <div class="table-responsive">
        <table class="table align-middle">
            <tbody>
            <?php foreach ($rows as $r): ?>
                <tr data-state="<?= h($r['state']) ?>">
                    <td style="width: 42%"><?= h($r['label']) ?><?php if ($r['key']): ?><div class="t-faint t-small mono"><?= h($r['key']) ?></div><?php endif; ?></td>
                    <td><?= $r['state'] === 'off' ? dot('off', $r['display']) : ($r['state'] === 'on' ? dot('ok', $r['display']) : '<span class="cf-val">' . h($r['display']) . '</span>') ?></td>
                </tr>
            <?php endforeach; ?>
            </tbody>
        </table>
        </div>
    </section>
<?php }

function cf_action_tag(string $action): string
{
    $tone = ['danger' => 'tag-danger', 'warning' => 'tag-warning', 'success' => 'tag-ok', 'primary' => 'tag-accent'][cf_action_class($action)] ?? '';
    return '<span class="tag ' . $tone . '">' . h(ucfirst(str_replace('_', ' ', $action))) . '</span>';
}

function cf_rules_tables(array $groups, array $names): void
{
    foreach ($groups as $g):
        $enabled = count(array_filter($g['rules'], fn($r) => !empty($r['enabled']))); ?>
    <section class="panel">
        <div class="panel-head">
            <h3 class="t-h2 m-0"><?= h($g['label']) ?></h3>
            <span class="t-faint t-small"><?= $enabled ?> of <?= count($g['rules']) ?> on<?= $g['last_updated'] ? ', changed ' . h(date('j M Y', strtotime($g['last_updated']))) : '' ?></span>
        </div>
        <?php if (!$g['rules']): ?>
            <div class="empty pt-0">No rules in this phase.</div>
        <?php else: ?>
        <div class="table-responsive">
        <table class="table align-middle">
            <tbody>
            <?php foreach ($g['rules'] as $r):
                $summary = cf_rule_summary($r, $names);
                $action = $r['action'] ?? '';
                $desc = ($r['description'] ?? '') !== '' ? $r['description'] : (($action === 'execute') ? ($names[$r['action_parameters']['id'] ?? ''] ?? 'Managed ruleset') : 'Untitled rule'); ?>
                <tr data-state="<?= !empty($r['enabled']) ? 'on' : 'off' ?>">
                    <td style="width: 140px"><?= cf_action_tag($action) ?></td>
                    <td>
                        <div class="<?= empty($r['enabled']) ? 't-faint' : '' ?>"><?= h($desc) ?><?= empty($r['enabled']) ? ' <span class="t-small">(off)</span>' : '' ?></div>
                        <?php if ($summary): ?><div class="t-muted t-small"><?= h($summary) ?></div><?php endif; ?>
                        <details>
                            <summary>Expression</summary>
                            <pre class="code mono"><?= h($r['expression'] ?? '') ?><?php
                                $params = array_intersect_key($r, array_flip(['action_parameters', 'ratelimit', 'logging']));
                                if ($params) echo "\n\n" . h(json_encode($params, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)); ?></pre>
                        </details>
                    </td>
                </tr>
            <?php endforeach; ?>
            </tbody>
        </table>
        </div>
        <?php endif; ?>
    </section>
<?php endforeach;
}

$sections = ['summary' => 'Summary', 'ssl' => 'SSL/TLS', 'waf' => 'WAF & security', 'rules' => 'Rules',
             'speed' => 'Speed', 'cache' => 'Cache', 'network' => 'Network'];
if (!empty($settings['other'])) $sections['other'] = 'Other';
$sections['standard'] = 'Standard';
$activePageRules = count(array_filter($pageRules, fn($p) => ($p['status'] ?? '') === 'active'));
$plan = trim(str_ireplace('Website', '', $cfd['plan'] ?? ''));
?>
<style>
    .cf-wrap.hide-off [data-state="off"] { display: none; }
    .cf-wrap .panel + .panel { margin-top: 20px; }
    .cf-bar { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 20px; }
    .cf-nav { display: flex; gap: 4px; flex-wrap: wrap; }
    .cf-nav .nav-link { border: 1px solid transparent; border-radius: 7px; padding: 5px 11px; color: var(--ink-2); font-size: 13.5px; background: none; }
    .cf-nav .nav-link:hover { background: var(--line-2); color: var(--ink); }
    .cf-nav .nav-link.active { background: var(--surface); border-color: var(--line); color: var(--ink); }
    .cf-nav .num { color: var(--ink-3); margin-left: 4px; }
    .cf-val { color: var(--ink); }
</style>

<?php if (!$full): ?>
    <p class="dot dot-info mb-3">This report is from an older collector. Re-run it to see certificates, WAF, rules and cache details.</p>
<?php endif; ?>

<div class="cf-wrap hide-off" id="cfWrap">
    <div class="cf-bar">
        <div class="nav cf-nav" role="tablist">
            <?php $first = true; foreach ($sections as $id => $label):
                $num = '';
                if ($id === 'standard' && $cf['score'] !== null) $num = $cf['score'] . '%';
                elseif (isset(CF_SECTIONS[$id])) { [$on, $rc] = $count($id); if ($id === 'rules') $rc += $activePageRules; $num = $id === 'rules' ? (string) $rc : (string) $on; } ?>
                <button class="nav-link <?= $first ? 'active' : '' ?>" data-bs-toggle="pill" data-bs-target="#cf-<?= $id ?>" type="button"><?= h($label) ?><?php if ($num !== ''): ?><span class="num"><?= h($num) ?></span><?php endif; ?></button>
            <?php $first = false; endforeach; ?>
        </div>
        <div class="form-check form-switch m-0 t-small">
            <input class="form-check-input" type="checkbox" id="cfShowOff">
            <label class="form-check-label t-muted" for="cfShowOff">Include disabled</label>
        </div>
    </div>

    <div class="tab-content">

    <!-- Summary -->
    <div class="tab-pane fade show active" id="cf-summary">
        <div class="grid-2">
            <section class="panel panel-pad">
                <h3 class="t-h2">Zone</h3>
                <dl class="kv">
                    <dt>Zone</dt><dd><?= h($cfd['zone_name'] ?? $s['domain']) ?></dd>
                    <dt>Plan</dt><dd><span class="tag <?= strcasecmp($plan, 'Free') === 0 ? '' : 'tag-accent' ?>"><?= h($plan ?: '—') ?></span></dd>
                    <dt>Status</dt><dd><?= !empty($cfd['paused']) ? dot('danger', 'Paused') : dot(($cfd['status'] ?? '') === 'active' ? 'ok' : 'warning', ucfirst($cfd['status'] ?? '—')) ?></dd>
                    <?php if (!empty($cfd['name_servers'])): ?><dt>Nameservers</dt><dd class="mono"><?= implode('<br>', array_map('h', $cfd['name_servers'])) ?></dd><?php endif; ?>
                    <dt>Zone ID</dt><dd class="mono t-small text-break"><?= h($cfd['zone_id'] ?? '—') ?></dd>
                </dl>
            </section>
            <section class="panel panel-pad">
                <h3 class="t-h2">At a glance</h3>
                <dl class="kv">
                    <?php
                    $st = $cfd['settings'] ?? [];
                    $glance = [
                        'SSL mode'       => isset($st['ssl']) ? ucfirst($st['ssl']) : null,
                        'Minimum TLS'    => $st['min_tls_version'] ?? null,
                        'Security level' => isset($st['security_level']) ? cf_setting_view('security_level', $st['security_level'])[0] : null,
                        'Bot Fight Mode' => isset($secx['bot_management']['fight_mode']) ? ($secx['bot_management']['fight_mode'] ? 'On' : 'Off') : null,
                        'Cache level'    => isset($st['cache_level']) ? ucfirst($st['cache_level']) : null,
                        'Active rules'   => $full ? (string) cf_rule_counts($s)['enabled'] : null,
                        'Standard'       => $cf['score'] !== null ? $cf['score'] . '% (' . $cf['passed'] . ' of ' . $cf['evaluated'] . ')' : null,
                    ];
                    foreach ($glance as $k => $v): if ($v === null) continue; ?>
                        <dt><?= h($k) ?></dt><dd><?= h($v) ?></dd>
                    <?php endforeach; ?>
                </dl>
            </section>
        </div>
        <?php if ($cf['failed_checks']): ?>
        <section class="panel" style="margin-top: 20px">
            <div class="panel-head"><h3 class="t-h2 m-0">Off standard</h3></div>
            <ul class="issues">
                <?php foreach ($cf['failed_checks'] as $c): ?>
                    <li><?= dot($c['severity'] === 'high' ? 'danger' : ($c['severity'] === 'medium' ? 'warning' : 'off'), $c['label']) ?><span class="t-muted">Is <span class="mono"><?= h($c['actual']) ?></span>, should be <span class="mono"><?= h($c['expect']) ?></span></span></li>
                <?php endforeach; ?>
            </ul>
        </section>
        <?php endif; ?>
        <?php if (!empty($cfd['fetch_errors'])): ?>
            <p class="t-muted t-small mt-3"><?= plural(count($cfd['fetch_errors']), 'Cloudflare call') ?> failed, so some sections may be incomplete. Details are in the Collector log tab.</p>
        <?php endif; ?>
    </div>

    <!-- SSL/TLS -->
    <div class="tab-pane fade" id="cf-ssl">
        <?php cf_settings_table(array_merge($settings['ssl'] ?? [], $extra['ssl']), 'Settings'); ?>
        <?php
        $packs = array_values(array_filter($sslx['certificate_packs'] ?? [], fn($cp) => ($cp['status'] ?? '') !== 'deleted'));
        if ($packs): ?>
        <section class="panel">
            <div class="panel-head"><h3 class="t-h2 m-0">Edge certificates</h3></div>
            <div class="table-responsive">
            <table class="table align-middle">
                <thead><tr><th>Hosts</th><th>Type</th><th>Issuer</th><th>Status</th><th>Expires</th></tr></thead>
                <tbody>
                <?php foreach ($packs as $cp):
                    $exp = !empty($cp['expires_on']) ? strtotime($cp['expires_on']) : null;
                    $days = $exp ? (int) floor(($exp - time()) / 86400) : null;
                    $st = $cp['status'] ?? ''; ?>
                    <tr>
                        <td class="mono t-small"><?= implode('<br>', array_map('h', $cp['hosts'] ?? [])) ?></td>
                        <td><?= h(ucfirst($cp['type'] ?? '')) ?></td>
                        <td><?= h(['lets_encrypt' => "Let's Encrypt", 'google' => 'Google Trust Services', 'ssl_com' => 'SSL.com', 'digicert' => 'DigiCert', 'sectigo' => 'Sectigo'][$cp['certificate_authority'] ?? ''] ?? ucfirst($cp['certificate_authority'] ?? '—')) ?></td>
                        <td><?= $st === 'active' ? dot('ok', 'Active') : ($st === 'backup_issued' ? dot('off', 'Backup') : dot('warning', ucfirst(str_replace('_', ' ', $st)))) ?></td>
                        <td style="<?= $st === 'active' && $days !== null && $days < 14 ? 'color: var(--danger)' : '' ?>"><?= $exp ? h(date('j M Y', $exp)) . ' <span class="t-faint t-small">in ' . $days . 'd</span>' : '—' ?></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
            </div>
        </section>
        <?php endif; ?>
    </div>

    <!-- WAF -->
    <div class="tab-pane fade" id="cf-waf">
        <?php cf_settings_table($settings['waf'] ?? [], 'Security settings'); ?>
        <?php cf_settings_table($extra['waf'], 'Bots and credentials'); ?>
        <?php cf_rules_tables($rulesets['waf'] ?? [], $names); ?>
        <?php if ($full && empty($rulesets['waf'])): ?><p class="t-muted mt-3">No WAF custom, managed or rate limiting rules on this zone.</p><?php endif; ?>
        <?php if ($accessRules): ?>
        <section class="panel">
            <div class="panel-head"><h3 class="t-h2 m-0">IP access rules</h3></div>
            <div class="table-responsive">
            <table class="table align-middle">
                <thead><tr><th>Action</th><th>Applies to</th><th>Scope</th><th>Note</th></tr></thead>
                <tbody>
                <?php foreach ($accessRules as $ar): $mode = ($ar['mode'] ?? '') === 'whitelist' ? 'allow' : ($ar['mode'] ?? ''); ?>
                    <tr>
                        <td style="width: 140px"><?= cf_action_tag($mode) ?></td>
                        <td><span class="t-muted"><?= h(humanize_key($ar['target'] ?? '')) ?></span> <span class="mono"><?= h($ar['value'] ?? '') ?></span></td>
                        <td class="t-muted"><?= h(ucfirst($ar['scope'] ?? '')) ?></td>
                        <td class="t-muted"><?= h($ar['notes'] ?? '') ?></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
            </div>
        </section>
        <?php endif; ?>
        <?php foreach (['zone_lockdowns' => 'Zone lockdown rules (legacy)', 'ua_rules' => 'User agent blocking rules (legacy)'] as $k => $label):
            if (empty($secx[$k])) continue; ?>
            <section class="panel panel-pad">
                <h3 class="t-h2"><?= h($label) ?></h3>
                <ul class="mb-0 t-small"><?php foreach ($secx[$k] as $l): ?><li data-state="<?= !empty($l['paused']) ? 'off' : 'on' ?>"><?= h($l['description'] ?? '') ?> <span class="mono t-faint"><?= h(json_encode(array_diff_key($l, ['description' => 1]), JSON_UNESCAPED_SLASHES)) ?></span></li><?php endforeach; ?></ul>
            </section>
        <?php endforeach; ?>
    </div>

    <!-- Rules -->
    <div class="tab-pane fade" id="cf-rules">
        <?php cf_rules_tables($rulesets['rules'] ?? [], $names); ?>
        <?php if ($pageRules): ?>
        <section class="panel">
            <div class="panel-head"><h3 class="t-h2 m-0">Page rules (legacy)</h3><span class="t-faint t-small"><?= $activePageRules ?> of <?= count($pageRules) ?> on</span></div>
            <div class="table-responsive">
            <table class="table align-middle">
                <tbody>
                <?php foreach ($pageRules as $pr): ?>
                    <tr data-state="<?= ($pr['status'] ?? '') === 'active' ? 'on' : 'off' ?>">
                        <td class="mono t-small text-break" style="width: 42%"><?= h($pr['target'] ?? '') ?></td>
                        <td class="t-small"><?= h(implode(', ', array_map(fn($a) => humanize_key($a['id']) . ($a['value'] !== null ? ': ' . (is_array($a['value']) ? json_encode($a['value'], JSON_UNESCAPED_SLASHES) : $a['value']) : ''), $pr['actions'] ?? []))) ?></td>
                    </tr>
                <?php endforeach; ?>
                </tbody>
            </table>
            </div>
        </section>
        <?php endif; ?>
        <?php if ($full && empty($rulesets['rules']) && !$pageRules): ?><p class="t-muted">No redirect, transform, origin, configuration or page rules on this zone.</p><?php endif; ?>
    </div>

    <!-- Speed -->
    <div class="tab-pane fade" id="cf-speed">
        <?php cf_settings_table(array_merge($settings['speed'] ?? [], $extra['speed']), 'Settings'); ?>
    </div>

    <!-- Cache -->
    <div class="tab-pane fade" id="cf-cache">
        <?php cf_settings_table(array_merge($settings['cache'] ?? [], $extra['cache']), 'Settings'); ?>
        <?php cf_rules_tables($rulesets['cache'] ?? [], $names); ?>
        <?php if ($full && empty($rulesets['cache'])): ?><p class="t-muted mt-3">No cache rules on this zone.</p><?php endif; ?>
    </div>

    <!-- Network -->
    <div class="tab-pane fade" id="cf-network">
        <?php cf_settings_table($settings['network'] ?? [], 'Settings'); ?>
    </div>

    <?php if (!empty($settings['other'])): ?>
    <div class="tab-pane fade" id="cf-other">
        <p class="t-muted t-small">Settings Cloudflare returned that aren't grouped yet.</p>
        <?php cf_settings_table($settings['other'], 'Settings'); ?>
    </div>
    <?php endif; ?>

    <!-- Standard -->
    <div class="tab-pane fade" id="cf-standard">
        <p class="t-muted"><?= $cf['passed'] ?> of <?= $cf['evaluated'] ?> settings match the standard set in <span class="mono">config.php</span>.</p>
        <section class="panel">
            <div class="table-responsive">
                <table class="table align-middle">
                    <thead><tr><th>Setting</th><th>Importance</th><th>Should be</th><th>Is</th><th>Result</th></tr></thead>
                    <tbody>
                    <?php
                    $checks = $cf['checks'];
                    $ord = ['fail' => 0, 'pass' => 1, 'na' => 2, 'missing' => 3];
                    usort($checks, fn($a, $b) => $ord[$a['state']] <=> $ord[$b['state']]);
                    foreach ($checks as $c): ?>
                        <tr>
                            <td><?= h($c['label']) ?><div class="t-faint t-small mono"><?= h($c['key']) ?></div></td>
                            <td class="t-muted"><?= h(ucfirst($c['severity'])) ?></td>
                            <td class="mono"><?= h($c['expect']) ?></td>
                            <td class="mono"><?= $c['actual'] === null ? '<span class="t-faint">—</span>' : h($c['actual']) ?></td>
                            <td>
                                <?php if ($c['state'] === 'pass'): ?><?= dot('ok', 'Matches') ?>
                                <?php elseif ($c['state'] === 'fail'): ?><?= dot($c['severity'] === 'high' ? 'danger' : 'warning', 'Off standard') ?>
                                <?php elseif ($c['state'] === 'na'): ?><span class="t-faint"><?= h($c['note'] ?? 'Not applicable') ?></span>
                                <?php else: ?><span class="t-faint">Not collected</span><?php endif; ?>
                            </td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </section>
    </div>

    </div>
</div>
<script>
document.getElementById('cfShowOff').addEventListener('change', e => document.getElementById('cfWrap').classList.toggle('hide-off', !e.target.checked));
</script>
