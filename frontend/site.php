<?php
require __DIR__ . '/lib.php';
require __DIR__ . '/layout.php';

$slug = (string) ($_GET['site'] ?? '');
$file = rtrim($config['metrics_dir'], '/') . '/' . $slug . '.json';
$s = (valid_slug($slug) && is_file($file)) ? load_site_file($file, $config) : null;

if (!$s) {
    http_response_code(404);
    page_header('Site not found');
    echo '<a href="./" class="text-decoration-none small"><i class="bi bi-arrow-left"></i> All sites</a>';
    echo '<div class="alert alert-warning mt-3">No report found for <code>' . h($slug) . '</code>.</div>';
    page_footer();
    exit;
}

$wp  = $s['wordpress'];
$env = $s['environment'] ?? [];
$cfd = $s['cloudflare'] ?? [];
$cf  = $s['_cf'];
$wf  = $s['_wf'];

function yesno($v, bool $goodWhenTrue = true): string
{
    if ($v === null) return '<span class="text-muted">—</span>';
    $good = $goodWhenTrue ? $v : !$v;
    return '<span class="badge rounded-pill ' . ($good ? 'bg-success-subtle text-success' : 'bg-warning-subtle text-warning-emphasis') . '">' . ($v ? 'Yes' : 'No') . '</span>';
}

function status_badge(string $status): string
{
    $map = ['active' => 'success', 'active-network' => 'success', 'parent' => 'info', 'inactive' => 'secondary', 'must-use' => 'primary', 'dropin' => 'primary'];
    $c = $map[$status] ?? 'secondary';
    return '<span class="badge rounded-pill bg-' . $c . '-subtle text-' . $c . '-emphasis">' . h($status) . '</span>';
}

page_header($s['domain'] . ' · WordPress Fleet');
?>
<a href="./" class="text-decoration-none small"><i class="bi bi-arrow-left"></i> All sites</a>

<header class="my-3 d-flex flex-column flex-md-row justify-content-between align-items-md-center gap-3">
    <div>
        <h1 class="h3 fw-bold mb-1"><?= h($s['domain']) ?></h1>
        <div class="muted-xs">
            vhost <span class="mono"><?= h($s['site']) ?></span>
            <?php if (!empty($env['home'])): ?> · <a href="<?= h($env['home']) ?>" target="_blank" rel="noopener"><?= h($env['home']) ?> <i class="bi bi-box-arrow-up-right"></i></a><?php endif; ?>
            · collected <span class="<?= $s['_stale'] ? 'text-danger fw-semibold' : '' ?>"><?= h($s['_age']) ?></span> (<?= h(date('Y-m-d H:i', $s['_ts'])) ?>)
            <?php if (!empty($s['script_version'])): ?> · script v<?= h($s['script_version']) ?><?php endif; ?>
        </div>
    </div>
    <?php if (!empty($env['home'])): ?>
    <a href="<?= h(rtrim($env['home'], '/')) ?>/wp-admin/" target="_blank" rel="noopener" class="btn btn-sm btn-dark rounded-pill px-3"><i class="bi bi-wordpress me-1"></i>WP Admin</a>
    <?php endif; ?>
</header>

<!-- Health -->
<div class="card rounded-4 p-4 mb-4">
    <div class="section-title mb-3">Health checks</div>
    <?php if (!$s['_health']): ?>
        <div class="text-success"><i class="bi bi-check-circle-fill me-1"></i>No issues detected.</div>
    <?php else: ?>
        <div class="row g-2">
        <?php foreach ($s['_health'] as $c): $b = level_badge($c['level']); ?>
            <div class="col-md-6 col-xl-4">
                <div class="border rounded-3 p-2 px-3 h-100 border-<?= $b ?>-subtle bg-<?= $b ?>-subtle bg-opacity-25">
                    <div class="fw-semibold small text-<?= $b ?>-emphasis">
                        <i class="bi bi-<?= $c['level'] === 'danger' ? 'x-octagon-fill' : ($c['level'] === 'warning' ? 'exclamation-triangle-fill' : 'info-circle') ?> me-1"></i><?= h($c['label']) ?>
                    </div>
                    <?php if ($c['detail']): ?><div class="muted-xs"><?= h($c['detail']) ?></div><?php endif; ?>
                </div>
            </div>
        <?php endforeach; ?>
        </div>
    <?php endif; ?>
</div>

