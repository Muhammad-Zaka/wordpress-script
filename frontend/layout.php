<?php
function page_header(string $title, string $back = ''): void
{ ?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="robots" content="noindex, nofollow">
    <title><?= h($title) ?></title>
    <script>
        // Follow the OS light/dark preference
        document.documentElement.setAttribute('data-bs-theme', matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
    </script>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
    <style>
        :root, [data-bs-theme="light"] {
            --paper: #F5F6F8;
            --surface: #FFFFFF;
            --ink: #1B2330;
            --ink-2: #5E6878;
            --ink-3: #8C95A3;
            --line: #E2E5EA;
            --line-2: #EEF0F3;
            --accent: #0F6E78;
            --accent-soft: #E3F1F2;
            --danger: #C2372C;  --danger-soft: #FBEAE8;
            --warning: #B26B00; --warning-soft: #FDF1DC;
            --ok: #2F8552;      --ok-soft: #E5F3EA;
            --info: #5B6B82;    --info-soft: #EDF0F4;
        }
        [data-bs-theme="dark"] {
            --paper: #13171E;
            --surface: #1A1F28;
            --ink: #E5E8ED;
            --ink-2: #A3ACBA;
            --ink-3: #7A8494;
            --line: #2B323D;
            --line-2: #232933;
            --accent: #4FB3BC;
            --accent-soft: #173238;
            --danger: #F07167;  --danger-soft: #3A1F1E;
            --warning: #E9A23B; --warning-soft: #3A2C14;
            --ok: #5CC285;      --ok-soft: #173225;
            --info: #9AA8BC;    --info-soft: #232B36;
        }
        :root {
            --bs-body-font-family: 'IBM Plex Sans', system-ui, sans-serif;
            --bs-font-monospace: 'IBM Plex Mono', ui-monospace, monospace;
            --bs-body-bg: var(--paper);
            --bs-body-color: var(--ink);
            --bs-border-color: var(--line);
            --bs-link-color-rgb: 15, 110, 120;
            --bs-secondary-color: var(--ink-2);
        }
        body { background: var(--paper); color: var(--ink); font-size: 14.5px; font-feature-settings: "tnum" 1; -webkit-font-smoothing: antialiased; }
        a { color: var(--accent); }
        h1, h2, h3, h4 { color: var(--ink); }
        .grid-2 > .panel { margin-top: 0 !important; }
        .wrap { max-width: 1320px; margin: 0 auto; padding: 0 24px 64px; }
        @media (max-width: 576px) { .wrap { padding: 0 16px 48px; } .search { width: 100%; min-width: 0; } }
        :focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

        /* Top bar */
        .topbar { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 18px 0; border-bottom: 1px solid var(--line); margin-bottom: 36px; }
        .brand { display: flex; align-items: center; gap: 10px; font-weight: 600; color: var(--ink); text-decoration: none; }
        .brand-mark { width: 22px; height: 22px; border-radius: 6px; background: var(--ink); display: grid; place-items: center; }
        .brand-mark::after { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--paper); box-shadow: 0 0 0 2px var(--ink), 0 0 0 4px var(--paper); }
        .crumb { color: var(--ink-2); text-decoration: none; }
        .crumb:hover { color: var(--ink); }

        /* Type */
        .t-hero { font-size: clamp(26px, 3.4vw, 38px); font-weight: 600; letter-spacing: -0.02em; line-height: 1.15; margin: 0; }
        .t-hero .n-bad { color: var(--danger); }
        .t-h2 { font-size: 15px; font-weight: 600; margin: 0 0 12px; }
        .t-muted { color: var(--ink-2); }
        .t-faint { color: var(--ink-3); }
        .t-small { font-size: 12.5px; }
        .mono { font-family: var(--bs-font-monospace); font-size: .9em; }

        /* Panels: one surface style, used sparingly */
        .panel { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; }
        .panel-pad { padding: 20px 22px; }
        .panel + .panel, .panel + .t-h2, .section + .section { margin-top: 28px; }
        .panel-head { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; padding: 16px 22px 10px; }

        /* Status dot */
        .dot { display: inline-flex; align-items: center; gap: 7px; white-space: nowrap; }
        .dot::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: var(--ink-3); flex: none; }
        .dot-danger::before { background: var(--danger); } .dot-danger { color: var(--danger); }
        .dot-warning::before { background: var(--warning); } .dot-warning { color: var(--warning); }
        .dot-ok::before { background: var(--ok); }
        .dot-info::before { background: var(--accent); }
        .dot-off { color: var(--ink-3); }
        .dot-off::before { background: transparent; box-shadow: inset 0 0 0 1.5px var(--ink-3); }

        /* Small tag for actions / plans */
        .tag { display: inline-block; font-size: 12px; font-weight: 500; padding: 2px 8px; border-radius: 5px; background: var(--info-soft); color: var(--ink-2); white-space: nowrap; }
        .tag-danger { background: var(--danger-soft); color: var(--danger); }
        .tag-warning { background: var(--warning-soft); color: var(--warning); }
        .tag-ok { background: var(--ok-soft); color: var(--ok); }
        .tag-accent { background: var(--accent-soft); color: var(--accent); }

        /* Tables */
        .table { --bs-table-bg: transparent; --bs-table-hover-bg: var(--line-2); --bs-table-color: var(--ink); --bs-table-hover-color: var(--ink); margin: 0; }
        .table > :not(caption) > * > * { padding: 12px 14px; border-bottom-color: var(--line-2); }
        .table thead th { font-size: 12.5px; font-weight: 500; color: var(--ink-3); border-bottom: 1px solid var(--line); white-space: nowrap; }
        .table tbody tr:last-child > * { border-bottom: 0; }
        .table td:first-child, .table th:first-child { padding-left: 22px; }
        .table td:last-child, .table th:last-child { padding-right: 22px; }
        th.sortable { cursor: pointer; user-select: none; }
        th.sortable:hover { color: var(--ink); }
        th.sortable[data-dir="asc"]::after { content: " ↑"; } th.sortable[data-dir="desc"]::after { content: " ↓"; }

        /* Tabs: underline */
        .tabs { display: flex; gap: 22px; border-bottom: 1px solid var(--line); margin: 32px 0 24px; overflow-x: auto; flex-wrap: nowrap; }
        .tabs .nav-link { padding: 10px 0; margin-bottom: -1px; border: 0; border-bottom: 2px solid transparent; border-radius: 0; color: var(--ink-2); font-weight: 500; background: none; white-space: nowrap; }
        .tabs .nav-link:hover { color: var(--ink); }
        .tabs .nav-link.active { color: var(--ink); border-bottom-color: var(--ink); }
        .tabs .count { color: var(--ink-3); font-weight: 400; margin-left: 4px; }

        /* Definition lists */
        .kv { display: grid; grid-template-columns: minmax(130px, 40%) 1fr; gap: 10px 16px; margin: 0; }
        .kv dt { font-weight: 400; color: var(--ink-2); }
        .kv dd { margin: 0; }

        /* Inputs / buttons */
        .search { margin-left: auto; display: flex; align-items: center; gap: 8px; background: var(--surface); border: 1px solid var(--line); border-radius: 8px; padding: 7px 12px; min-width: 240px; }
        .search:focus-within { border-color: var(--accent); }
        .search input { border: 0; outline: 0; background: transparent; color: var(--ink); width: 100%; }
        .btn-quiet { border: 1px solid var(--line); background: var(--surface); color: var(--ink); border-radius: 8px; padding: 6px 12px; font-size: 13.5px; font-weight: 500; text-decoration: none; }
        .btn-quiet:hover { border-color: var(--ink-3); color: var(--ink); }
        .form-check-input:checked { background-color: var(--accent); border-color: var(--accent); }
        details > summary { cursor: pointer; color: var(--ink-3); font-size: 12.5px; }
        pre.code { background: var(--paper); border: 1px solid var(--line-2); border-radius: 6px; padding: 10px 12px; margin: 6px 0 0; white-space: pre-wrap; font-size: 12px; color: var(--ink); }
        .tooltip-inner { text-align: left; max-width: 340px; }
        .empty { padding: 28px 22px; color: var(--ink-2); }
        @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }
    </style>
</head>
<body>
<div class="wrap">
    <header class="topbar">
        <a href="./" class="brand"><span class="brand-mark"></span>Fleet health</a>
        <?php if ($back): ?><a href="./" class="crumb"><i class="bi bi-arrow-left me-1"></i><?= h($back) ?></a><?php endif; ?>
    </header>
<?php }

function page_footer(): void
{ ?>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script>
document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(el => new bootstrap.Tooltip(el));
// Remember the selected tab per page via the URL hash
(() => {
    const t = location.hash && document.querySelector('.tabs [data-bs-target="' + location.hash.replace('#', '#t-') + '"]');
    if (t) bootstrap.Tab.getOrCreateInstance(t).show();
    document.querySelectorAll('.tabs [data-bs-toggle="tab"]').forEach(el => el.addEventListener('shown.bs.tab', e => history.replaceState(null, '', '#' + e.target.dataset.bsTarget.replace('#t-', ''))));
})();
</script>
</body>
</html>
<?php }
