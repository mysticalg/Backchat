<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('GET');
$authUser = bc_auth_user_or_fail();

$stmt = bc_pdo()->prepare(
    'SELECT
         u.id,
         u.username,
         u.normalized_username,
         u.avatar_url,
         u.quote_text,
         MAX(s.last_seen_at) AS last_seen_at,
         CASE
             WHEN MAX(s.last_seen_at) >= DATE_SUB(UTC_TIMESTAMP(), INTERVAL 45 SECOND)
                 THEN "online"
             ELSE "offline"
         END AS status
     FROM contacts c
     INNER JOIN users u ON u.id = c.contact_user_id
     LEFT JOIN sessions s
         ON s.user_id = u.id
        AND s.revoked_at IS NULL
        AND (s.expires_at IS NULL OR s.expires_at > UTC_TIMESTAMP())
     WHERE c.user_id = :user_id
     GROUP BY u.id, u.username, u.normalized_username
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
