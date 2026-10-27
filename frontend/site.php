<?php
require __DIR__ . '/lib.php';
require __DIR__ . '/layout.php';

$slug = (string) ($_GET['site'] ?? '');
$file = rtrim($config['metrics_dir'], '/') . '/' . $slug . '.json';
$s = (valid_slug($slug) && is_file($file)) ? load_site_file($file, $config) : null;

if (!$s) {
    http_response_code(404);
    page_header('Site not found', 'All sites');
    echo '<h1 class="t-hero">No report for this site</h1><p class="t-muted mt-2">There is no report named <span class="mono">' . h($slug) . '</span>. Check the link, or run the collector for this vhost.</p>';
    page_footer();
    exit;
}

$wp  = $s['wordpress'];
$env = $s['environment'] ?? [];
$cfd = $s['cloudflare'] ?? [];
$cf  = $s['_cf'];
$wf  = $s['_wf'];
$bk  = $s['_bk'];

function yn($v, bool $goodWhenTrue = true, string $yes = 'Yes', string $no = 'No'): string
{
    if ($v === null) return '<span class="t-faint">Not collected</span>';
    return dot(($goodWhenTrue ? $v : !$v) ? 'ok' : 'warning', $v ? $yes : $no);
}

function status_text(string $status): string
{
    $tone = ['active' => 'ok', 'active-network' => 'ok', 'parent' => 'info', 'inactive' => 'off', 'must-use' => 'info', 'dropin' => 'info'][$status] ?? 'off';
    return dot($tone, ucfirst(str_replace('-', ' ', $status)));
}

$issues = $s['_health'];
$order = ['danger' => 0, 'warning' => 1, 'info' => 2];
usort($issues, fn($a, $b) => $order[$a['level']] <=> $order[$b['level']]);
$serious = count(array_filter($issues, fn($c) => $c['level'] !== 'info'));

page_header($s['domain'] . ' – Fleet health', 'All sites');
?>
<style>
    .site-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 16px; flex-wrap: wrap; }
    .site-meta { display: flex; flex-wrap: wrap; gap: 6px 20px; color: var(--ink-2); margin-top: 10px; }
    .issues { list-style: none; margin: 0; padding: 0; }
    .issues li { display: grid; grid-template-columns: 220px 1fr; gap: 12px; padding: 11px 22px; border-top: 1px solid var(--line-2); }
    .issues li:first-child { border-top: 0; }
    @media (max-width: 640px) { .issues li { grid-template-columns: 1fr; gap: 2px; } }
    .grid-2 { display: grid; grid-template-columns: 1fr 1fr; gap: 28px; }
    @media (max-width: 900px) { .grid-2 { grid-template-columns: 1fr; } }
    .strip { display: grid; grid-template-columns: repeat(30, 1fr); gap: 3px; margin-top: 14px; }
    .strip span { height: 18px; border-radius: 3px; background: var(--line); min-width: 5px; }
    .strip span.full { background: var(--ok); }
    .strip span.part { background: var(--warning); }
    .strip-axis { display: flex; justify-content: space-between; color: var(--ink-3); font-size: 12px; margin-top: 6px; }
    .type-filter { display: flex; gap: 6px; flex-wrap: wrap; }
</style>

<div class="site-head">
    <div>
        <h1 class="t-hero"><?= h($s['domain']) ?></h1>
        <div class="site-meta">
            <span>vhost <span class="mono"><?= h($s['site']) ?></span></span>
            <span>WordPress <span class="mono"><?= h($wp['version'] ?: '?') ?></span></span>
            <?php if (!empty($env['php_version'])): ?><span>PHP <span class="mono"><?= h($env['php_version']) ?></span></span><?php endif; ?>
            <span style="<?= $s['_stale'] ? 'color: var(--danger)' : '' ?>" title="<?= h(date('Y-m-d H:i', $s['_ts'])) ?>">Checked <?= h($s['_age']) ?></span>
        </div>
    </div>
    <div class="d-flex gap-2">
        <?php if (!empty($env['home'])): ?>
            <a href="<?= h($env['home']) ?>" target="_blank" rel="noopener" class="btn-quiet">Open site</a>
            <a href="<?= h(rtrim($env['home'], '/')) ?>/wp-admin/" target="_blank" rel="noopener" class="btn-quiet">WP Admin</a>
        <?php else: ?>
            <a href="https://<?= h($s['domain']) ?>" target="_blank" rel="noopener" class="btn-quiet">Open site</a>
        <?php endif; ?>
    </div>