<ul class="nav nav-pills gap-2 mb-3" role="tablist">
    <li class="nav-item"><button class="nav-link active" data-bs-toggle="pill" data-bs-target="#t-overview">Overview</button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="pill" data-bs-target="#t-plugins">Plugins <span class="badge bg-secondary-subtle text-secondary-emphasis"><?= $s['plugins']['total'] ?></span></button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="pill" data-bs-target="#t-themes">Themes <span class="badge bg-secondary-subtle text-secondary-emphasis"><?= $s['themes']['total'] ?></span></button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="pill" data-bs-target="#t-cf">Cloudflare <?php if ($cf['score'] !== null): ?><span class="badge bg-secondary-subtle text-secondary-emphasis"><?= $cf['score'] ?>%</span><?php endif; ?></button></li>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="pill" data-bs-target="#t-wf">Wordfence <?php if ($wf['issues']): ?><span class="badge bg-danger"><?= $wf['issues'] ?></span><?php endif; ?></button></li>
    <?php if ($s['errors']): ?>
    <li class="nav-item"><button class="nav-link" data-bs-toggle="pill" data-bs-target="#t-errors">Collector warnings <span class="badge bg-warning text-dark"><?= count($s['errors']) ?></span></button></li>
    <?php endif; ?>
</ul>

