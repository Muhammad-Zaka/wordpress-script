<?php
require __DIR__ . '/lib.php';
require __DIR__ . '/layout.php';

[$sites, $hiddenCount, $badFiles] = load_sites($config);

// Worst first, then alphabetical
$rank = ['danger' => 0, 'warning' => 1, 'ok' => 2];
usort($sites, fn($a, $b) => [$rank[$a['_worst']], $a['domain']] <=> [$rank[$b['_worst']], $b['domain']]);

$n = ['all' => count($sites), 'danger' => 0, 'warning' => 0, 'ok' => 0, 'updates' => 0,
      'wordfence' => 0, 'drift' => 0, 'stale' => 0, 'pro' => 0, 'free' => 0];
foreach ($sites as $s) {
    $n[$s['_worst']]++;
    if ($s['_needs_update'])        $n['updates']++;
    if ($s['_wf']['issues'] > 0)    $n['wordfence']++;
    if ($s['_cf']['failed_checks']) $n['drift']++;
    if ($s['_stale'])               $n['stale']++;
    if (!empty($s['cloudflare']['is_pro_or_higher'])) $n['pro']++; elseif ($s['_has_cf']) $n['free']++;
}
$attention = $n['danger'] + $n['warning'];
$primaryBackup = array_key_first($config['backup_max_age_days']);

$filters = [
    ['all',       'All sites',         $n['all']],
    ['danger',    'Critical',          $n['danger']],
    ['updates',   'Updates pending',   $n['updates']],
    ['wordfence', 'Wordfence findings', $n['wordfence']],
    ['drift',     'Cloudflare drift',  $n['drift']],
    ['stale',     'Stale reports',     $n['stale']],
    ['pro',       'Cloudflare Pro',    $n['pro']],
];

page_header('Fleet health');
?>
<style>
    .hero { display: grid; grid-template-columns: 1fr auto; gap: 24px 48px; align-items: end; margin-bottom: 28px; }
    @media (max-width: 860px) { .hero { grid-template-columns: 1fr; } }
    .sevbar { display: flex; height: 8px; border-radius: 4px; overflow: hidden; background: var(--line); margin: 20px 0 10px; max-width: 560px; }
    .sevbar span { display: block; height: 100%; }
    .sevbar span + span { margin-left: 2px; }
    .legend { display: flex; flex-wrap: wrap; gap: 18px; color: var(--ink-2); font-size: 13.5px; }
    .plan-split { text-align: right; }
    .plan-split .big { font-size: 28px; font-weight: 600; letter-spacing: -0.01em; line-height: 1; }
    @media (max-width: 860px) { .plan-split { text-align: left; } }
    .filters { display: flex; flex-wrap: wrap; gap: 6px; }
    .filter { border: 1px solid transparent; background: none; color: var(--ink-2); border-radius: 7px; padding: 5px 10px; font-size: 13.5px; }
    .filter b { color: var(--ink); font-weight: 600; margin-left: 4px; }
    .filter:hover { background: var(--line-2); }
    .filter.active { background: var(--surface); border-color: var(--line); color: var(--ink); }
    .filter[data-zero="1"] { opacity: .5; }
    .toolbar { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; margin-bottom: 12px; }
    #sitesTable tbody tr { cursor: pointer; }
    #sitesTable tbody tr > td:first-child { box-shadow: inset 3px 0 0 transparent; }
    #sitesTable tbody tr[data-worst="danger"] > td:first-child { box-shadow: inset 3px 0 0 var(--danger); }
    #sitesTable tbody tr[data-worst="warning"] > td:first-child { box-shadow: inset 3px 0 0 var(--warning); }
    .site-name { font-weight: 600; color: var(--ink); text-decoration: none; }
    .site-name:hover { text-decoration: underline; }
    .issue-more { color: var(--ink-3); }
</style>

<section class="hero">
    <div>
        <h1 class="t-hero">
            <?php if (!$n['all']): ?>No site reports yet
            <?php elseif ($attention): ?><span class="<?= $n['danger'] ? 'n-bad' : '' ?>"><?= $attention ?></span> of <?= $n['all'] ?> sites need attention
            <?php else: ?>All <?= $n['all'] ?> sites are healthy<?php endif; ?>
        </h1>
        <?php if ($n['all']): ?>
        <div class="sevbar" aria-hidden="true">
            <?php foreach (['danger', 'warning', 'ok'] as $k): if (!$n[$k]) continue; ?>
                <span style="flex: <?= $n[$k] ?>; background: var(--<?= $k ?>)"></span>
            <?php endforeach; ?>
        </div>
        <div class="legend">
            <span class="dot dot-danger"><?= $n['danger'] ?> critical</span>
            <span class="dot dot-warning"><?= $n['warning'] ?> warning</span>
            <span class="dot dot-ok"><?= $n['ok'] ?> healthy</span>
            <?php if ($hiddenCount): ?><span class="t-faint"><?= plural($hiddenCount, 'site') ?> without Cloudflare hidden</span><?php endif; ?>
        </div>
        <?php endif; ?>
    </div>
    <div class="plan-split">
        <div class="big"><?= $n['pro'] ?> <span class="t-faint" style="font-weight:400">/ <?= $n['pro'] + $n['free'] ?></span></div>
        <div class="t-muted t-small mt-1">sites on Cloudflare Pro or higher</div>
    </div>