</div>

<div class="panel" style="margin-top: 28px">
    <div class="panel-head">
        <h2 class="t-h2 m-0"><?= $serious ? plural($serious, 'thing') . ' need' . ($serious === 1 ? 's' : '') . ' attention' : 'Nothing needs attention' ?></h2>
        <?php if (count($issues) > $serious): ?><span class="t-faint t-small"><?= plural(count($issues) - $serious, 'note') ?> below</span><?php endif; ?>
    </div>
    <?php if ($issues): ?>
    <ul class="issues">
        <?php foreach ($issues as $c): ?>
            <li><?= dot($c['level'] === 'info' ? 'off' : $c['level'], $c['label']) ?><span class="t-muted"><?= h($c['detail']) ?></span></li>
        <?php endforeach; ?>
    </ul>
    <?php else: ?>
        <div class="empty pt-0">Updates, backups, security scan and Cloudflare all look good.</div>
    <?php endif; ?>
</div>

<nav class="nav tabs" role="tablist">
    <button class="nav-link active" data-bs-toggle="tab" data-bs-target="#t-overview" type="button">Overview</button>
    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#t-plugins" type="button">Plugins<span class="count"><?= $s['plugins']['total'] ?></span></button>
    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#t-themes" type="button">Themes<span class="count"><?= $s['themes']['total'] ?></span></button>
    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#t-cf" type="button">Cloudflare</button>
    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#t-backups" type="button">Backups<?php if ($bk['available']): ?><span class="count"><?= count($bk['rows']) ?></span><?php endif; ?></button>
    <button class="nav-link" data-bs-toggle="tab" data-bs-target="#t-wordfence" type="button">Wordfence<?php if ($wf['issues']): ?><span class="count" style="color: var(--danger)"><?= $wf['issues'] ?></span><?php endif; ?></button>
    <?php if ($s['errors'] || !empty($cfd['fetch_errors'])): ?>
        <button class="nav-link" data-bs-toggle="tab" data-bs-target="#t-log" type="button">Collector log</button>
    <?php endif; ?>
</nav>

