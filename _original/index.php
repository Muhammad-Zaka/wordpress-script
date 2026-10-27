<?php
$metricsDir = '/nas/wp-metrics-test1/';
$malwareReportsDir = '/nas/metrics/public_html/malware-reports/';
$sites = [];

if (is_dir($metricsDir)) {
    foreach (glob($metricsDir . '*.json') as $file) {
        $json = file_get_contents($file);
        $data = json_decode($json, true);
        if ($data) {
            // Check Cloudflare criteria: hide if plan is 'none' or status is 'inactive'
            $plan = $data['cloudflare']['plan'] ?? 'none';
            $status = $data['cloudflare']['status'] ?? 'inactive';

            if (strcasecmp($plan, 'none') === 0 || strcasecmp($status, 'inactive') === 0) {
                continue; // Skip this site entirely
            }

            // Filter out 'twentytwentyfive' theme and recalculate theme counts
            if (isset($data['themes']['items']) && is_array($data['themes']['items'])) {
                $filteredThemes = [];
                $themeUpdatesAvailable = 0;

                foreach ($data['themes']['items'] as $theme) {
                    if (strcasecmp($theme['name'] ?? '', 'twentytwentyfive') !== 0) {
                        $filteredThemes[] = $theme;
                        if (($theme['update'] ?? 'none') === 'available') {
                            $themeUpdatesAvailable++;
                        }
                    }
                }
                $data['themes']['items'] = $filteredThemes;
                $data['themes']['total'] = count($filteredThemes);
                $data['themes']['updates_available'] = $themeUpdatesAvailable;
            }

            // Check Wordfence malware CSV report status
            $vhostSlug = basename($file, '.json');
            $jsonSiteKey = $data['site'] ?? '';

            $csvFile = '';
            $candidate1 = $malwareReportsDir . $vhostSlug . '.csv';
            $candidate2 = !empty($jsonSiteKey) ? $malwareReportsDir . $jsonSiteKey . '.csv' : '';

            if (!empty($candidate1) && file_exists($candidate1)) {
                $csvFile = $candidate1;
            } elseif (!empty($candidate2) && file_exists($candidate2)) {
                $csvFile = $candidate2;
            }

            $hasWfIssues = false;
            if (!empty($csvFile) && file_exists($csvFile)) {
                $csvRows = [];
                if (($handle = fopen($csvFile, "r")) !== FALSE) {
                    while (($row = fgetcsv($handle, 1000, ",")) !== FALSE) {
                        // Filter out empty rows/lines
                        if (!empty(array_filter($row))) {
                            $csvRows[] = $row;
                        }
                    }
                    fclose($handle);
                }
                // If there is more than 1 non-empty row (e.g., header + threats)
                if (count($csvRows) > 0) {
                    $hasWfIssues = true;
                }
            }
            $data['_wf_has_issues'] = $hasWfIssues;

            // Calculate JSON file age
            $fileMTime = filemtime($file);
            $ageSeconds = time() - $fileMTime;
            $data['_is_outdated'] = ($ageSeconds > 86400); // Older than 1 day

            // Format a friendly age string
            if ($ageSeconds < 3600) {
                $data['_file_age'] = floor($ageSeconds / 60) . 'm ago';
            } elseif ($ageSeconds < 86400) {
                $data['_file_age'] = floor($ageSeconds / 3600) . 'h ago';
            } else {
                $days = floor($ageSeconds / 86400);
                $data['_file_age'] = $days . ($days == 1 ? 'd ago' : 'd ago');
            }

            $sites[] = $data;
        }
    }
}

// Sort sites alphabetically by domain
usort($sites, function($a, $b) {
    return strcmp($a['domain'] ?? $a['site'], $b['domain'] ?? $b['site']);
});

$totalSites = count($sites);
$totalPlugins = 0;
$updateAlerts = 0;
$proCloudflare = 0;
$totalSecurityIssues = 0;

