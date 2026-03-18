<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$authUser = bc_auth_user_or_fail();
$payload = bc_read_json_body();

$toUsername = trim((string)($payload['toUsername'] ?? ''));
$kind = trim((string)($payload['kind'] ?? 'audio'));
$offer = $payload['offer'] ?? null;
$settings = bc_call_preferences_sanitize(
    is_array($payload['settings'] ?? null) ? $payload['settings'] : []
);

if ($toUsername === '' || !bc_validate_username($toUsername)) {
    bc_fail('invalid_recipient', 'Recipient username is invalid.', 400);
}
if (!bc_call_type_is_valid($kind)) {
    bc_fail('invalid_call_kind', 'Call kind must be audio or video.', 400);
}
if (!is_array($offer)) {
    bc_fail('invalid_offer', 'Offer payload is required.', 400);
}

$offerType = trim((string)($offer['type'] ?? ''));
$offerSdp = trim((string)($offer['sdp'] ?? ''));
if ($offerType !== 'offer' || $offerSdp === '') {
    bc_fail('invalid_offer', 'Offer must include type=offer and a non-empty SDP.', 400);
}

$recipient = bc_find_contact_user_or_fail((int)$authUser['id'], $toUsername);
if ((int)$recipient['id'] === (int)$authUser['id']) {
    bc_fail('invalid_recipient', 'Cannot start a call with yourself.', 409);
}

$activeCheck = bc_pdo()->prepare(
    'SELECT id
     FROM call_sessions
     WHERE status IN ("ringing", "active")
       AND (
           (caller_user_id = :caller_user_id AND callee_user_id = :callee_user_id)
           OR
           (caller_user_id = :callee_user_id AND callee_user_id = :caller_user_id)
       )
     LIMIT 1'
);
$activeCheck->execute([
    ':caller_user_id' => (int)$authUser['id'],
    ':callee_user_id' => (int)$recipient['id'],
]);
if ($activeCheck->fetch()) {
    bc_fail('call_in_progress', 'A call with this contact is already in progress.', 409);
}

$preferencesJson = json_encode($settings, JSON_UNESCAPED_SLASHES);
$insert = bc_pdo()->prepare(
    'INSERT INTO call_sessions
     (caller_user_id, callee_user_id, kind, status, preferences_json, created_at, updated_at)
     VALUES
     (:caller_user_id, :callee_user_id, :kind, "ringing", :preferences_json, UTC_TIMESTAMP(), UTC_TIMESTAMP())'
);
$insert->execute([
    ':caller_user_id' => (int)$authUser['id'],
    ':callee_user_id' => (int)$recipient['id'],
    ':kind' => $kind,
    ':preferences_json' => $preferencesJson,
]);
$callId = (int)bc_pdo()->lastInsertId();

$eventId = bc_call_insert_event(
    $callId,
    (int)$authUser['id'],
    (int)$recipient['id'],
    'offer',
    [
        'description' => [
            'type' => $offerType,
            'sdp' => $offerSdp,
        ],
    ]
);

$callSession = bc_call_session_for_user_or_fail($callId, (int)$authUser['id']);

bc_json([
    'ok' => true,
    'status' => 'ringing',
    'call' => bc_call_summary_payload($callSession, (int)$authUser['id']),
    'eventId' => $eventId,
]);
