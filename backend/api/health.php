<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

try {
    $pdo = bc_pdo();
    $stmt = $pdo->query('SELECT UTC_TIMESTAMP() AS utc_now');
    $row = $stmt->fetch();

    $requiredTables = [
        'users',
        'sessions',
        'contacts',
        'messages',
        'oauth_pending_states',
        'oauth_identities',
        'call_sessions',
        'call_signal_events',
    ];
    $missingTables = [];
    foreach ($requiredTables as $table) {
        try {
            $pdo->query("SELECT 1 FROM {$table} LIMIT 1");
        } catch (Throwable $e) {
            $missingTables[] = $table;
        }
    }

    $schemaReady = count($missingTables) === 0;

    bc_json([
        'ok' => $schemaReady,
        'status' => $schemaReady ? 'healthy' : 'schema_incomplete',
        'serverTimeUtc' => $row['utc_now'] ?? null,
        'schemaReady' => $schemaReady,
        'missingTables' => $missingTables,
    ]);
} catch (Throwable $e) {
    bc_fail('unhealthy', 'Database health check failed.', 500);
}
