<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('GET');
$authUser = bc_auth_user_or_fail();

$sinceId = isset($_GET['sinceId']) ? (int)$_GET['sinceId'] : 0;
$limit = isset($_GET['limit']) ? (int)$_GET['limit'] : 100;
if ($limit < 1) {
    $limit = 1;
}
if ($limit > 200) {
    $limit = 200;
}

$stmt = bc_pdo()->prepare(
    'SELECT
         e.id,
         e.call_session_id,
         e.event_type,
         e.payload_json,
         e.created_at,
         cs.caller_user_id,
         cs.callee_user_id,
         cs.kind,
         cs.status,
         cs.preferences_json,
         cs.answered_at,
         cs.ended_at,
         cs.created_at AS call_created_at
     FROM call_signal_events e
     INNER JOIN call_sessions cs ON cs.id = e.call_session_id
     WHERE e.recipient_user_id = :recipient_user_id
       AND e.id > :since_id
     ORDER BY e.id ASC
     LIMIT :limit_rows'
);
$stmt->bindValue(':recipient_user_id', (int)$authUser['id'], PDO::PARAM_INT);
$stmt->bindValue(':since_id', $sinceId, PDO::PARAM_INT);
$stmt->bindValue(':limit_rows', $limit, PDO::PARAM_INT);
$stmt->execute();

$rows = $stmt->fetchAll();
$signals = [];
$maxId = $sinceId;

foreach ($rows as $row) {
    $id = (int)$row['id'];
    if ($id > $maxId) {
        $maxId = $id;
    }

    $payloadJson = trim((string)($row['payload_json'] ?? ''));
    $decodedPayload = null;
    if ($payloadJson !== '') {
        $parsed = json_decode($payloadJson, true);
        if (is_array($parsed)) {
            $decodedPayload = $parsed;
        }
    }

    $signals[] = [
        'id' => $id,
        'callId' => (int)$row['call_session_id'],
        'type' => (string)$row['event_type'],
        'payload' => $decodedPayload,
        'createdAtUtc' => (string)$row['created_at'],
        'call' => bc_call_summary_payload(
            [
                'id' => $row['call_session_id'],
                'caller_user_id' => $row['caller_user_id'],
                'callee_user_id' => $row['callee_user_id'],
                'kind' => $row['kind'],
                'status' => $row['status'],
                'preferences_json' => $row['preferences_json'],
                'answered_at' => $row['answered_at'],
                'ended_at' => $row['ended_at'],
                'created_at' => $row['call_created_at'],
            ],
            (int)$authUser['id']
        ),
    ];
}

bc_json([
    'ok' => true,
    'status' => 'ok',
    'sinceId' => $sinceId,
    'nextSinceId' => $maxId,
    'signals' => $signals,
]);
