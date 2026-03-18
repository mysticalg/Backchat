<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$authUser = bc_auth_user_or_fail();
$payload = bc_read_json_body();

$callId = (int)($payload['callId'] ?? 0);
$type = trim((string)($payload['type'] ?? ''));
$signalPayload = is_array($payload['payload'] ?? null) ? $payload['payload'] : null;

if ($callId < 1) {
    bc_fail('invalid_call_id', 'callId must be a positive integer.', 400);
}
if (!bc_call_signal_type_is_valid($type) || $type === 'offer') {
    bc_fail('invalid_call_signal', 'Unsupported call signal type.', 400);
}

$callSession = bc_call_session_for_user_or_fail($callId, (int)$authUser['id']);
$recipientUserId = bc_call_other_participant_user_id($callSession, (int)$authUser['id']);

if ($type === 'answer') {
    $description = is_array($signalPayload['description'] ?? null) ? $signalPayload['description'] : null;
    $answerType = trim((string)($description['type'] ?? ''));
    $answerSdp = trim((string)($description['sdp'] ?? ''));
    if ($answerType !== 'answer' || $answerSdp === '') {
        bc_fail('invalid_answer', 'Answer must include type=answer and a non-empty SDP.', 400);
    }
    $update = bc_pdo()->prepare(
        'UPDATE call_sessions
         SET status = "active",
             answered_at = COALESCE(answered_at, UTC_TIMESTAMP()),
             updated_at = UTC_TIMESTAMP()
         WHERE id = :id'
    );
    $update->execute([':id' => $callId]);
} elseif ($type === 'candidate') {
    $candidate = trim((string)($signalPayload['candidate'] ?? ''));
    if ($candidate === '') {
        bc_fail('invalid_candidate', 'Candidate signal must include a candidate string.', 400);
    }
} elseif ($type === 'ringing') {
    // No state transition needed; the recipient has seen the call.
} else {
    $status = match ($type) {
        'rejected' => 'rejected',
        'busy' => 'busy',
        'ended' => ((string)$callSession['status']) === 'ringing' ? 'cancelled' : 'ended',
        default => 'failed',
    };
    $update = bc_pdo()->prepare(
        'UPDATE call_sessions
         SET status = :status,
             ended_at = COALESCE(ended_at, UTC_TIMESTAMP()),
             updated_at = UTC_TIMESTAMP()
         WHERE id = :id'
    );
    $update->execute([
        ':id' => $callId,
        ':status' => $status,
    ]);
}

$eventId = bc_call_insert_event(
    $callId,
    (int)$authUser['id'],
    $recipientUserId,
    $type,
    $signalPayload
);
$freshSession = bc_call_session_for_user_or_fail($callId, (int)$authUser['id']);

bc_json([
    'ok' => true,
    'status' => 'ok',
    'eventId' => $eventId,
    'call' => bc_call_summary_payload($freshSession, (int)$authUser['id']),
]);
