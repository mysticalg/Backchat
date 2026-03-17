<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('GET');
$authUser = bc_auth_user_or_fail();

$stmt = bc_pdo()->prepare(
    'SELECT u.id, u.username, u.normalized_username
     FROM contacts c
     INNER JOIN users u ON u.id = c.contact_user_id
     WHERE c.user_id = :user_id
     ORDER BY u.username ASC'
);
$stmt->execute([':user_id' => (int)$authUser['id']]);
$rows = $stmt->fetchAll();

$contacts = [];
foreach ($rows as $row) {
    $contacts[] = bc_user_payload($row);
}

bc_json([
    'ok' => true,
    'status' => 'ok',
    'contacts' => $contacts,
]);
