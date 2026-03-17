<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$payload = bc_read_json_body();
$state = trim((string)($payload['state'] ?? ''));

if ($state === '') {
    bc_fail('state_required', 'Missing OAuth state.', 400);
}

$stmt = bc_pdo()->prepare(
    'SELECT id, status, provider, user_id, session_token, error_code, expires_at
     FROM oauth_pending_states
     WHERE state = :state
     LIMIT 1'
);
$stmt->execute([':state' => $state]);
$row = $stmt->fetch();

if (!$row) {
    bc_fail('oauth_state_not_found', 'OAuth state was not found.', 404);
}

$expiresAt = strtotime((string)$row['expires_at']);
if ($expiresAt !== false && $expiresAt < time()) {
    bc_json([
        'ok' => true,
        'status' => 'expired',
        'provider' => $row['provider'],
    ]);
}

$status = (string)$row['status'];
if ($status === 'pending') {
    bc_json([
        'ok' => true,
        'status' => 'pending',
        'provider' => $row['provider'],
    ]);
}

if ($status === 'failed') {
    bc_json([
        'ok' => true,
        'status' => 'failed',
        'provider' => $row['provider'],
        'error' => (string)($row['error_code'] ?? ''),
    ]);
}

$userId = (int)($row['user_id'] ?? 0);
$token = trim((string)($row['session_token'] ?? ''));
if ($userId <= 0 || $token === '') {
    bc_fail('oauth_not_ready', 'OAuth session completed without credentials.', 500);
}

$userRow = bc_load_user_row_by_id($userId);
$userPayload = bc_enriched_user_payload($userRow);

bc_json([
    'ok' => true,
    'status' => 'authorized',
    'provider' => $row['provider'],
    'token' => $token,
    'user' => $userPayload,
]);
