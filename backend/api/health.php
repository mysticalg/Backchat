<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

function bc_health_column_exists(PDO $pdo, string $tableName, string $columnName): bool
{
    $stmt = $pdo->prepare(
        'SELECT 1
         FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE()
           AND TABLE_NAME = :table_name
           AND COLUMN_NAME = :column_name
         LIMIT 1'
    );
    $stmt->execute([
        ':table_name' => $tableName,
        ':column_name' => $columnName,
    ]);
    return (bool)$stmt->fetchColumn();
}

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

    $requiredColumns = [
        'call_sessions' => ['caller_user_id', 'callee_user_id', 'kind', 'status'],
        'call_signal_events' => ['call_session_id', 'sender_user_id', 'recipient_user_id', 'event_type'],
    ];
    $missingColumns = [];
    foreach ($requiredColumns as $table => $columns) {
        foreach ($columns as $column) {
            if (!bc_health_column_exists($pdo, $table, $column)) {
                $missingColumns[] = $table . '.' . $column;
            }
        }
    }

    $schemaReady = count($missingTables) === 0 && count($missingColumns) === 0;

    bc_json([
        'ok' => $schemaReady,
        'status' => $schemaReady ? 'healthy' : 'schema_incomplete',
        'serverTimeUtc' => $row['utc_now'] ?? null,
        'schemaReady' => $schemaReady,
        'missingTables' => $missingTables,
        'missingColumns' => $missingColumns,
    ]);
} catch (Throwable $e) {
    bc_fail('unhealthy', 'Database health check failed.', 500);
}
