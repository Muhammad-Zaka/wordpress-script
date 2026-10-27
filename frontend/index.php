<?php
require __DIR__ . '/lib.php';
require __DIR__ . '/layout.php';

[$sites, $hiddenCount, $badFiles] = load_sites($config);

$stats = ['sites' => count($sites), 'updates' => 0, 'wordfence' => 0, 'noncompliant' => 0, 'stale' => 0, 'danger' => 0];
foreach ($sites as $s) {
    if ($s['_needs_update'])                     $stats['updates']++;
    if ($s['_wf']['issues'] > 0)                 $stats['wordfence']++;
    if ($s['_has_cf'] && !$s['_cf']['compliant'] && $s['_cf']['evaluated'] > 0) $stats['noncompliant']++;
    if ($s['_stale'])                            $stats['stale']++;
    foreach ($s['_health'] as $c) { if ($c['level'] === 'danger') { $stats['danger']++; break; } }
}

$cards = [
    ['Monitored sites',      $stats['sites'],        'hdd-rack',            'primary', $hiddenCount ? "$hiddenCount hidden (no Cloudflare)" : 'All reports loaded', ''],
    ['Need updates',         $stats['updates'],      'arrow-repeat',        'warning', 'Core, plugin or theme',     'updates'],
    ['Wordfence findings',   $stats['wordfence'],    'shield-exclamation',  'danger',  'Sites with scan issues',    'wordfence'],
    ['Cloudflare drift',     $stats['noncompliant'], 'cloud-slash',         'info',    'Not matching the standard', 'noncompliant'],
    ['Stale reports',        $stats['stale'],        'clock-history',       'secondary', 'Older than ' . $config['stale_after_hours'] . 'h', 'stale'],
];

page_header('WordPress Fleet Control Center');
?>
<header class="mb-4 d-flex flex-column flex-md-row justify-content-between align-items-md-end gap-3">
    <div>
        <span class="badge bg-primary-subtle text-primary rounded-pill px-3 font-monospace small mb-2">Fleet Management</span>
        <h1 class="h3 fw-bold mb-0">WordPress Control Center</h1>
    </div>
    <div class="muted-xs">Page generated <?= h(date('Y-m-d H:i T')) ?></div>
</header>

<?php if ($badFiles): ?>
<div class="alert alert-warning small py-2"><i class="bi bi-exclamation-triangle me-1"></i>
    Could not parse <?= count($badFiles) ?> report(s): <span class="mono"><?= h(implode(', ', $badFiles)) ?></span></div>
<?php endif; ?>

<div class="row g-3 mb-4">
    <?php foreach ($cards as [$label, $value, $icon, $color, $sub, $filter]): ?>
    <div class="col-6 col-lg">
        <div class="card stat-card rounded-4 p-3 h-100 <?= $filter ? 'stat-filter' : '' ?>" <?= $filter ? 'data-filter="' . h($filter) . '" role="button"' : '' ?>>
            <div class="d-flex justify-content-between align-items-start mb-3">
                <div class="text-muted small fw-semibold"><?= h($label) ?></div>
                <div class="icon bg-<?= $color ?>-subtle text-<?= $color ?>-emphasis"><i class="bi bi-<?= $icon ?>"></i></div>
            </div>
            <div class="value mb-1"><?= (int) $value ?></div>
            <div class="muted-xs"><?= h($sub) ?></div>
        </div>
    </div>
    <?php endforeach; ?>
</div>

<div class="d-flex flex-column flex-lg-row justify-content-between gap-3 mb-3">
    <div class="d-flex flex-wrap gap-2" id="chips">
        <button class="chip active" data-filter="all">All<span class="count"><?= $stats['sites'] ?></span></button>
        <button class="chip" data-filter="attention">Critical<span class="count"><?= $stats['danger'] ?></span></button>
        <button class="chip" data-filter="updates">Updates<span class="count"><?= $stats['updates'] ?></span></button>
        <button class="chip" data-filter="wordfence">Wordfence<span class="count"><?= $stats['wordfence'] ?></span></button>
        <button class="chip" data-filter="noncompliant">CF drift<span class="count"><?= $stats['noncompliant'] ?></span></button>
        <button class="chip" data-filter="stale">Stale<span class="count"><?= $stats['stale'] ?></span></button>
    </div>
    <div class="search-box d-flex align-items-center gap-2">
        <i class="bi bi-search text-muted"></i>
        <input type="text" id="siteSearch" placeholder="Filter domains, plugins…">
    </div>
</div>

