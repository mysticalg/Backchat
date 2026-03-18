<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
$authUser = bc_auth_user_or_fail();

if ($method === 'GET') {
    bc_json([
        'ok' => true,
        'status' => 'ok',
        'user' => bc_enriched_user_payload(bc_load_user_row_by_id((int)$authUser['id'])),
    ]);
}

if ($method !== 'POST') {
    bc_fail('method_not_allowed', 'Invalid request method.', 405);
}

$payload = bc_read_json_body();
$avatarUrl = trim((string)($payload['avatarUrl'] ?? ''));
$quote = trim((string)($payload['quote'] ?? ''));

$quoteLength = function_exists('mb_strlen') ? mb_strlen($quote, 'UTF-8') : strlen($quote);
if ($quoteLength > 160) {
    bc_fail('invalid_quote', 'Quote must be 160 characters or fewer.', 400);
}

if ($avatarUrl !== '') {
    $isDataImage = strpos($avatarUrl, 'data:image/') === 0;
    $isRemoteUrl = filter_var($avatarUrl, FILTER_VALIDATE_URL) !== false
        && preg_match('#^https?://#i', $avatarUrl) === 1;

    if (!$isDataImage && !$isRemoteUrl) {
        bc_fail('invalid_avatar_url', 'Avatar must be an https URL or image data URI.', 400);
    }
    if ($isDataImage && strlen($avatarUrl) > 524288) {
        bc_fail('avatar_too_large', 'Avatar image data is too large.', 400);
    }
    if (!$isDataImage && strlen($avatarUrl) > 2048) {
        bc_fail('avatar_too_large', 'Avatar URL is too long.', 400);
    }
}

$stmt = bc_pdo()->prepare(
    'UPDATE users
     SET avatar_url = :avatar_url,
         quote_text = :quote_text
     WHERE id = :user_id'
);
$stmt->execute([
    ':user_id' => (int)$authUser['id'],
    ':avatar_url' => $avatarUrl === '' ? null : $avatarUrl,
    ':quote_text' => $quote === '' ? null : $quote,
]);

bc_json([
    'ok' => true,
    'status' => 'updated',
    'user' => bc_enriched_user_payload(bc_load_user_row_by_id((int)$authUser['id'])),
]);
