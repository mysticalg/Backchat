<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('GET');
bc_ensure_message_media_table();

$mediaKey = trim((string)($_GET['key'] ?? ''));
if ($mediaKey === '') {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Media not found.';
    exit;
}

$stmt = bc_pdo()->prepare(
    'SELECT mime_type, original_name, byte_size, blob_data
     FROM message_media
     WHERE media_key = :media_key
     LIMIT 1'
);
$stmt->execute([':media_key' => $mediaKey]);
$media = $stmt->fetch();

if (!$media) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Media not found.';
    exit;
}

$mimeType = trim((string)($media['mime_type'] ?? 'application/octet-stream'));
$byteSize = (int)($media['byte_size'] ?? 0);
$body = $media['blob_data'] ?? '';
if (!is_string($body)) {
    http_response_code(404);
    header('Content-Type: text/plain; charset=utf-8');
    echo 'Media not found.';
    exit;
}

$fileName = trim((string)($media['original_name'] ?? ''));
if ($fileName === '') {
    $extension = match ($mimeType) {
        'image/gif' => 'gif',
        'image/png' => 'png',
        'image/webp' => 'webp',
        default => 'jpg',
    };
    $fileName = 'backchat-media.' . $extension;
}

header('Content-Type: ' . $mimeType);
header('Content-Length: ' . ($byteSize > 0 ? $byteSize : strlen($body)));
header('Content-Disposition: inline; filename="' . rawurlencode($fileName) . '"');
header('Cache-Control: public, max-age=31536000, immutable');
header('X-Content-Type-Options: nosniff');
echo $body;