<div class="card rounded-4 overflow-hidden">
    <div class="table-responsive">
        <table class="table table-hover align-middle mb-0" id="sitesTable">
            <thead class="text-uppercase border-bottom">
            <tr>
                <th class="ps-4 sortable" data-key="domain">Site</th>
                <th class="sortable" data-key="wp">WordPress</th>
                <th class="sortable" data-key="plugins">Plugins</th>
                <th class="sortable" data-key="cf">Cloudflare</th>
                <th class="sortable" data-key="wf">Wordfence</th>
                <th class="sortable" data-key="health">Health</th>
                <th class="sortable pe-4" data-key="age">Report</th>
            </tr>
            </thead>
            <tbody>
            <?php if (!$sites): ?>
                <tr><td colspan="7" class="text-center py-5 text-muted">
                    <i class="bi bi-folder-x fs-1 opacity-50 d-block mb-2"></i>No site reports found.
                </td></tr>
            <?php endif; ?>
            <?php foreach ($sites as $s):
                $wp = $s['wordpress'];
                $cf = $s['_cf'];
                $danger = count(array_filter($s['_health'], fn($c) => $c['level'] === 'danger'));
                $warn = count(array_filter($s['_health'], fn($c) => $c['level'] === 'warning'));
                $tags = [];
                if ($danger) $tags[] = 'attention';
                if ($s['_needs_update']) $tags[] = 'updates';
                if ($s['_wf']['issues'] > 0) $tags[] = 'wordfence';
                if ($s['_has_cf'] && !$cf['compliant'] && $cf['evaluated'] > 0) $tags[] = 'noncompliant';
                if ($s['_stale']) $tags[] = 'stale';
                $searchText = strtolower($s['domain'] . ' ' . $s['site'] . ' ' . implode(' ', array_column($s['plugins']['items'], 'name')));
                $healthTip = implode('<br>', array_map(fn($c) => h($c['label'] . ($c['detail'] ? ': ' . $c['detail'] : '')), array_filter($s['_health'], fn($c) => $c['level'] !== 'info')));
                $url = 'site.php?site=' . urlencode($s['site']);
            ?>
            <tr class="site-row" data-href="<?= h($url) ?>" data-tags="<?= h(implode(' ', $tags)) ?>" data-search="<?= h($searchText) ?>"
                data-domain="<?= h($s['domain']) ?>" data-wp="<?= h($wp['version'] ?? '') ?>" data-plugins="<?= $s['plugins']['updates_available'] * 1000 + $s['plugins']['total'] ?>"
                data-cf="<?= $cf['score'] ?? -1 ?>" data-wf="<?= $s['_wf']['available'] ? $s['_wf']['issues'] : -1 ?>" data-health="<?= $danger * 100 + $warn ?>" data-age="<?= (int) $s['_ts'] ?>">
                <td class="ps-4">
                    <a href="<?= h($url) ?>" class="fw-bold text-dark text-decoration-none"><?= h($s['domain']) ?></a>
                    <div class="muted-xs">
                        <?= h($s['site']) ?>
                        <?php if (!empty($s['environment']['php_version'])): ?> · PHP <?= h($s['environment']['php_version']) ?><?php endif; ?>
                        <?php if (!empty($s['themes']['active'])): ?> · <?= h($s['themes']['active']) ?><?php endif; ?>
                    </div>
                </td>
                <td>
                    <span class="badge bg-light text-dark border font-monospace"><?= h($wp['version'] ?: '?') ?></span>
                    <?php if ($wp['update_available'] ?? false): ?>
                        <span class="badge bg-warning-subtle text-warning-emphasis rounded-pill">→ <?= h($wp['updates'][0]['version'] ?? 'update') ?></span>
                    <?php elseif (($wp['update_check_status'] ?? 'ok') === 'error'): ?>
                        <span class="badge bg-secondary-subtle text-secondary rounded-pill">Check failed</span>
                    <?php else: ?>
                        <span class="badge bg-success-subtle text-success rounded-pill">Latest</span>
                    <?php endif; ?>
                </td>
                <td>
                    <span class="fw-semibold"><?= $s['plugins']['active'] ?></span><span class="text-muted">/<?= $s['plugins']['total'] ?></span>
                    <?php if ($s['plugins']['updates_available']): ?>
                        <span class="badge bg-warning-subtle text-warning-emphasis rounded-pill ms-1"><?= $s['plugins']['updates_available'] ?> update<?= $s['plugins']['updates_available'] > 1 ? 's' : '' ?></span>
                    <?php endif; ?>
                    <?php if ($s['themes']['updates_available']): ?>
                        <span class="badge bg-warning-subtle text-warning-emphasis rounded-pill ms-1" title="Theme updates"><i class="bi bi-palette"></i> <?= $s['themes']['updates_available'] ?></span>
                    <?php endif; ?>
                </td>
                <td>
                    <?php if (!$s['_has_cf']): ?>
                        <span class="badge bg-light text-muted border rounded-pill">No zone</span>
                    <?php else:
                        $plan = trim(str_ireplace('Website', '', $s['cloudflare']['plan'] ?? 'Free'));
                        $sc = $cf['score'];
                        $barColor = $sc === null ? '#cbd5e1' : ($sc === 100 ? '#16a34a' : ($cf['high_fails'] ? '#dc2626' : '#f59e0b'));
                    ?>
                        <div class="d-flex align-items-center gap-2">
                            <span class="badge <?= strcasecmp($plan, 'Free') === 0 ? 'bg-primary-subtle text-primary' : 'bg-success-subtle text-success' ?> rounded-pill"><?= h($plan) ?></span>
                            <?php if ($sc !== null): ?>
                                <div class="score-bar" title="<?= $cf['passed'] ?>/<?= $cf['evaluated'] ?> settings match the standard"><div style="width: <?= $sc ?>%; background: <?= $barColor ?>"></div></div>
                                <span class="muted-xs"><?= $sc ?>%</span>
                            <?php endif; ?>
                        </div>
                    <?php endif; ?>
                </td>
                <td>
                    <?php if (!$s['_wf']['available']): ?>
                        <span class="badge bg-light text-muted border rounded-pill">No scan</span>
                    <?php elseif ($s['_wf']['issues']): ?>
                        <span class="badge bg-danger-subtle text-danger border border-danger-subtle rounded-pill"><i class="bi bi-exclamation-triangle-fill me-1"></i><?= $s['_wf']['issues'] ?> issue<?= $s['_wf']['issues'] > 1 ? 's' : '' ?></span>
                    <?php else: ?>
                        <span class="badge bg-success-subtle text-success border border-success-subtle rounded-pill"><i class="bi bi-check-circle-fill me-1"></i>Clean</span>
                    <?php endif; ?>
                </td>
                <td>
                    <?php if (!$danger && !$warn): ?>
                        <span class="badge bg-success-subtle text-success rounded-pill"><i class="bi bi-check2 me-1"></i>Healthy</span>
                    <?php else: ?>
                        <span data-bs-toggle="tooltip" data-bs-html="true" title="<?= h($healthTip) ?>">
                            <?php if ($danger): ?><span class="badge bg-danger rounded-pill"><?= $danger ?> critical</span><?php endif; ?>
                            <?php if ($warn): ?><span class="badge bg-warning text-dark rounded-pill"><?= $warn ?> warning<?= $warn > 1 ? 's' : '' ?></span><?php endif; ?>
                        </span>
                    <?php endif; ?>
                </td>
                <td class="pe-4">
                    <span class="<?= $s['_stale'] ? 'text-danger fw-semibold' : 'text-muted' ?> small" title="<?= h(date('Y-m-d H:i', $s['_ts'])) ?>">
                        <i class="bi bi-<?= $s['_stale'] ? 'clock-history' : 'clock' ?> me-1"></i><?= h($s['_age']) ?>
                    </span>
                </td>
            </tr>
            <?php endforeach; ?>
            <tr id="noMatch" style="display:none"><td colspan="7" class="text-center text-muted py-4">No sites match this filter.</td></tr>
            </tbody>
        </table>
    </div>