foreach ($sites as $site) {
    $totalPlugins += $site['plugins']['total'] ?? 0;

    if ($site['_wf_has_issues'] ?? false) {
        $totalSecurityIssues++;
    }

    $hasWpUpdate = $site['wordpress']['update_available'] ?? false;
    $hasPluginUpdate = ($site['plugins']['updates_available'] ?? 0) > 0;
    $hasThemeUpdate = ($site['themes']['updates_available'] ?? 0) > 0;

    if ($hasWpUpdate || $hasPluginUpdate || $hasThemeUpdate) {
        $updateAlerts++;
    }

    if ($site['cloudflare']['is_pro_or_higher'] ?? false) {
        $proCloudflare++;
    }
}
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>WordPress Fleet Control Center</title>
    <!-- Google Fonts & Bootstrap 5 -->
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css">
    <style>
        :root {
            --bs-body-font-family: 'Plus Jakarta Sans', sans-serif;
            --bs-body-bg: #f8fafc;
        }
        body {
            font-family: var(--bs-body-font-family);
            background-color: var(--bs-body-bg);
            color: #0f172a;
        }
        .card {
            border: 1px solid #e2e8f0;
            box-shadow: 0 1px 3px 0 rgba(0, 0, 0, 0.02), 0 1px 2px -1px rgba(0, 0, 0, 0.02);
            transition: all 0.2s ease-in-out;
        }
        .card:hover {
            box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.05), 0 4px 6px -4px rgba(0, 0, 0, 0.05);
        }
        .table > :not(caption) > * > * {
            padding: 1rem 1.25rem;
        }
        .badge {
            font-weight: 500;
            padding: 0.5em 0.8em;
            letter-spacing: -0.01em;
        }
        .search-box {
            background-color: #fff;
            border: 1px solid #e2e8f0;
            border-radius: 0.75rem;
            padding: 0.5rem 1rem;
        }
        .search-box:focus-within {
            border-color: #3b82f6;
            box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.1);
        }
    </style>
