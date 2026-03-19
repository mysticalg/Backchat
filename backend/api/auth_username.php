<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$payload = bc_read_json_body();

$username = trim((string)($payload['username'] ?? ''));
$recoveryEmail = trim((string)($payload['recoveryEmail'] ?? ''));
$password = (string)($payload['password'] ?? '');

if (!bc_validate_username($username)) {
    bc_fail('invalid_username', 'Username must be 3-24 letters/numbers/underscore.', 400);
}

$normalized = bc_normalize_username($username);
$pdo = bc_pdo();

$findUser = $pdo->prepare(
    'SELECT id, username, normalized_username, recovery_email, password_hash, avatar_url, quote_text
     FROM users
     WHERE normalized_username = :normalized_username
     LIMIT 1'
);
$findUser->execute([':normalized_username' => $normalized]);
$existingUser = $findUser->fetch();

if ($existingUser) {
    $storedPasswordHash = trim((string)($existingUser['password_hash'] ?? ''));
    if ($storedPasswordHash !== '') {
        if ($password === '') {
            bc_fail('password_required', 'Enter your password to sign in to this username.', 401);
        }
        if (!bc_validate_password($password)) {
            bc_fail('invalid_password', 'Password must be 8-72 characters.', 400);
        }
        if (!bc_password_verify_value($password, $storedPasswordHash)) {
            bc_fail('password_incorrect', 'Password is incorrect for this username.', 401);
        }
        if (password_needs_rehash($storedPasswordHash, PASSWORD_DEFAULT)) {
            $refreshPassword = $pdo->prepare(
                'UPDATE users
                 SET password_hash = :password_hash, password_updated_at = UTC_TIMESTAMP()
                 WHERE id = :id'
            );
            $refreshPassword->execute([
                ':id' => (int)$existingUser['id'],
                ':password_hash' => bc_password_hash_value($password),
            ]);
        }
    } elseif ($password !== '') {
        if (!bc_validate_password($password)) {
            bc_fail('invalid_password', 'Password must be 8-72 characters.', 400);
        }
        if ($recoveryEmail === '') {
            bc_fail(
                'password_setup_needs_recovery_email',
                'Add your recovery email to secure this username with a password.',
                400
            );
        }
        if (strtolower($recoveryEmail) !== strtolower((string)$existingUser['recovery_email'])) {
            bc_fail(
                'recovery_email_mismatch',
                'Recovery email does not match this username, so the password was not changed.',
                403
            );
        }
        $setPassword = $pdo->prepare(
            'UPDATE users
             SET password_hash = :password_hash, password_updated_at = UTC_TIMESTAMP()
             WHERE id = :id'
        );
        $setPassword->execute([
            ':id' => (int)$existingUser['id'],
            ':password_hash' => bc_password_hash_value($password),
        ]);
        $existingUser['password_hash'] = '[set]';
        $token = bc_issue_session_token((int)$existingUser['id']);
        bc_json([
            'ok' => true,
            'status' => 'password_set',
            'token' => $token,
            'user' => bc_user_payload($existingUser),
        ]);
    }

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
if ($password !== '' && !bc_validate_password($password)) {
    bc_fail('invalid_password', 'Password must be 8-72 characters.', 400);
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
        'INSERT INTO users (
             username, normalized_username, recovery_email, password_hash, password_updated_at, avatar_url, quote_text, created_at
         )
         VALUES (
             :username, :normalized_username, :recovery_email, :password_hash, :password_updated_at, NULL, NULL, UTC_TIMESTAMP()
         )'
    );
    $passwordHash = $password !== '' ? bc_password_hash_value($password) : null;
    $insert->execute([
        ':username' => $username,
        ':normalized_username' => $normalized,
        ':recovery_email' => $recoveryEmail,
        ':password_hash' => $passwordHash,
        ':password_updated_at' => $passwordHash !== null ? gmdate('Y-m-d H:i:s') : null,
    ]);
} catch (Throwable $e) {
    bc_fail('username_taken', 'Username was just claimed. Try signing in again.', 409);
}

$findCreated = $pdo->prepare(
    'SELECT id, username, normalized_username, recovery_email, password_hash, avatar_url, quote_text
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
