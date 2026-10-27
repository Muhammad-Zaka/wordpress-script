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

function cf_settings_table(array $rows, string $title = 'Settings'): void
{
    if (!$rows) return; ?>
    <div class="card rounded-4 overflow-hidden mb-4">
        <div class="px-4 pt-3 pb-2 section-title"><?= h($title) ?></div>
        <div class="table-responsive">
        <table class="table table-sm align-middle mb-0 cf-table">
            <tbody>
            <?php foreach ($rows as $r): ?>
                <tr data-state="<?= h($r['state']) ?>">
                    <td class="ps-4" style="width: 45%">
                        <div class="fw-semibold"><?= h($r['label']) ?></div>
                        <?php if ($r['key']): ?><div class="muted-xs mono"><?= h($r['key']) ?></div><?php endif; ?>
                    </td>
                    <td class="mono text-break"><?= h($r['display']) ?></td>
                    <td class="pe-4 text-end" style="width: 80px">
                        <?php if ($r['state'] === 'on'): ?><span class="badge rounded-pill bg-success-subtle text-success">On</span>
                        <?php elseif ($r['state'] === 'off'): ?><span class="badge rounded-pill bg-light text-muted border">Off</span>
                        <?php else: ?><span class="badge rounded-pill bg-primary-subtle text-primary">Set</span><?php endif; ?>
                    </td>
                </tr>
            <?php endforeach; ?>
            </tbody>
        </table>
        </div>
    </div>
<?php }

function cf_rules_tables(array $groups, array $names): void
{
    foreach ($groups as $g):
        $enabled = count(array_filter($g['rules'], fn($r) => !empty($r['enabled']))); ?>
    <div class="card rounded-4 overflow-hidden mb-4">
        <div class="px-4 pt-3 pb-2 d-flex justify-content-between align-items-center">
            <div class="section-title"><?= h($g['label']) ?></div>
            <div class="muted-xs"><?= $enabled ?> of <?= count($g['rules']) ?> enabled<?= $g['last_updated'] ? ' · updated ' . h(date('Y-m-d', strtotime($g['last_updated']))) : '' ?></div>
        </div>
        <?php if (!$g['rules']): ?>
            <div class="px-4 pb-3 text-muted small">No rules.</div>
        <?php else: ?>
        <div class="table-responsive">
        <table class="table table-sm align-middle mb-0 cf-table">
            <thead class="text-uppercase"><tr><th class="ps-4" style="width:40px">#</th><th>Rule</th><th>Action</th><th class="pe-4 text-end">Status</th></tr></thead>
            <tbody>
            <?php foreach ($g['rules'] as $i => $r):
                $summary = cf_rule_summary($r, $names);
                $action = $r['action'] ?? '';
                $desc = ($r['description'] ?? '') !== '' ? $r['description'] : (($action === 'execute') ? ($names[$r['action_parameters']['id'] ?? ''] ?? 'Managed ruleset') : '(no description)'); ?>
                <tr data-state="<?= !empty($r['enabled']) ? 'on' : 'off' ?>">
                    <td class="ps-4 text-muted"><?= $i + 1 ?></td>
                    <td>
                        <div class="fw-semibold"><?= h($desc) ?></div>
                        <?php if ($summary): ?><div class="small text-body-secondary"><?= h($summary) ?></div><?php endif; ?>
                        <details class="mt-1">
                            <summary class="muted-xs">Expression &amp; parameters</summary>
                            <pre class="mono small bg-light border rounded p-2 mt-1 mb-0" style="white-space: pre-wrap"><?= h($r['expression'] ?? '') ?><?php
                                $params = array_intersect_key($r, array_flip(['action_parameters', 'ratelimit', 'logging']));
                                if ($params) echo "\n\n" . h(json_encode($params, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)); ?></pre>
                        </details>
                    </td>
                    <td><span class="badge rounded-pill bg-<?= cf_action_class($action) ?>-subtle text-<?= cf_action_class($action) ?>-emphasis"><?= h(str_replace('_', ' ', $action)) ?></span></td>
                    <td class="pe-4 text-end"><?= !empty($r['enabled']) ? '<span class="badge rounded-pill bg-success-subtle text-success">Enabled</span>' : '<span class="badge rounded-pill bg-light text-muted border">Disabled</span>' ?></td>
                </tr>
            <?php endforeach; ?>
            </tbody>
        </table>
        </div>
        <?php endif; ?>
    </div>
<?php endforeach;
}