</head>
<body>
    <div class="container-fluid px-4 py-5" style="max-width: 1400px;">

        <!-- Header Section -->
        <header class="mb-5 d-flex flex-column flex-md-row justify-content-between align-items-md-center gap-3">
            <div>
                <div class="d-flex align-items-center gap-2 mb-1">
                    <span class="badge bg-primary-subtle text-primary rounded-pill px-3 py-1 font-monospace small">Fleet Management</span>
                    <span class="text-muted small">• Active Environment</span>
                </div>
                <h1 class="h3 fw-bold text-dark tracking-tight mb-0">WordPress Control Center</h1>
            </div>
            <div class="d-flex align-items-center gap-3">
                <div class="search-box d-flex align-items-center gap-2">
                    <i class="bi bi-search text-muted"></i>
                    <input type="text" id="siteSearch" placeholder="Filter domains..." class="border-0 bg-transparent outline-none shadow-none" style="outline: none; width: 200px;">
                </div>
                <div class="bg-white border rounded-3 px-3 py-2 text-muted small shadow-sm">
                    <i class="bi bi-folder2-open text-primary me-1"></i> <code><?= htmlspecialchars($metricsDir) ?></code>
                </div>
            </div>
        </header>

        <!-- Modern Summary Cards -->
        <div class="row g-4 mb-5">
            <div class="col-12 col-sm-6 col-xl-3">
                <div class="card border-0 rounded-4 p-4 bg-white h-100">
                    <div class="d-flex justify-content-between align-items-start mb-3">
                        <div class="text-muted small fw-bold text-uppercase tracking-wider">Monitored Sites</div>
                        <div class="bg-primary-subtle text-primary p-2 rounded-3"><i class="bi bi-hdd-rack fs-5"></i></div>
                    </div>
                    <div class="fs-2 fw-bold text-dark mb-1"><?= $totalSites ?></div>
                    <div class="text-muted small">Active Cloudflare zones</div>
                </div>
            </div>
            <div class="col-12 col-sm-6 col-xl-3">
                <div class="card border-0 rounded-4 p-4 bg-white h-100">
                    <div class="d-flex justify-content-between align-items-start mb-3">
                        <div class="text-muted small fw-bold text-uppercase tracking-wider">Pending Updates</div>
                        <div class="bg-warning-subtle text-warning p-2 rounded-3"><i class="bi bi-exclamation-triangle fs-5"></i></div>
                    </div>
                    <div class="fs-2 fw-bold text-dark mb-1"><?= $updateAlerts ?></div>
                    <div class="text-muted small">Sites requiring attention</div>
                </div>
            </div>
            <div class="col-12 col-sm-6 col-xl-3">
                <div class="card border-0 rounded-4 p-4 bg-white h-100">
                    <div class="d-flex justify-content-between align-items-start mb-3">
                        <div class="text-muted small fw-bold text-uppercase tracking-wider">Cloudflare Pro</div>
                        <div class="bg-success-subtle text-success p-2 rounded-3"><i class="bi bi-shield-check fs-5"></i></div>
                    </div>
                    <div class="fs-2 fw-bold text-dark mb-1"><?= $proCloudflare ?></div>
                    <div class="text-muted small">Enhanced security tier</div>
                </div>
            </div>
            <div class="col-12 col-sm-6 col-xl-3">
                <div class="card border-0 rounded-4 p-4 bg-white h-100">
                    <div class="d-flex justify-content-between align-items-start mb-3">
                        <div class="text-muted small fw-bold text-uppercase tracking-wider">Security Issues</div>
                        <div class="bg-danger-subtle text-danger p-2 rounded-3"><i class="bi bi-shield-exclamation fs-5"></i></div>
                    </div>
                    <div class="fs-2 fw-bold text-dark mb-1"><?= $totalSecurityIssues ?></div>
                    <div class="text-muted small">Sites flagged by Wordfence</div>
                </div>
            </div>
        </div>

        <!-- Sites Table Card -->
        <div class="card border-0 rounded-4 overflow-hidden bg-white shadow-sm">
            <div class="card-body p-0">
                <div class="table-responsive">
                    <table class="table table-hover align-middle mb-0" id="sitesTable">
                        <thead class="bg-light text-uppercase fs-7 text-muted border-bottom">
                            <tr>
                                <th class="ps-4 py-3">Domain</th>
                                <th class="py-3">WP Version</th>
                                <th class="py-3">Cloudflare Plan</th>
                                <th class="py-3">Wordfence</th>
                                <th class="py-3">Report Health</th>
                                <th class="py-3">Updates</th>
                                <th class="text-end pe-4 py-3">Action</th>
                            </tr>
                        </thead>
                        <tbody>
                            <?php if (empty($sites)): ?>
                                <tr>
                                    <td colspan="7" class="text-center py-5 text-muted">
                                        <div class="py-4">
                                            <i class="bi bi-folder-x fs-1 text-secondary opacity-50 mb-3 d-block"></i>
                                            <p class="mb-0 fw-medium">No active Cloudflare metric JSON reports found in <code><?= htmlspecialchars($metricsDir) ?></code>.</p>
                                        </div>
                                    </td>
                                </tr>
                            <?php else: ?>
                                <?php foreach ($sites as $site): ?>
                                    <tr class="site-row">
                                        <td class="ps-4">
                                            <div class="fw-bold text-dark fs-6 site-domain"><?= htmlspecialchars($site['domain'] ?? $site['site']) ?></div>
                                        </td>
                                        <td>
                                            <?php
                                                $wpVersion = $site['wordpress']['version'] ?? 'Unknown';
                                                $wpUpdates = $site['wordpress']['updates'] ?? [];
                                            ?>
                                            <div class="d-flex align-items-center gap-2">
                                                <span class="badge bg-light text-dark border font-monospace"><?= htmlspecialchars($wpVersion) ?></span>
                                                <?php if (empty($wpUpdates)): ?>
                                                    <span class="badge bg-success-subtle text-success rounded-pill px-2 py-0.5" style="font-size: 0.7rem;">Latest</span>
                                                <?php endif; ?>
                                            </div>
                                        </td>
                                        <td>
                                            <?php
                                                $rawPlan = $site['cloudflare']['plan'] ?? 'Free';
                                                $plan = trim(str_ireplace('Website', '', $rawPlan));
                                                $status = $site['cloudflare']['status'] ?? 'inactive';

                                                $badgeClass = (strcasecmp($plan, 'Free') === 0) ? 'bg-primary' : 'bg-success';
                                            ?>
                                            <div class="d-flex align-items-center gap-1">
                                                <span class="badge <?= $badgeClass ?> rounded-pill px-2.5"><?= htmlspecialchars($plan) ?></span>
                                                <span class="text-muted small font-monospace" style="font-size: 0.75rem;">(<?= htmlspecialchars($status) ?>)</span>
                                            </div>
                                        </td>
                                        <td>
                                            <?php if ($site['_wf_has_issues']): ?>
                                                <span class="badge bg-danger-subtle text-danger border border-danger-subtle rounded-pill px-2.5 py-1">
                                                    <i class="bi bi-exclamation-triangle-fill me-1"></i> Issues Found
                                                </span>
                                            <?php else: ?>
                                                <span class="badge bg-success-subtle text-success border border-success-subtle rounded-pill px-2.5 py-1">
                                                    <i class="bi bi-check-circle-fill me-1"></i> Clean
                                                </span>
                                            <?php endif; ?>
                                        </td>
                                        <td>
                                            <?php if ($site['_is_outdated']): ?>
                                                <span class="badge bg-danger-subtle text-danger rounded-pill px-2.5 py-1" title="Generated <?= htmlspecialchars($site['_file_age']) ?>">
                                                    <i class="bi bi-clock-history me-1"></i> Outdated (<?= htmlspecialchars($site['_file_age']) ?>)
                                                </span>
                                            <?php else: ?>
                                                <span class="badge bg-success-subtle text-success rounded-pill px-2.5 py-1">
                                                    <i class="bi bi-check-circle-fill me-1" style="font-size: 0.65rem;"></i> Fresh (<?= htmlspecialchars($site['_file_age']) ?>)
                                                </span>
                                            <?php endif; ?>
                                        </td>
                                        <td>
                                            <?php
                                                $needsUpdate = ($site['wordpress']['update_available'] ?? false) ||
                                                             ($site['plugins']['updates_available'] ?? 0) > 0 ||
                                                             ($site['themes']['updates_available'] ?? 0) > 0;
                                            ?>
                                            <?php if ($needsUpdate): ?>
                                                <span class="badge bg-warning-subtle text-warning-emphasis border border-warning-subtle rounded-pill px-2.5 py-1">
                                                    <i class="bi bi-exclamation-triangle-fill me-1" style="font-size: 0.65rem;"></i> Action Required
                                                </span>
                                            <?php else: ?>
                                                <span class="badge bg-light text-muted border rounded-pill px-2.5 py-1">
                                                    <i class="bi bi-check me-1"></i> Up to date
                                                </span>
                                            <?php endif; ?>
                                        </td>
                                        <td class="text-end pe-4">
                                            <a href="site.php?site=<?= urlencode($site['site']) ?>" class="btn btn-sm btn-light border fw-semibold rounded-pill px-3 shadow-none hover-shadow transition">
                                                Manage <i class="bi bi-arrow-right ms-1 text-primary"></i>
                                            </a>
                                        </td>
                                    </tr>
                                <?php endforeach; ?>
                            <?php endif; ?>
                        </tbody>
                    </table>
                </div>
            </div>
        </div>
    </div>

    <!-- Live Table Filter Script -->
    <script>
        document.getElementById('siteSearch').addEventListener('input', function(e) {
            let term = e.target.value.toLowerCase();
            let rows = document.querySelectorAll('.site-row');
            rows.forEach(row => {
                let domain = row.querySelector('.site-domain').textContent.toLowerCase();
                row.style.display = domain.includes(term) ? '' : 'none';
            });
        });
    </script>
</body>
</html>