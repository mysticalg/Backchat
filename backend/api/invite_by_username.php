<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$authUser = bc_auth_user_or_fail();
$payload = bc_read_json_body();
$username = trim((string)($payload['username'] ?? ''));

if (!bc_validate_username($username)) {
    bc_fail('invalid_username', 'Username must be 3-24 letters/numbers/underscore.', 400);
}

$normalized = bc_normalize_username($username);
$findTarget = bc_pdo()->prepare(
    'SELECT id, username, normalized_username
     FROM users
     WHERE normalized_username = :normalized_username
     LIMIT 1'
);
$findTarget->execute([':normalized_username' => $normalized]);
$target = $findTarget->fetch();

if (!$target) {
    bc_fail('not_found', 'Username not found.', 404);
}
if ((int)$target['id'] === (int)$authUser['id']) {
    bc_fail('self_invite', 'You cannot invite your own username.', 409);
}

$exists = bc_pdo()->prepare(
    'SELECT 1
     FROM contacts
     WHERE user_id = :user_id AND contact_user_id = :contact_user_id
     LIMIT 1'
);
$exists->execute([
    ':user_id' => (int)$authUser['id'],
    ':contact_user_id' => (int)$target['id'],
]);
if ($exists->fetch()) {
    bc_json([
        'ok' => true,
        'status' => 'already_contact',
        'contact' => bc_user_payload($target),
    ]);
}

$insert = bc_pdo()->prepare(
    'INSERT IGNORE INTO contacts (user_id, contact_user_id, created_at)
     VALUES (:user_id, :contact_user_id, UTC_TIMESTAMP())'
);
$insert->execute([
    ':user_id' => (int)$authUser['id'],
    ':contact_user_id' => (int)$target['id'],
]);
$insert->execute([
    ':user_id' => (int)$target['id'],
    ':contact_user_id' => (int)$authUser['id'],
]);

bc_json([
    'ok' => true,
    'status' => 'added',
    'contact' => bc_user_payload($target),
]);