</section>

<?php if ($badFiles): ?>
    <p class="dot dot-warning mb-3">Couldn't read <?= plural(count($badFiles), 'report') ?>: <span class="mono"><?= h(implode(', ', $badFiles)) ?></span></p>
<?php endif; ?>

<div class="toolbar">
    <div class="filters" role="group" aria-label="Filter sites">
        <?php foreach ($filters as $i => [$key, $label, $count]): ?>
            <button class="filter <?= $i === 0 ? 'active' : '' ?>" data-filter="<?= $key ?>" data-zero="<?= $count ? 0 : 1 ?>"><?= h($label) ?><b><?= $count ?></b></button>
        <?php endforeach; ?>
    </div>
    <label class="search">
        <i class="bi bi-search t-faint"></i>
        <input type="text" id="siteSearch" placeholder="Search sites or plugins" aria-label="Search sites or plugins">
    </label>
</div>

<div class="panel">
    <div class="table-responsive">
        <table class="table table-hover align-middle" id="sitesTable">
            <thead>
            <tr>
                <th class="sortable" data-key="domain">Site</th>
                <th class="sortable" data-key="wp">WordPress</th>
                <th class="sortable" data-key="updates">Updates</th>
                <th class="sortable" data-key="cf">Cloudflare</th>
                <th class="sortable" data-key="backup"><?= h($primaryBackup) ?> backup</th>
                <th class="sortable" data-key="wf">Wordfence</th>
                <th class="sortable" data-key="health">Needs attention</th>
                <th class="sortable" data-key="age">Checked</th>
            </tr>
            </thead>
            <tbody>
            <?php if (!$sites): ?>
                <tr><td colspan="8" class="empty">Run <span class="mono">scripts/wordpress-metrics.sh</span> to collect the first reports into <span class="mono"><?= h($config['metrics_dir']) ?></span>.</td></tr>
            <?php endif; ?>
            <?php foreach ($sites as $s):
                $wp = $s['wordpress'];
                $cf = $s['_cf'];
                $bk = $s['_bk'];
                $issues = array_values(array_filter($s['_health'], fn($c) => $c['level'] !== 'info'));
                $tags = [$s['_worst']];
                if ($s['_needs_update'])        $tags[] = 'updates';
                if ($s['_wf']['issues'] > 0)    $tags[] = 'wordfence';
                if ($cf['failed_checks'])       $tags[] = 'drift';
                if ($s['_stale'])               $tags[] = 'stale';
                if (!empty($s['cloudflare']['is_pro_or_higher'])) $tags[] = 'pro';
                $updates = array_filter([
                    $s['plugins']['updates_available'] ? plural($s['plugins']['updates_available'], 'plugin') : '',
                    $s['themes']['updates_available'] ? plural($s['themes']['updates_available'], 'theme') : '',
                ]);
                $pb = $bk['types'][$primaryBackup] ?? null;
                $url = 'site.php?site=' . urlencode($s['site']);
                $search = strtolower($s['domain'] . ' ' . $s['site'] . ' ' . implode(' ', array_column($s['plugins']['items'], 'name')));
                $rcnt = cf_rule_counts($s);
            ?>
            <tr data-href="<?= h($url) ?>" data-worst="<?= $s['_worst'] ?>" data-tags="<?= h(implode(' ', $tags)) ?>" data-search="<?= h($search) ?>"
                data-domain="<?= h($s['domain']) ?>" data-wp="<?= h($wp['version'] ?? '') ?>"
                data-updates="<?= $s['plugins']['updates_available'] + $s['themes']['updates_available'] + (($wp['update_available'] ?? false) ? 100 : 0) ?>"
                data-cf="<?= $cf['score'] ?? -1 ?>" data-backup="<?= $pb ? $pb['age_days'] : 99999 ?>"
                data-wf="<?= $s['_wf']['available'] ? $s['_wf']['issues'] : -1 ?>"
                data-health="<?= $rank[$s['_worst']] * -1000 + count($issues) ?>" data-age="<?= (int) $s['_ts'] ?>">
                <td>
                    <a href="<?= h($url) ?>" class="site-name"><?= h($s['domain']) ?></a>
                    <div class="t-faint t-small"><?= h($s['site']) ?><?= !empty($s['environment']['php_version']) ? ', PHP ' . h($s['environment']['php_version']) : '' ?></div>
                </td>
                <td>
                    <span class="mono"><?= h($wp['version'] ?: '?') ?></span>
                    <?php if ($wp['update_available'] ?? false): ?>
                        <div class="t-small" style="color: var(--warning)"><?= h($wp['updates'][0]['version'] ?? 'Update') ?> available</div>
                    <?php elseif (($wp['update_check_status'] ?? 'ok') === 'error'): ?>
                        <div class="t-small t-faint">Check failed</div>
                    <?php endif; ?>
                </td>
                <td><?= $updates ? '<span style="color: var(--warning)">' . h(implode(', ', $updates)) . '</span>' : '<span class="t-faint">None</span>' ?></td>
                <td>
                    <?php if (!$s['_has_cf']): ?>
                        <span class="t-faint">No zone</span>
                    <?php else: $plan = trim(str_ireplace('Website', '', $s['cloudflare']['plan'] ?? 'Free')); ?>
                        <span class="tag <?= strcasecmp($plan, 'Free') === 0 ? '' : 'tag-accent' ?>"><?= h($plan) ?></span>
                        <?php if ($cf['score'] !== null): ?>
                            <span class="ms-1 t-small" style="color: var(--<?= $cf['high_fails'] ? 'danger' : ($cf['failed_checks'] ? 'warning' : 'ink-2') ?>)"
                                  <?php if ($cf['failed_checks']): ?>data-bs-toggle="tooltip" title="<?= h('Off standard: ' . implode(', ', array_column($cf['failed_checks'], 'label'))) ?>"<?php endif; ?>><?= $cf['score'] ?>%</span>
                        <?php endif; ?>
                        <?php if (isset($s['cloudflare']['rulesets'])): ?><div class="t-faint t-small"><?= plural($rcnt['enabled'], 'active rule') ?></div><?php endif; ?>
                    <?php endif; ?>
                </td>
                <td>
                    <?php if (!$bk['available']): ?><?= dot('off', 'No report') ?>
                    <?php elseif (!$pb): ?><span class="t-faint">None</span>
                    <?php else: ?>
                        <span title="<?= h($pb['latest']) ?>"><?= $pb['age_days'] === 0 ? 'Today' : ($pb['age_days'] === 1 ? 'Yesterday' : $pb['age_days'] . ' days ago') ?></span>
                    <?php endif; ?>
                </td>
                <td>
                    <?php if (!$s['_wf']['available']): ?><?= dot('off', 'No scan') ?>
                    <?php elseif ($s['_wf']['issues']): ?><?= dot('danger', plural($s['_wf']['issues'], 'finding')) ?>
                    <?php else: ?><?= dot('ok', 'Clean') ?><?php endif; ?>
                </td>
                <td>
                    <?php if (!$issues): ?><span class="t-faint">Nothing</span>
                    <?php else: ?>
                        <span <?= count($issues) > 1 ? 'data-bs-toggle="tooltip" data-bs-html="true" title="' . h(implode('<br>', array_map(fn($c) => h($c['label']), $issues))) . '"' : '' ?>>
                            <?= dot($issues[0]['level'], $issues[0]['label']) ?>
                            <?php if (count($issues) > 1): ?><span class="issue-more t-small">+<?= count($issues) - 1 ?> more</span><?php endif; ?>
                        </span>
                    <?php endif; ?>
                </td>
                <td class="t-small <?= $s['_stale'] ? '' : 't-muted' ?>" style="<?= $s['_stale'] ? 'color: var(--danger)' : '' ?>" title="<?= h(date('Y-m-d H:i', $s['_ts'])) ?>"><?= h($s['_age']) ?></td>
            </tr>
            <?php endforeach; ?>
            <tr id="noMatch" style="display:none"><td colspan="8" class="empty">No sites match this filter.</td></tr>
            </tbody>
        </table>
    </div>
