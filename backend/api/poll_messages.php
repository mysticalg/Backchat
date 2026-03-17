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
    'SELECT m.id, m.ciphertext, m.created_at, u.username AS from_username, u.normalized_username AS from_normalized_username
     FROM messages m
     INNER JOIN users u ON u.id = m.sender_user_id
     WHERE m.recipient_user_id = :recipient_user_id
       AND m.id > :since_id
     ORDER BY m.id ASC
     LIMIT :limit_rows'
);
$stmt->bindValue(':recipient_user_id', (int)$authUser['id'], PDO::PARAM_INT);
$stmt->bindValue(':since_id', $sinceId, PDO::PARAM_INT);
$stmt->bindValue(':limit_rows', $limit, PDO::PARAM_INT);
$stmt->execute();

$rows = $stmt->fetchAll();
$messages = [];
$maxId = $sinceId;

foreach ($rows as $row) {
    $id = (int)$row['id'];
    if ($id > $maxId) {
        $maxId = $id;
    }
    $messages[] = [
        'id' => $id,
        'fromUserId' => 'username:' . $row['from_normalized_username'],
        'fromUsername' => $row['from_username'],
        'cipherText' => $row['ciphertext'],
        'sentAtUtc' => $row['created_at'],
    ];
}

bc_json([
    'ok' => true,
    'status' => 'ok',
    'sinceId' => $sinceId,
    'nextSinceId' => $maxId,
    'messages' => $messages,
]);
