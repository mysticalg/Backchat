<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

function bc_setup_column_exists(PDO $pdo, string $tableName, string $columnName): bool
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

function bc_setup_table_exists(PDO $pdo, string $tableName): bool
{
    $stmt = $pdo->prepare(
        'SELECT 1
         FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = DATABASE()
           AND TABLE_NAME = :table_name
         LIMIT 1'
    );
    $stmt->execute([':table_name' => $tableName]);
    return (bool)$stmt->fetchColumn();
}

function bc_setup_ensure_profile_columns(PDO $pdo): void
{
    if (!bc_setup_column_exists($pdo, 'users', 'avatar_url')) {
        $pdo->exec('ALTER TABLE users ADD COLUMN avatar_url TEXT NULL AFTER recovery_email');
    }
    if (!bc_setup_column_exists($pdo, 'users', 'quote_text')) {
        $pdo->exec('ALTER TABLE users ADD COLUMN quote_text VARCHAR(160) NULL AFTER avatar_url');
    }
}

function bc_setup_ensure_call_schema(PDO $pdo): void
{
    if (bc_setup_table_exists($pdo, 'call_sessions')) {
        if (!bc_setup_column_exists($pdo, 'call_sessions', 'preferences_json')) {
            $pdo->exec('ALTER TABLE call_sessions ADD COLUMN preferences_json TEXT NULL AFTER status');
        }
        if (!bc_setup_column_exists($pdo, 'call_sessions', 'answered_at')) {
            $pdo->exec('ALTER TABLE call_sessions ADD COLUMN answered_at DATETIME NULL AFTER preferences_json');
        }
        if (!bc_setup_column_exists($pdo, 'call_sessions', 'ended_at')) {
            $pdo->exec('ALTER TABLE call_sessions ADD COLUMN ended_at DATETIME NULL AFTER answered_at');
        }
        if (!bc_setup_column_exists($pdo, 'call_sessions', 'updated_at')) {
            $pdo->exec(
                'ALTER TABLE call_sessions
                 ADD COLUMN updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                 ON UPDATE CURRENT_TIMESTAMP
                 AFTER created_at'
            );
        }
    }

    if (bc_setup_table_exists($pdo, 'call_signal_events')) {
        if (!bc_setup_column_exists($pdo, 'call_signal_events', 'recipient_user_id')) {
            $pdo->exec(
                'ALTER TABLE call_signal_events
                 ADD COLUMN recipient_user_id BIGINT UNSIGNED NOT NULL AFTER sender_user_id'
            );
        }
        if (!bc_setup_column_exists($pdo, 'call_signal_events', 'payload_json')) {
            $pdo->exec(
                'ALTER TABLE call_signal_events
                 ADD COLUMN payload_json MEDIUMTEXT NULL AFTER event_type'
            );
        }
        if (!bc_setup_column_exists($pdo, 'call_signal_events', 'created_at')) {
            $pdo->exec(
                'ALTER TABLE call_signal_events
                 ADD COLUMN created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP AFTER payload_json'
            );
        }
    }
}

$payload = bc_read_json_body();
$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? '');
if ($method !== 'POST') {
    bc_fail('method_not_allowed', 'Invalid request method.', 405);
}
$providedKey = trim((string)($payload['setupKey'] ?? ''));

if ($providedKey === '') {
    bc_fail('setup_key_required', 'Missing setupKey.', 400);
}

$cfg = bc_config();
if (!hash_equals((string)$cfg['setup_key'], $providedKey)) {
    bc_fail('forbidden', 'Invalid setupKey.', 403);
}

$schema = file_get_contents(__DIR__ . '/schema.sql');
if ($schema === false) {
    bc_fail('schema_missing', 'schema.sql could not be read.', 500);
}

$statements = array_filter(array_map('trim', explode(';', $schema)));

try {
    $pdo = bc_pdo();
    foreach ($statements as $statement) {
        if ($statement !== '') {
            $pdo->exec($statement);
        }
    }
    bc_setup_ensure_profile_columns($pdo);
    bc_setup_ensure_call_schema($pdo);
    bc_json([
        'ok' => true,
        'status' => 'schema_ready',
        'message' => 'Database schema created or already up to date.',
    ]);
} catch (Throwable $e) {
    bc_fail('setup_failed', 'Schema setup failed: ' . $e->getMessage(), 500);
}