</div>

<script>
(() => {
    const tbody = document.querySelector('#sitesTable tbody');
    const rows = [...tbody.querySelectorAll('tr[data-href]')];
    const noMatch = document.getElementById('noMatch');
    let filter = 'all', term = '';

    function apply() {
        let shown = 0;
        rows.forEach(r => {
            const ok = (filter === 'all' || r.dataset.tags.split(' ').includes(filter)) && r.dataset.search.includes(term);
            r.style.display = ok ? '' : 'none';
            shown += ok;
        });
        noMatch.style.display = shown || !rows.length ? 'none' : '';
    }
    document.querySelectorAll('.filter').forEach(b => b.addEventListener('click', () => {
        filter = b.dataset.filter;
        document.querySelectorAll('.filter').forEach(x => x.classList.toggle('active', x === b));
        apply();
    }));
    document.getElementById('siteSearch').addEventListener('input', e => { term = e.target.value.toLowerCase().trim(); apply(); });
    rows.forEach(r => r.addEventListener('click', e => { if (!e.target.closest('a')) location.href = r.dataset.href; }));

    document.querySelectorAll('th.sortable').forEach(th => th.addEventListener('click', () => {
        const key = th.dataset.key, dir = th.dataset.dir === 'asc' ? 'desc' : 'asc';
        document.querySelectorAll('th.sortable').forEach(o => delete o.dataset.dir);
        th.dataset.dir = dir;
        const text = key === 'domain' || key === 'wp';
        rows.sort((a, b) => {
            const x = a.dataset[key], y = b.dataset[key];
            const c = text ? x.localeCompare(y, undefined, {numeric: true}) : (+x - +y);
            return dir === 'asc' ? c : -c;
        }).forEach(r => tbody.insertBefore(r, noMatch));
    }));
})();
</script>
<?php page_footer();