function cf_empty_note(string $text): void
{
    echo '<div class="alert alert-light border small">' . h($text) . '</div>';
}

$sections = ['summary' => ['Summary', 'grid'], 'ssl' => CF_SECTIONS['ssl'], 'waf' => CF_SECTIONS['waf'], 'rules' => CF_SECTIONS['rules'],
             'speed' => CF_SECTIONS['speed'], 'cache' => CF_SECTIONS['cache'], 'network' => CF_SECTIONS['network']];
if (!empty($settings['other'])) $sections['other'] = CF_SECTIONS['other'];
$sections['standard'] = ['Standard', 'clipboard-check'];
?>
<style>
    .cf-wrap.hide-off [data-state="off"] { display: none; }
    .cf-nav .nav-link { display: flex; justify-content: space-between; align-items: center; text-align: left; }
    .cf-table td { padding-top: .6rem; padding-bottom: .6rem; }
</style>

<?php if (!$full): ?>
<div class="alert alert-info small"><i class="bi bi-info-circle me-1"></i>
    This report was collected by an older script version. Re-run the collector (v2.1+) to see certificates, WAF, rules and cache details.</div>
<?php endif; ?>

<div class="row g-4 cf-wrap hide-off" id="cfWrap">
    <div class="col-lg-3">
        <div class="card rounded-4 p-3 position-sticky" style="top: 1rem">
            <div class="nav flex-column nav-pills cf-nav gap-1" role="tablist">
                <?php $first = true; foreach ($sections as $id => [$label, $icon]):
                    $badge = '';
                    if ($id === 'standard' && $cf['score'] !== null) $badge = $cf['score'] . '%';
                    elseif (isset(CF_SECTIONS[$id])) {
                        [$on, $rc] = $count($id);
                        if ($id === 'rules') $rc += count(array_filter($pageRules, fn($p) => ($p['status'] ?? '') === 'active'));
                        $hasSettings = !empty($settings[$id]) || !empty($extra[$id]);
                        $badge = implode(' · ', array_filter([$hasSettings ? "$on on" : '', $rc ? "$rc rules" : '']));
                    }
                ?>
                    <button class="nav-link <?= $first ? 'active' : '' ?>" data-bs-toggle="pill" data-bs-target="#cf-<?= $id ?>" type="button">
                        <span><i class="bi bi-<?= $icon ?> me-2"></i><?= h($label) ?></span>
                        <?php if ($badge !== ''): ?><span class="muted-xs"><?= h($badge) ?></span><?php endif; ?>
                    </button>
                <?php $first = false; endforeach; ?>
            </div>
            <hr>
            <div class="form-check form-switch small">
                <input class="form-check-input" type="checkbox" id="cfShowOff">
                <label class="form-check-label" for="cfShowOff">Show disabled settings &amp; rules</label>
            </div>
        </div>
    </div>

    <div class="col-lg-9">
        <div class="tab-content">

        <!-- Summary -->
        <div class="tab-pane fade show active" id="cf-summary">
            <div class="row g-3 mb-4">
                <div class="col-md-6">
                    <div class="card rounded-4 p-4 h-100">
                        <div class="section-title mb-3">Zone</div>
                        <dl class="row kv mb-0">
                            <dt class="col-5">Zone</dt><dd class="col-7"><?= h($cfd['zone_name'] ?? $s['domain']) ?></dd>
                            <dt class="col-5">Plan</dt><dd class="col-7"><?= h($cfd['plan'] ?? '—') ?></dd>
                            <dt class="col-5">Status</dt><dd class="col-7"><?= h($cfd['status'] ?? '—') ?><?= !empty($cfd['paused']) ? ' <span class="badge bg-danger">paused</span>' : '' ?></dd>
                            <dt class="col-5">Zone ID</dt><dd class="col-7 mono text-break small"><?= h($cfd['zone_id'] ?? '—') ?></dd>
                            <?php if (!empty($cfd['name_servers'])): ?><dt class="col-5">Nameservers</dt><dd class="col-7 mono small"><?= implode('<br>', array_map('h', $cfd['name_servers'])) ?></dd><?php endif; ?>
                        </dl>
                    </div>
                </div>
                <div class="col-md-6">
                    <div class="card rounded-4 p-4 h-100">
                        <div class="section-title mb-3">Key settings</div>
                        <dl class="row kv mb-0">
                            <?php
                            $st = $cfd['settings'] ?? [];
                            $key = [
                                'SSL mode'       => isset($st['ssl']) ? ucfirst($st['ssl']) : null,
                                'Min TLS'        => $st['min_tls_version'] ?? null,
                                'Security level' => isset($st['security_level']) ? cf_setting_view('security_level', $st['security_level'])[0] : null,
                                'Bot Fight Mode' => isset($secx['bot_management']['fight_mode']) ? ($secx['bot_management']['fight_mode'] ? 'On' : 'Off') : null,
                                'Cache level'    => isset($st['cache_level']) ? ucfirst($st['cache_level']) : null,
                                'APO'            => isset($st['automatic_platform_optimization']) ? cf_setting_view('automatic_platform_optimization', $st['automatic_platform_optimization'])[0] : null,
                            ];
                            foreach ($key as $k => $v): if ($v === null) continue; ?>
                                <dt class="col-5"><?= h($k) ?></dt><dd class="col-7"><?= h($v) ?></dd>
                            <?php endforeach; ?>
                        </dl>
                    </div>
                </div>
            </div>
            <div class="row g-3 mb-4">
                <?php foreach (['ssl', 'waf', 'rules', 'speed', 'cache', 'network'] as $sec):
                    [$on, $rc] = $count($sec);
                    if ($sec === 'rules') $rc += count(array_filter($pageRules, fn($p) => ($p['status'] ?? '') === 'active')); ?>
                <div class="col-6 col-md-4">
                    <div class="card rounded-4 p-3 h-100" role="button" onclick="document.querySelector('[data-bs-target=&quot;#cf-<?= $sec ?>&quot;]').click()">
                        <div class="small fw-semibold mb-2"><i class="bi bi-<?= CF_SECTIONS[$sec][1] ?> me-1"></i><?= h(CF_SECTIONS[$sec][0]) ?></div>
                        <div class="d-flex gap-3">
                            <?php if (!empty($settings[$sec]) || !empty($extra[$sec])): ?>
                            <div><div class="fs-4 fw-bold"><?= $on ?></div><div class="muted-xs">enabled / set</div></div>
                            <?php endif; ?>
                            <?php if ($rc || in_array($sec, ['waf', 'rules', 'cache'], true)): ?>
                            <div><div class="fs-4 fw-bold"><?= $rc ?></div><div class="muted-xs">active rules</div></div>
                            <?php endif; ?>
                        </div>
                    </div>
                </div>
                <?php endforeach; ?>
            </div>
            <?php if (!empty($cfd['fetch_errors'])): ?>
            <div class="card rounded-4 p-4">
                <div class="section-title mb-2">Not collected</div>
                <div class="muted-xs mb-2">These API calls failed — usually a missing API token permission or a feature not on this plan.</div>
                <ul class="mb-0 mono small"><?php foreach ($cfd['fetch_errors'] as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul>
            </div>
            <?php endif; ?>
        </div>

        <!-- SSL/TLS -->
        <div class="tab-pane fade" id="cf-ssl">
            <?php cf_settings_table(array_merge($settings['ssl'] ?? [], $extra['ssl'])); ?>
            <?php if (!empty($sslx['certificate_packs'])): ?>
            <div class="card rounded-4 overflow-hidden mb-4">
                <div class="px-4 pt-3 pb-2 section-title">Edge certificates</div>
                <div class="table-responsive">
                <table class="table table-sm align-middle mb-0">
                    <thead class="text-uppercase"><tr><th class="ps-4">Hosts</th><th>Type</th><th>CA</th><th>Status</th><th class="pe-4">Expires</th></tr></thead>
                    <tbody>
                    <?php foreach ($sslx['certificate_packs'] as $cp):
                        $exp = !empty($cp['expires_on']) ? strtotime($cp['expires_on']) : null;
                        $days = $exp ? (int) floor(($exp - time()) / 86400) : null; ?>
                        <tr>
                            <td class="ps-4 mono small"><?= implode('<br>', array_map('h', $cp['hosts'] ?? [])) ?></td>
                            <td><?= h(ucfirst($cp['type'] ?? '')) ?></td>
                            <td><?= h($cp['certificate_authority'] ?? '—') ?></td>
                            <td><span class="badge rounded-pill <?= ($cp['status'] ?? '') === 'active' ? 'bg-success-subtle text-success' : 'bg-warning-subtle text-warning-emphasis' ?>"><?= h($cp['status'] ?? '') ?></span></td>
                            <td class="pe-4 <?= $days !== null && $days < 14 ? 'text-danger fw-semibold' : '' ?>"><?= $exp ? h(date('Y-m-d', $exp)) . ' <span class="muted-xs">(' . $days . 'd)</span>' : '—' ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
                </div>
            </div>
            <?php endif; ?>
        </div>

        <!-- WAF -->
        <div class="tab-pane fade" id="cf-waf">
            <?php cf_settings_table($settings['waf'] ?? [], 'Security settings'); ?>
            <?php cf_settings_table($extra['waf'], 'Bots & credentials'); ?>
            <?php cf_rules_tables($rulesets['waf'] ?? [], $names); ?>
            <?php if ($full && empty($rulesets['waf'])) cf_empty_note('No WAF custom, managed or rate limiting rules deployed on this zone.'); ?>
            <?php if ($accessRules): ?>
            <div class="card rounded-4 overflow-hidden mb-4">
                <div class="px-4 pt-3 pb-2 section-title">IP access rules</div>
                <div class="table-responsive">
                <table class="table table-sm align-middle mb-0">
                    <thead class="text-uppercase"><tr><th class="ps-4">Target</th><th>Value</th><th>Action</th><th>Scope</th><th class="pe-4">Notes</th></tr></thead>
                    <tbody>
                    <?php foreach ($accessRules as $ar): ?>
                        <tr>
                            <td class="ps-4"><?= h($ar['target'] ?? '') ?></td>
                            <td class="mono"><?= h($ar['value'] ?? '') ?></td>
                            <td><span class="badge rounded-pill bg-<?= cf_action_class($ar['mode'] === 'whitelist' ? 'allow' : ($ar['mode'] ?? '')) ?>-subtle text-<?= cf_action_class($ar['mode'] === 'whitelist' ? 'allow' : ($ar['mode'] ?? '')) ?>-emphasis"><?= h($ar['mode'] === 'whitelist' ? 'allow' : str_replace('_', ' ', $ar['mode'] ?? '')) ?></span></td>
                            <td class="small"><?= h($ar['scope'] ?? '') ?></td>
                            <td class="pe-4 small"><?= h($ar['notes'] ?? '') ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
                </div>
            </div>
            <?php endif; ?>
            <?php foreach (['zone_lockdowns' => 'Zone lockdown rules (legacy)', 'ua_rules' => 'User agent blocking rules (legacy)'] as $k => $label):
                if (empty($secx[$k])) continue; ?>
                <div class="card rounded-4 p-4 mb-4">
                    <div class="section-title mb-2"><?= h($label) ?></div>
                    <ul class="mb-0 small"><?php foreach ($secx[$k] as $l): ?><li data-state="<?= !empty($l['paused']) ? 'off' : 'on' ?>"><?= h($l['description'] ?? '') ?> <span class="mono muted-xs"><?= h(json_encode(array_diff_key($l, ['description' => 1]), JSON_UNESCAPED_SLASHES)) ?></span></li><?php endforeach; ?></ul>
                </div>
            <?php endforeach; ?>
        </div>

        <!-- Rules -->
        <div class="tab-pane fade" id="cf-rules">
            <?php cf_rules_tables($rulesets['rules'] ?? [], $names); ?>
            <?php if ($pageRules): ?>
            <div class="card rounded-4 overflow-hidden mb-4">
                <div class="px-4 pt-3 pb-2 section-title">Page rules (legacy)</div>
                <div class="table-responsive">
                <table class="table table-sm align-middle mb-0">
                    <thead class="text-uppercase"><tr><th class="ps-4" style="width:40px">#</th><th>URL</th><th>Settings</th><th class="pe-4 text-end">Status</th></tr></thead>
                    <tbody>
                    <?php foreach ($pageRules as $pr): ?>
                        <tr data-state="<?= ($pr['status'] ?? '') === 'active' ? 'on' : 'off' ?>">
                            <td class="ps-4 text-muted"><?= h($pr['priority'] ?? '') ?></td>
                            <td class="mono small text-break"><?= h($pr['target'] ?? '') ?></td>
                            <td class="small"><?php foreach ($pr['actions'] ?? [] as $a): ?><span class="badge bg-light text-dark border me-1 mb-1"><?= h(humanize_key($a['id'])) ?><?= $a['value'] !== null ? ': ' . h(is_array($a['value']) ? json_encode($a['value'], JSON_UNESCAPED_SLASHES) : $a['value']) : '' ?></span><?php endforeach; ?></td>
                            <td class="pe-4 text-end"><?= ($pr['status'] ?? '') === 'active' ? '<span class="badge rounded-pill bg-success-subtle text-success">Active</span>' : '<span class="badge rounded-pill bg-light text-muted border">' . h($pr['status'] ?? '') . '</span>' ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
                </div>
            </div>
            <?php endif; ?>
            <?php if ($full && empty($rulesets['rules']) && !$pageRules) cf_empty_note('No redirect, transform, origin, configuration or page rules on this zone.'); ?>
        </div>

        <!-- Speed -->
        <div class="tab-pane fade" id="cf-speed">
            <?php cf_settings_table(array_merge($settings['speed'] ?? [], $extra['speed'])); ?>
        </div>

        <!-- Cache -->
        <div class="tab-pane fade" id="cf-cache">
            <?php cf_settings_table(array_merge($settings['cache'] ?? [], $extra['cache'])); ?>
            <?php cf_rules_tables($rulesets['cache'] ?? [], $names); ?>
            <?php if ($full && empty($rulesets['cache'])) cf_empty_note('No cache rules on this zone.'); ?>
        </div>

        <!-- Network -->
        <div class="tab-pane fade" id="cf-network">
            <?php cf_settings_table($settings['network'] ?? []); ?>
        </div>

        <?php if (!empty($settings['other'])): ?>
        <div class="tab-pane fade" id="cf-other">
            <div class="muted-xs mb-2">Settings returned by Cloudflare that aren't categorised yet.</div>
            <?php cf_settings_table($settings['other']); ?>
        </div>
        <?php endif; ?>

        <!-- Standard -->
        <div class="tab-pane fade" id="cf-standard">
            <div class="card rounded-4 p-4 mb-4 d-flex flex-row align-items-center gap-4">
                <div class="display-6 fw-bold"><?= $cf['score'] ?? '—' ?><span class="fs-5 text-muted">%</span></div>
                <div class="muted-xs"><?= $cf['passed'] ?> of <?= $cf['evaluated'] ?> collected settings match the standard defined in <span class="mono">config.php</span></div>
            </div>
            <div class="card rounded-4 overflow-hidden">
                <div class="table-responsive">
                    <table class="table align-middle mb-0">
                        <thead class="text-uppercase"><tr><th class="ps-4">Setting</th><th>Severity</th><th>Standard</th><th>Actual</th><th class="pe-4">Result</th></tr></thead>
                        <tbody>
                        <?php
                        $checks = $cf['checks'];
                        $order = ['fail' => 0, 'pass' => 1, 'missing' => 2];
                        usort($checks, fn($a, $b) => $order[$a['state']] <=> $order[$b['state']]);
                        $sevc = ['high' => 'danger', 'medium' => 'warning', 'low' => 'secondary'];
                        foreach ($checks as $c): ?>
                            <tr>
                                <td class="ps-4"><div class="fw-semibold"><?= h($c['label']) ?></div><div class="muted-xs mono"><?= h($c['key']) ?></div></td>
                                <td><span class="badge rounded-pill bg-<?= $sevc[$c['severity']] ?>-subtle text-<?= $sevc[$c['severity']] ?>-emphasis"><?= h($c['severity']) ?></span></td>
                                <td class="mono"><?= h($c['expect']) ?></td>
                                <td class="mono"><?= $c['actual'] === null ? '<span class="text-muted">not collected</span>' : h($c['actual']) ?></td>
                                <td class="pe-4">
                                    <?php if ($c['state'] === 'pass'): ?><i class="bi bi-check-circle-fill text-success"></i>
                                    <?php elseif ($c['state'] === 'fail'): ?><i class="bi bi-x-circle-fill text-danger"></i>
                                    <?php else: ?><i class="bi bi-dash-circle text-muted"></i><?php endif; ?>
                                </td>
                            </tr>
                        <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>

        </div>
    </div>
</div>
<script>
document.getElementById('cfShowOff').addEventListener('change', e => document.getElementById('cfWrap').classList.toggle('hide-off', !e.target.checked));
</script>
