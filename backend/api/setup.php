<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

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
    bc_json([
        'ok' => true,
        'status' => 'schema_ready',
        'message' => 'Database schema created or already up to date.',
    ]);
} catch (Throwable $e) {
    bc_fail('setup_failed', 'Schema setup failed: ' . $e->getMessage(), 500);
}