<div class="tab-content">
    <!-- Overview -->
    <div class="tab-pane fade show active" id="t-overview">
        <div class="grid-2">
            <section class="panel panel-pad">
                <h2 class="t-h2">WordPress</h2>
                <dl class="kv">
                    <dt>Version</dt><dd><span class="mono"><?= h($wp['version'] ?: '?') ?></span>
                        <?php if ($wp['update_available'] ?? false): ?><span class="ms-2" style="color: var(--warning)"><?= h($wp['updates'][0]['version'] ?? '') ?> available</span><?php endif; ?></dd>
                    <dt>Update check</dt><dd><?= ($wp['update_check_status'] ?? '') === 'error' ? dot('warning', 'Failed') : dot('ok', 'OK') ?></dd>
                    <dt>Core files</dt><dd><?php $ck = $wp['checksums'] ?? null; echo $ck === null ? '<span class="t-faint">Not collected</span>' : ($ck === 'ok' ? dot('ok', 'Match WordPress.org') : dot('danger', 'Modified or unexpected files')); ?></dd>
                    <dt>Core auto-updates</dt><dd><?= h(fmt_value($env['auto_update_core'] ?? null)) ?></dd>
                    <dt>Search engines</dt><dd><?= array_key_exists('blog_public', $env) ? ($env['blog_public'] ? dot('ok', 'Allowed') : dot('danger', 'Discouraged')) : '<span class="t-faint">Not collected</span>' ?></dd>
                    <dt>Multisite</dt><dd><?= array_key_exists('is_multisite', $env) ? ($env['is_multisite'] ? 'Yes' : 'No') : '<span class="t-faint">Not collected</span>' ?></dd>
                    <dt>Drop-ins</dt><dd><?= empty($s['dropins']) ? 'None' : implode(', ', array_map(fn($d) => '<span class="mono">' . h($d['name']) . '</span>', $s['dropins'])) ?></dd>
                </dl>
            </section>
            <section class="panel panel-pad">
                <h2 class="t-h2">Server</h2>
                <?php if (!$env): ?>
                    <p class="t-muted m-0">Re-run the collector to fill in PHP, database, debug and disk details.</p>
                <?php else: ?>
                <dl class="kv">
                    <dt>PHP</dt><dd class="mono"><?= h($env['php_version'] ?? '—') ?></dd>
                    <dt>Database</dt><dd class="mono"><?= h($env['mysql_version'] ?? '—') ?></dd>
                    <dt>Memory limit</dt><dd class="mono"><?= h($env['memory_limit'] ?? '—') ?></dd>
                    <dt>WP_DEBUG</dt><dd><?= yn($env['wp_debug'] ?? null, false, 'On', 'Off') ?></dd>
                    <dt>File editor</dt><dd><?= array_key_exists('disallow_file_edit', $env) ? ($env['disallow_file_edit'] ? dot('ok', 'Disabled') : dot('warning', 'Enabled')) : '—' ?></dd>
                    <dt>WP-Cron</dt><dd><?= array_key_exists('disable_wp_cron', $env) ? ($env['disable_wp_cron'] ? 'System cron' : 'Built-in') : '—' ?></dd>
                    <dt>Users</dt><dd><?= h($env['users_total'] ?? '—') ?>, of which <?= h($env['admins'] ?? '—') ?> admins</dd>
                    <dt>Autoloaded options</dt><dd><?= h(human_bytes($env['autoload_bytes'] ?? null)) ?></dd>
                    <dt>Disk</dt><dd><?= h(human_bytes($env['disk_bytes'] ?? null)) ?> total, <?= h(human_bytes($env['uploads_bytes'] ?? null)) ?> uploads</dd>
                </dl>
                <?php endif; ?>
            </section>
        </div>
    </div>

    <!-- Plugins -->
    <div class="tab-pane fade" id="t-plugins">
        <div class="panel">
            <div class="table-responsive">
                <table class="table align-middle">
                    <thead><tr><th>Plugin</th><th>Status</th><th>Version</th><th>Update</th><th>Auto-update</th></tr></thead>
                    <tbody>
                    <?php
                    $items = $s['plugins']['items'];
                    usort($items, fn($a, $b) => [($b['update'] ?? '') === 'available', $a['name']] <=> [($a['update'] ?? '') === 'available', $b['name']]);
                    foreach ($items as $p): ?>
                        <tr>
                            <td><div class="fw-medium"><?= h($p['title'] ?? $p['name']) ?></div><?php if (!empty($p['title'])): ?><div class="t-faint t-small mono"><?= h($p['name']) ?></div><?php endif; ?></td>
                            <td><?= status_text($p['status'] ?? '') ?></td>
                            <td class="mono"><?= h($p['version'] ?: '—') ?></td>
                            <td><?= ($p['update'] ?? '') === 'available' ? '<span style="color: var(--warning)">' . h($p['update_version']) . ' available</span>' : '<span class="t-faint">—</span>' ?></td>
                            <td class="<?= ($p['auto_update'] ?? 'off') === 'on' ? '' : 't-faint' ?>"><?= ($p['auto_update'] ?? 'off') === 'on' ? 'On' : 'Off' ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <!-- Themes -->
    <div class="tab-pane fade" id="t-themes">
        <div class="panel">
            <div class="table-responsive">
                <table class="table align-middle">
                    <thead><tr><th>Theme</th><th>Status</th><th>Version</th><th>Update</th><th>Auto-update</th></tr></thead>
                    <tbody>
                    <?php foreach ($s['themes']['items'] as $t): ?>
                        <tr>
                            <td><div class="fw-medium"><?= h($t['title'] ?? $t['name']) ?></div><?php if (!empty($t['title'])): ?><div class="t-faint t-small mono"><?= h($t['name']) ?></div><?php endif; ?></td>
                            <td><?= status_text($t['status'] ?? '') ?></td>
                            <td class="mono"><?= h($t['version'] ?: '—') ?></td>
                            <td><?= ($t['update'] ?? '') === 'available' ? '<span style="color: var(--warning)">' . h($t['update_version']) . ' available</span>' : '<span class="t-faint">—</span>' ?></td>
                            <td class="<?= ($t['auto_update'] ?? 'off') === 'on' ? '' : 't-faint' ?>"><?= ($t['auto_update'] ?? 'off') === 'on' ? 'On' : 'Off' ?></td>
                        </tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </div>
        <?php if ($config['hidden_themes']): ?><p class="t-faint t-small mt-2">Not shown: <?= h(implode(', ', $config['hidden_themes'])) ?> (set in config.php)</p><?php endif; ?>
    </div>

    <!-- Cloudflare -->
    <div class="tab-pane fade" id="t-cf">
        <?php if (!$s['_has_cf']): ?>
            <p class="t-muted">This site has no active Cloudflare zone.</p>
        <?php else: require __DIR__ . '/site_cloudflare.php'; endif; ?>
    </div>

    <!-- Backups -->
    <div class="tab-pane fade" id="t-backups">
        <?php if (!$bk['available']): ?>
            <p class="t-muted">No backup report found. Expected <span class="mono"><?= h(rtrim($config['backups_dir'], '/') . '/' . $s['site'] . '.csv') ?></span>.</p>
        <?php elseif (!$bk['rows']): ?>
            <p class="t-muted">The backup report for this site is empty.</p>
        <?php else:
            $primary = array_key_first($config['backup_max_age_days']);
            $today = strtotime('today'); ?>
        <section class="panel panel-pad">
            <div class="d-flex justify-content-between flex-wrap gap-2">
                <h2 class="t-h2 m-0">Last 30 days</h2>
                <span class="t-faint t-small">
                    <span class="dot dot-ok">All expected types</span>
                    <span class="dot dot-warning ms-3">Some types</span>
                    <span class="dot dot-off ms-3">None</span>
                </span>
            </div>
            <div class="strip">
                <?php
                $expected = array_keys($config['backup_max_age_days']);
                for ($i = 29; $i >= 0; $i--) {
                    $d = date('Y-m-d', $today - $i * 86400);
                    $types = array_unique($bk['days'][$d] ?? []);
                    $hasAll = !array_diff($expected, $types);
                    $cls = $types ? ($hasAll ? 'full' : 'part') : '';
                    echo '<span class="' . $cls . '" data-bs-toggle="tooltip" title="' . h(date('D j M', strtotime($d)) . ': ' . ($types ? implode(', ', $types) : 'no backups')) . '"></span>';
                }
                ?>
            </div>
            <div class="strip-axis"><span><?= h(date('j M', $today - 29 * 86400)) ?></span><span>Today</span></div>
        </section>

        <section class="panel" style="margin-top: 28px">
            <div class="table-responsive">
                <table class="table align-middle">
                    <thead><tr><th>Type</th><th>Latest</th><th>Copies</th><th>Oldest</th><th>Status</th></tr></thead>
                    <tbody>
                    <?php foreach ($bk['types'] as $type => $t):
                        $max = $config['backup_max_age_days'][$type] ?? null; ?>
                        <tr>
                            <td class="fw-medium"><?= h($type) ?></td>
                            <td><?= h($t['latest']) ?> <span class="t-faint t-small"><?= $t['age_days'] === 0 ? 'today' : $t['age_days'] . 'd ago' ?></span></td>
                            <td><?= $t['count'] ?></td>
                            <td><?= h($t['oldest']) ?></td>
                            <td><?= $max === null ? '<span class="t-faint">Not monitored</span>' : ($t['age_days'] > $max ? dot('danger', 'Overdue (max ' . $max . 'd)') : dot('ok', 'On schedule')) ?></td>
                        </tr>
                    <?php endforeach; ?>
                    <?php foreach (array_diff(array_keys($config['backup_max_age_days']), array_keys($bk['types'])) as $missing): ?>
                        <tr><td class="fw-medium"><?= h($missing) ?></td><td colspan="3" class="t-faint">No backups in report</td><td><?= dot('danger', 'Missing') ?></td></tr>
                    <?php endforeach; ?>
                    </tbody>
                </table>
            </div>
        </section>

        <section style="margin-top: 28px">
            <div class="d-flex justify-content-between align-items-center flex-wrap gap-2 mb-2">
                <h2 class="t-h2 m-0">Backup files</h2>
                <div class="type-filter" id="bkFilter">
                    <button class="filter active" data-type="">All</button>
                    <?php foreach (array_keys($bk['types']) as $type): ?><button class="filter" data-type="<?= h($type) ?>"><?= h($type) ?></button><?php endforeach; ?>
                </div>
            </div>
            <div class="panel">
                <div class="table-responsive">
                    <table class="table align-middle" id="bkTable">
                        <thead><tr><th>File</th><th>Date</th><th>Type</th><th>Format</th></tr></thead>
                        <tbody>
                        <?php foreach ($bk['rows'] as $i => $r): ?>
                            <tr data-type="<?= h($r['type']) ?>" <?= $i >= 20 ? 'data-extra="1" style="display:none"' : '' ?>>
                                <td class="mono text-break"><?= h($r['file']) ?></td>
                                <td><?= h($r['date']) ?></td>
                                <td><?= h($r['type']) ?></td>
                                <td class="t-muted"><?= h($r['ext']) ?></td>
                            </tr>
                        <?php endforeach; ?>
                        </tbody>
                    </table>
                </div>
                <?php if (count($bk['rows']) > 20): ?>
                    <div class="px-4 py-3" style="border-top: 1px solid var(--line-2)"><button class="btn-quiet" id="bkMore">Show all <?= count($bk['rows']) ?> files</button></div>
                <?php endif; ?>
            </div>
            <p class="t-faint t-small mt-2">Report updated <?= h(human_age(time() - $bk['report_at'])) ?>.</p>
        </section>
        <style>.filter { border: 1px solid transparent; background: none; color: var(--ink-2); border-radius: 7px; padding: 4px 10px; font-size: 13px; } .filter.active { background: var(--surface); border-color: var(--line); color: var(--ink); }</style>
        <script>
        (() => {
            const rows = [...document.querySelectorAll('#bkTable tbody tr')];
            let type = '', all = false;
            const more = document.getElementById('bkMore');
            function apply() {
                let n = 0;
                rows.forEach(r => {
                    const match = !type || r.dataset.type === type;
                    const show = match && (all || type || n < 20);
                    if (match) n++;
                    r.style.display = show ? '' : 'none';
                });
                if (more) more.parentElement.style.display = (all || type) ? 'none' : '';
            }
            document.querySelectorAll('#bkFilter .filter').forEach(b => b.addEventListener('click', () => {
                type = b.dataset.type;
                document.querySelectorAll('#bkFilter .filter').forEach(x => x.classList.toggle('active', x === b));
                apply();
            }));
            if (more) more.addEventListener('click', () => { all = true; apply(); });
        })();
        </script>
        <?php endif; ?>
    </div>

    <!-- Wordfence -->
    <div class="tab-pane fade" id="t-wordfence">
        <?php if (!$wf['available']): ?>
            <p class="t-muted">No Wordfence scan report found for this site.</p>
        <?php elseif (!$wf['issues']): ?>
            <p><?= dot('ok', 'Last scan was clean') ?> <span class="t-faint ms-2">Report updated <?= h(human_age(time() - $wf['scanned_at'])) ?></span></p>
        <?php else: ?>
            <p class="t-faint t-small">Report updated <?= h(human_age(time() - $wf['scanned_at'])) ?> (<?= h(date('Y-m-d H:i', $wf['scanned_at'])) ?>)</p>
            <div class="panel">
                <div class="table-responsive">
                    <table class="table align-middle">
                        <?php if ($wf['header']): ?><thead><tr><?php foreach ($wf['header'] as $hc): ?><th><?= h($hc) ?></th><?php endforeach; ?></tr></thead><?php endif; ?>
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

    <?php if ($s['errors'] || !empty($cfd['fetch_errors'])): ?>
    <div class="tab-pane fade" id="t-log">
        <?php if ($s['errors']): ?>
            <section class="panel panel-pad">
                <h2 class="t-h2">WordPress collection</h2>
                <ul class="mb-0 mono t-small"><?php foreach ($s['errors'] as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul>
            </section>
        <?php endif; ?>
        <?php if (!empty($cfd['fetch_errors'])): ?>
            <section class="panel panel-pad">
                <h2 class="t-h2">Cloudflare calls that failed</h2>
                <p class="t-muted t-small">Usually a missing API token permission, or a feature that isn't on this plan.</p>
                <ul class="mb-0 mono t-small"><?php foreach ($cfd['fetch_errors'] as $e): ?><li><?= h($e) ?></li><?php endforeach; ?></ul>
            </section>
        <?php endif; ?>
    </div>
    <?php endif; ?>
</div>
<?php page_footer();