<div class="tab-content">
    <!-- Overview -->
    <div class="tab-pane fade show active" id="t-overview">
        <div class="row g-4">
            <div class="col-lg-6">
                <div class="card rounded-4 p-4 h-100">
                    <div class="section-title mb-3">WordPress core</div>
                    <dl class="row kv mb-0">
                        <dt class="col-5">Version</dt><dd class="col-7 mono"><?= h($wp['version'] ?: '?') ?>
                            <?php if ($wp['update_available'] ?? false): ?><span class="badge bg-warning-subtle text-warning-emphasis rounded-pill ms-1">→ <?= h($wp['updates'][0]['version'] ?? '') ?></span><?php endif; ?></dd>
                        <dt class="col-5">Update check</dt><dd class="col-7"><?= h($wp['update_check_status'] ?? '—') ?></dd>
                        <dt class="col-5">Core checksums</dt><dd class="col-7"><?php $ck = $wp['checksums'] ?? null; echo $ck === null ? '<span class="text-muted">not collected</span>' : ($ck === 'ok' ? '<span class="badge bg-success-subtle text-success rounded-pill">Passed</span>' : '<span class="badge bg-danger rounded-pill">' . h(ucfirst($ck)) . '</span>'); ?></dd>
                        <dt class="col-5">Auto-update core</dt><dd class="col-7 mono"><?= h(fmt_value($env['auto_update_core'] ?? null)) ?></dd>
                        <dt class="col-5">Multisite</dt><dd class="col-7"><?= array_key_exists('is_multisite', $env) ? ($env['is_multisite'] ? 'Yes' : 'No') : '—' ?></dd>
                        <dt class="col-5">Search engines</dt><dd class="col-7"><?= array_key_exists('blog_public', $env) ? ($env['blog_public'] ? '<span class="badge bg-success-subtle text-success rounded-pill">Allowed</span>' : '<span class="badge bg-danger rounded-pill">Discouraged</span>') : '—' ?></dd>
                        <dt class="col-5">Drop-ins</dt><dd class="col-7"><?php foreach ($s['dropins'] ?? [] as $d): ?><span class="badge bg-light text-dark border mono me-1"><?= h($d['name']) ?></span><?php endforeach; ?><?= empty($s['dropins']) ? '—' : '' ?></dd>
                    </dl>
                </div>
            </div>
            <div class="col-lg-6">
                <div class="card rounded-4 p-4 h-100">
                    <div class="section-title mb-3">Environment</div>
                    <?php if (!$env): ?>
                        <div class="text-muted small">Not collected — re-run the updated collector script to populate this.</div>
                    <?php else: ?>
                    <dl class="row kv mb-0">
                        <dt class="col-5">PHP</dt><dd class="col-7 mono"><?= h($env['php_version'] ?? '—') ?></dd>
                        <dt class="col-5">MySQL / MariaDB</dt><dd class="col-7 mono"><?= h($env['mysql_version'] ?? '—') ?></dd>
                        <dt class="col-5">Memory limit</dt><dd class="col-7 mono"><?= h($env['memory_limit'] ?? '—') ?></dd>
                        <dt class="col-5">WP_DEBUG</dt><dd class="col-7"><?= yesno($env['wp_debug'] ?? null, false) ?></dd>
                        <dt class="col-5">File editor disabled</dt><dd class="col-7"><?= yesno($env['disallow_file_edit'] ?? null) ?></dd>
                        <dt class="col-5">WP-Cron disabled</dt><dd class="col-7"><?= array_key_exists('disable_wp_cron', $env) ? ($env['disable_wp_cron'] ? 'Yes (system cron)' : 'No') : '—' ?></dd>
                        <dt class="col-5">Users / admins</dt><dd class="col-7"><?= h($env['users_total'] ?? '—') ?> / <?= h($env['admins'] ?? '—') ?></dd>
                        <dt class="col-5">Autoloaded options</dt><dd class="col-7"><?= h(human_bytes($env['autoload_bytes'] ?? null)) ?></dd>
                        <dt class="col-5">Disk (site / uploads)</dt><dd class="col-7"><?= h(human_bytes($env['disk_bytes'] ?? null)) ?> / <?= h(human_bytes($env['uploads_bytes'] ?? null)) ?></dd>
                    </dl>
                    <?php endif; ?>
                </div>
            </div>
        </div>
    </div>

    <!-- Plugins -->
    <div class="tab-pane fade" id="t-plugins">
        <div class="card rounded-4 overflow-hidden">
            <div class="table-responsive">
                <table class="table table-hover align-middle mb-0">
                    <thead class="text-uppercase"><tr><th class="ps-4">Plugin</th><th>Status</th><th>Version</th><th>Update</th><th class="pe-4">Auto-update</th></tr></thead>
                    <tbody>
                    <?php
                    $items = $s['plugins']['items'];
                    usort($items, fn($a, $b) => [($b['update'] ?? '') === 'available', $a['name']] <=> [($a['update'] ?? '') === 'available', $b['name']]);
                    foreach ($items as $p): ?>
                        <tr>
                            <td class="ps-4">
                                <div class="fw-semibold"><?= h($p['title'] ?? $p['name']) ?></div>
                                <?php if (!empty($p['title'])): ?><div class="muted-xs mono"><?= h($p['name']) ?></div><?php endif; ?>
                            </td>
                            <td><?= status_badge($p['status'] ?? '') ?></td>
                            <td class="mono"><?= h($p['version'] ?: '—') ?></td>
                            <td><?php if (($p['update'] ?? '') === 'available'): ?><span class="badge bg-warning-subtle text-warning-emphasis rounded-pill">→ <?= h($p['update_version']) ?></span><?php else: ?><span class="text-muted">—</span><?php endif; ?></td>
                            <td class="pe-4"><?= ($p['auto_update'] ?? 'off') === 'on' ? '<span class="badge bg-info-subtle text-info-emphasis rounded-pill">on</span>' : '<span class="text-muted small">off</span>' ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- Themes -->
    <div class="tab-pane fade" id="t-themes">
        <div class="card rounded-4 overflow-hidden">
            <div class="table-responsive">
                <table class="table align-middle mb-0">
                    <thead class="text-uppercase"><tr><th class="ps-4">Theme</th><th>Status</th><th>Version</th><th>Update</th><th class="pe-4">Auto-update</th></tr></thead>
                    <tbody>
                    <?php foreach ($s['themes']['items'] as $t): ?>
                        <tr>
                            <td class="ps-4"><div class="fw-semibold"><?= h($t['title'] ?? $t['name']) ?></div><?php if (!empty($t['title'])): ?><div class="muted-xs mono"><?= h($t['name']) ?></div><?php endif; ?></td>
                            <td><?= status_badge($t['status'] ?? '') ?></td>
                            <td class="mono"><?= h($t['version'] ?: '—') ?></td>
                            <td><?php if (($t['update'] ?? '') === 'available'): ?><span class="badge bg-warning-subtle text-warning-emphasis rounded-pill">→ <?= h($t['update_version']) ?></span><?php else: ?><span class="text-muted">—</span><?php endif; ?></td>
                            <td class="pe-4"><?= ($t['auto_update'] ?? 'off') === 'on' ? '<span class="badge bg-info-subtle text-info-emphasis rounded-pill">on</span>' : '<span class="text-muted small">off</span>' ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
            <?php if ($config['hidden_themes']): ?><div class="muted-xs px-4 py-2 border-top">Hidden by config: <?= h(implode(', ', $config['hidden_themes'])) ?></div><?php endif; ?>
        </div>
    </div>

    <!-- Cloudflare -->
    <div class="tab-pane fade" id="t-cf">
        <?php if (!$s['_has_cf']): ?>
            <div class="alert alert-light border">No active Cloudflare zone found for this site.</div>
        <?php else: ?>
        <div class="row g-4">
            <div class="col-lg-4">
                <div class="card rounded-4 p-4 h-100">
                    <div class="section-title mb-3">Zone</div>
                    <dl class="row kv mb-0">
                        <dt class="col-5">Zone</dt><dd class="col-7"><?= h($cfd['zone_name'] ?? $s['domain']) ?></dd>
                        <dt class="col-5">Plan</dt><dd class="col-7"><?= h($cfd['plan'] ?? '—') ?></dd>
                        <dt class="col-5">Status</dt><dd class="col-7"><?= h($cfd['status'] ?? '—') ?><?= !empty($cfd['paused']) ? ' <span class="badge bg-danger">paused</span>' : '' ?></dd>
                        <dt class="col-5">Zone ID</dt><dd class="col-7 mono text-break"><?= h($cfd['zone_id'] ?? '—') ?></dd>
                        <?php if (!empty($cfd['name_servers'])): ?><dt class="col-5">Nameservers</dt><dd class="col-7 mono small"><?= implode('<br>', array_map('h', $cfd['name_servers'])) ?></dd><?php endif; ?>
                    </dl>
                    <hr>
                    <div class="section-title mb-2">Compliance</div>
                    <div class="display-6 fw-bold"><?= $cf['score'] ?? '—' ?><span class="fs-5 text-muted">%</span></div>
                    <div class="muted-xs"><?= $cf['passed'] ?> of <?= $cf['evaluated'] ?> collected settings match the standard</div>
                </div>
            </div>
            <div class="col-lg-8">
                <div class="card rounded-4 overflow-hidden">
                    <div class="table-responsive">
                        <table class="table align-middle mb-0">
                            <thead class="text-uppercase"><tr><th class="ps-4">Setting</th><th>Severity</th><th>Standard</th><th>Actual</th><th class="pe-4">Result</th></tr></thead>
                            <tbody>
                            <?php
                            $checks = $cf['checks'];
                            $order = ['fail' => 0, 'missing' => 2, 'pass' => 1];
                            usort($checks, fn($a, $b) => $order[$a['state']] <=> $order[$b['state']]);
                            foreach ($checks as $c): ?>
                                <tr>
                                    <td class="ps-4"><div class="fw-semibold"><?= h($c['label']) ?></div><div class="muted-xs mono"><?= h($c['key']) ?></div></td>
                                    <td><span class="badge rounded-pill bg-<?= ['high' => 'danger', 'medium' => 'warning', 'low' => 'secondary'][$c['severity']] ?>-subtle text-<?= ['high' => 'danger', 'medium' => 'warning', 'low' => 'secondary'][$c['severity']] ?>-emphasis"><?= h($c['severity']) ?></span></td>
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
                <?php
                $extra = array_diff_key($cfd['settings'] ?? [], $config['cloudflare_standard']);
                if ($extra): ?>
                <div class="card rounded-4 p-4 mt-4">
                    <div class="section-title mb-2">Other collected settings</div>
                    <div class="d-flex flex-wrap gap-2">
                        <?php foreach ($extra as $k => $v): ?><span class="badge bg-light text-dark border mono"><?= h($k) ?>: <?= h(fmt_value($v)) ?></span><?php endforeach; ?>
                    </div>
                </div>
                <?php endif; ?>
            </div>
        </div>
        <?php endif; ?>
    </div>

    <!-- Wordfence -->
    <div class="tab-pane fade" id="t-wf">
        <?php if (!$wf['available']): ?>
            <div class="alert alert-light border">No Wordfence scan report found for this site.</div>
        <?php elseif (!$wf['issues']): ?>
            <div class="alert alert-success"><i class="bi bi-check-circle-fill me-1"></i>Last scan clean · report updated <?= h(human_age(time() - $wf['scanned_at'])) ?>.</div>
        <?php else: ?>
            <div class="muted-xs mb-2">Report updated <?= h(human_age(time() - $wf['scanned_at'])) ?> (<?= h(date('Y-m-d H:i', $wf['scanned_at'])) ?>)</div>
            <div class="card rounded-4 overflow-hidden">
                <div class="table-responsive">
                    <table class="table table-sm align-middle mb-0 small">
                        <?php if ($wf['header']): ?><thead class="text-uppercase"><tr><?php foreach ($wf['header'] as $hcell): ?><th><?= h($hcell) ?></th><?php endforeach; ?></tr></thead><?php endif; ?>
                        <tbody>
                        <?php foreach ($wf['rows'] as $row): ?>
                            <tr><?php foreach ($row as $cell): ?><td class="text-break"><?= h($cell) ?></td><?php endforeach; ?></tr>
                        <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
            </div>
        <?php endif; ?>
    </div>

    <?php if ($s['errors']): ?>
    <div class="tab-pane fade" id="t-errors">
        <div class="card rounded-4 p-4">
            <ul class="mb-0 mono small"><?php foreach ($s['errors'] as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul>
        </div>
    </div>
    <?php endif; ?>
</div>
<?php page_footer();
