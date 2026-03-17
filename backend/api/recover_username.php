<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$payload = bc_read_json_body();
$recoveryEmail = trim((string)($payload['recoveryEmail'] ?? ''));

if (!bc_validate_email($recoveryEmail)) {
    bc_fail('invalid_recovery_email', 'Recovery email is invalid.', 400);
}

$stmt = bc_pdo()->prepare(
    'SELECT username
     FROM users
     WHERE LOWER(recovery_email) = :recovery_email
     LIMIT 1'
);
$stmt->execute([':recovery_email' => strtolower($recoveryEmail)]);
$row = $stmt->fetch();

if (!$row) {
    bc_json([
        'ok' => true,
        'status' => 'not_found',
        'username' => null,
    ]);
}

bc_json([
    'ok' => true,
    'status' => 'found',
    'username' => $row['username'],
]);
