<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

try {
    $pdo = bc_pdo();
    $stmt = $pdo->query('SELECT UTC_TIMESTAMP() AS utc_now');
    $row = $stmt->fetch();

    bc_json([
        'ok' => true,
        'status' => 'healthy',
        'serverTimeUtc' => $row['utc_now'] ?? null,
    ]);
} catch (Throwable $e) {
    bc_fail('unhealthy', 'Database health check failed.', 500);
}
