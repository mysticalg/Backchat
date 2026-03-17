<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$authUser = bc_auth_user_or_fail();
$payload = bc_read_json_body();

$toUsername = trim((string)($payload['toUsername'] ?? ''));
$cipherText = trim((string)($payload['cipherText'] ?? ''));
$clientMessageId = trim((string)($payload['clientMessageId'] ?? ''));

if ($toUsername === '' || !bc_validate_username($toUsername)) {
    bc_fail('invalid_recipient', 'Recipient username is invalid.', 400);
}
if ($cipherText === '') {
    bc_fail('invalid_ciphertext', 'cipherText is required.', 400);
}

$normalized = bc_normalize_username($toUsername);
$findTarget = bc_pdo()->prepare(
    'SELECT id, username, normalized_username
     FROM users
     WHERE normalized_username = :normalized_username
     LIMIT 1'
);
$findTarget->execute([':normalized_username' => $normalized]);
$recipient = $findTarget->fetch();

if (!$recipient) {
    bc_fail('not_found', 'Recipient username not found.', 404);
}
if ((int)$recipient['id'] === (int)$authUser['id']) {
    bc_fail('invalid_recipient', 'Cannot send message to yourself.', 409);
}

$insert = bc_pdo()->prepare(
    'INSERT INTO messages (sender_user_id, recipient_user_id, ciphertext, client_message_id, created_at)
     VALUES (:sender_user_id, :recipient_user_id, :ciphertext, :client_message_id, UTC_TIMESTAMP())'
);

try {
    $insert->execute([
        ':sender_user_id' => (int)$authUser['id'],
        ':recipient_user_id' => (int)$recipient['id'],
        ':ciphertext' => $cipherText,
        ':client_message_id' => $clientMessageId === '' ? null : $clientMessageId,
    ]);
} catch (Throwable $e) {
    bc_fail('send_failed', 'Could not store message.', 500);
}

$id = (int)bc_pdo()->lastInsertId();

bc_json([
    'ok' => true,
    'status' => 'sent',
    'messageId' => $id,
]);
