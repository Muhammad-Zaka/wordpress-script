<?php
function page_header(string $title): void
{ ?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="robots" content="noindex, nofollow">
    <title><?= h($title) ?></title>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
    <style>
        :root { --bs-body-font-family: 'Plus Jakarta Sans', sans-serif; --bs-body-bg: #f8fafc; --bs-font-monospace: 'JetBrains Mono', monospace; }
        body { color: #0f172a; }
        .card { border: 1px solid #e2e8f0; box-shadow: 0 1px 3px rgba(0,0,0,.03); }
        .stat-card { border: 1px solid #e2e8f0 !important; }
        .stat-card .value { font-size: 2rem; font-weight: 700; line-height: 1; }
        .stat-card .icon { width: 40px; height: 40px; display: grid; place-items: center; border-radius: .75rem; }
        .table > :not(caption) > * > * { padding: .85rem 1rem; }
        .table thead th { font-size: .72rem; letter-spacing: .04em; color: #64748b; font-weight: 600; white-space: nowrap; background: #f8fafc; }
        th.sortable { cursor: pointer; user-select: none; }
        th.sortable:hover { color: #0f172a; }
        th.sortable[data-dir="asc"]::after { content: " ▲"; font-size: .6rem; }
        th.sortable[data-dir="desc"]::after { content: " ▼"; font-size: .6rem; }
        .badge { font-weight: 500; padding: .45em .7em; }
        .chip { border: 1px solid #e2e8f0; background: #fff; border-radius: 999px; padding: .35rem .85rem; font-size: .85rem; color: #334155; }
        .chip.active { background: #0f172a; border-color: #0f172a; color: #fff; }
        .chip .count { opacity: .6; margin-left: .25rem; }
        .search-box { background: #fff; border: 1px solid #e2e8f0; border-radius: .75rem; padding: .45rem .9rem; }
        .search-box:focus-within { border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59,130,246,.1); }
        .search-box input { outline: none; border: 0; background: transparent; width: 220px; }
        .site-row { cursor: pointer; }
        .muted-xs { font-size: .75rem; color: #64748b; }
        .mono { font-family: var(--bs-font-monospace); font-size: .82rem; }
        .score-bar { height: 6px; border-radius: 3px; background: #e2e8f0; overflow: hidden; width: 70px; }
        .score-bar > div { height: 100%; }
        .section-title { font-size: .8rem; font-weight: 700; text-transform: uppercase; letter-spacing: .05em; color: #64748b; }
        .kv dt { font-weight: 500; color: #64748b; font-size: .85rem; }
        .kv dd { margin-bottom: .6rem; }
        .nav-pills .nav-link { color: #334155; }
        .nav-pills .nav-link.active { background: #0f172a; }
    </style>
</head>
<body>
<div class="container-fluid px-3 px-md-4 py-4 py-md-5" style="max-width: 1440px;">
<?php }

function page_footer(): void
{ ?>
</div>
<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js"></script>
<script>
document.querySelectorAll('[data-bs-toggle="tooltip"]').forEach(el => new bootstrap.Tooltip(el));
</script>
</body>
</html>
<?php }