</div>

<script>
(() => {
    const rows = [...document.querySelectorAll('.site-row')];
    const tbody = document.querySelector('#sitesTable tbody');
    const noMatch = document.getElementById('noMatch');
    let filter = 'all', term = '';

    function apply() {
        let shown = 0;
        rows.forEach(r => {
            const ok = (filter === 'all' || r.dataset.tags.split(' ').includes(filter)) && r.dataset.search.includes(term);
            r.style.display = ok ? '' : 'none';
            if (ok) shown++;
        });
        noMatch.style.display = shown || !rows.length ? 'none' : '';
    }
    function setFilter(f) {
        filter = f;
        document.querySelectorAll('.chip').forEach(c => c.classList.toggle('active', c.dataset.filter === f));
        apply();
    }
    document.querySelectorAll('.chip, .stat-filter').forEach(c => c.addEventListener('click', () => setFilter(c.dataset.filter)));
    document.getElementById('siteSearch').addEventListener('input', e => { term = e.target.value.toLowerCase().trim(); apply(); });

    rows.forEach(r => r.addEventListener('click', e => { if (!e.target.closest('a')) location.href = r.dataset.href; }));

    document.querySelectorAll('th.sortable').forEach(th => th.addEventListener('click', () => {
        const key = th.dataset.key;
        const dir = th.dataset.dir === 'asc' ? 'desc' : 'asc';
        document.querySelectorAll('th.sortable').forEach(o => delete o.dataset.dir);
        th.dataset.dir = dir;
        const num = key !== 'domain' && key !== 'wp';
        rows.sort((a, b) => {
            let x = a.dataset[key], y = b.dataset[key];
            const c = num ? (+x - +y) : x.localeCompare(y, undefined, {numeric: true});
            return dir === 'asc' ? c : -c;
        }).forEach(r => tbody.insertBefore(r, noMatch));
    }));
})();
</script>
<?php page_footer();
