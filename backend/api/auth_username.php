<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$payload = bc_read_json_body();

$username = trim((string)($payload['username'] ?? ''));
$recoveryEmail = trim((string)($payload['recoveryEmail'] ?? ''));

if (!bc_validate_username($username)) {
    bc_fail('invalid_username', 'Username must be 3-24 letters/numbers/underscore.', 400);
}

$normalized = bc_normalize_username($username);
$pdo = bc_pdo();

$findUser = $pdo->prepare(
    'SELECT id, username, normalized_username, recovery_email, avatar_url, quote_text
     FROM users
     WHERE normalized_username = :normalized_username
     LIMIT 1'
);
$findUser->execute([':normalized_username' => $normalized]);
$existingUser = $findUser->fetch();

if ($existingUser) {
    $token = bc_issue_session_token((int)$existingUser['id']);
    bc_json([
        'ok' => true,
        'status' => 'signed_in',
        'token' => $token,
        'user' => bc_user_payload($existingUser),
    ]);
}

if ($recoveryEmail === '') {
    bc_fail('username_needs_recovery_email', 'Recovery email is required for new usernames.', 400);
}
if (!bc_validate_email($recoveryEmail)) {
    bc_fail('invalid_recovery_email', 'Recovery email is invalid.', 400);
}

$normalizedEmail = strtolower($recoveryEmail);
$findEmail = $pdo->prepare(
    'SELECT username FROM users WHERE LOWER(recovery_email) = :recovery_email LIMIT 1'
);
$findEmail->execute([':recovery_email' => $normalizedEmail]);
$emailOwner = $findEmail->fetch();
if ($emailOwner) {
    bc_fail('recovery_email_already_in_use', 'Recovery email already belongs to another username.', 409, [
        'linkedUsername' => $emailOwner['username'],
    ]);
}

try {
    $insert = $pdo->prepare(
        'INSERT INTO users (username, normalized_username, recovery_email, avatar_url, quote_text, created_at)
         VALUES (:username, :normalized_username, :recovery_email, NULL, NULL, UTC_TIMESTAMP())'
    );
    $insert->execute([
        ':username' => $username,
        ':normalized_username' => $normalized,
        ':recovery_email' => $recoveryEmail,
    ]);
} catch (Throwable $e) {
    bc_fail('username_taken', 'Username was just claimed. Try signing in again.', 409);
}

$findCreated = $pdo->prepare(
    'SELECT id, username, normalized_username, recovery_email, avatar_url, quote_text
     FROM users
     WHERE normalized_username = :normalized_username
     LIMIT 1'
);
$findCreated->execute([':normalized_username' => $normalized]);
$createdUser = $findCreated->fetch();

if (!$createdUser) {
    bc_fail('create_failed', 'Could not create user.', 500);
}

$token = bc_issue_session_token((int)$createdUser['id']);
bc_json([
    'ok' => true,
    'status' => 'created',
    'token' => $token,
    'user' => bc_user_payload($createdUser),
]);
