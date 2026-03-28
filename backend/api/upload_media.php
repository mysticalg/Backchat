<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

const BC_MEDIA_MAX_BYTES = 8 * 1024 * 1024;
const BC_MEDIA_ALLOWED_MIME_TYPES = [
    'image/gif' => 'gif',
    'image/jpeg' => 'image',
    'image/png' => 'image',
    'image/webp' => 'image',
];

function bc_media_server_upload_limit_bytes(): int
{
    $limits = array_filter([
        bc_ini_size_to_bytes((string)ini_get('post_max_size')),
        bc_ini_size_to_bytes((string)ini_get('upload_max_filesize')),
        BC_MEDIA_MAX_BYTES,
    ], static fn(int $value): bool => $value > 0);

    if (empty($limits)) {
        return BC_MEDIA_MAX_BYTES;
    }
    return min($limits);
}

function bc_media_normalize_mime_type(string $value): string
{
    $normalized = strtolower(trim($value));
    if ($normalized === 'image/jpg') {
        return 'image/jpeg';
    }
    return $normalized;
}

function bc_media_sanitized_original_name(?string $value): ?string
{
    $name = trim((string)$value);
    if ($name === '') {
        return null;
    }

    $basename = basename(str_replace('\\', '/', $name));
    $basename = preg_replace('/[[:cntrl:]]+/', '', $basename) ?? '';
    $basename = trim($basename);
    if ($basename === '') {
        return null;
    }

    return substr($basename, 0, 255);
}

function bc_media_fail_for_upload_error(int $errorCode): void
{
    $serverLimitBytes = bc_media_server_upload_limit_bytes();
    $serverLimitMb = max(1, (int)floor($serverLimitBytes / (1024 * 1024)));

    switch ($errorCode) {
        case UPLOAD_ERR_INI_SIZE:
        case UPLOAD_ERR_FORM_SIZE:
            bc_fail(
                'upload_too_large',
                'That GIF or image exceeds the server upload limit of about ' . $serverLimitMb . ' MB.',
                413
            );
        case UPLOAD_ERR_PARTIAL:
            bc_fail('upload_incomplete', 'The GIF or image upload was interrupted. Please try again.', 400);
        case UPLOAD_ERR_NO_FILE:
            bc_fail('upload_missing', 'No GIF or image file was attached.', 400);
        default:
            bc_fail('upload_failed', 'Could not receive the GIF or image upload.', 500);
    }
}

function bc_media_detect_mime_type(string $path, string $fallback): string
{
    $detected = '';
    if (class_exists('finfo')) {
        $finfo = new finfo(FILEINFO_MIME_TYPE);
        $result = $finfo->file($path);
        if (is_string($result)) {
            $detected = bc_media_normalize_mime_type($result);
        }
    }

    if ($detected !== '' && $detected !== 'application/octet-stream') {
        return $detected;
    }
    return bc_media_normalize_mime_type($fallback);
}

bc_require_method('POST');
$authUser = bc_auth_user_or_fail();
bc_ensure_message_media_table();

$contentLength = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
$serverLimitBytes = bc_media_server_upload_limit_bytes();
if ($contentLength > 0 && empty($_FILES) && $contentLength > $serverLimitBytes) {
    $serverLimitMb = max(1, (int)floor($serverLimitBytes / (1024 * 1024)));
    bc_fail(
        'upload_too_large',
        'That GIF or image exceeds the server upload limit of about ' . $serverLimitMb . ' MB.',
        413
    );
}

$file = $_FILES['file'] ?? null;
if (!is_array($file)) {
    bc_fail('upload_missing', 'No GIF or image file was attached.', 400);
}

$errorCode = (int)($file['error'] ?? UPLOAD_ERR_NO_FILE);
if ($errorCode !== UPLOAD_ERR_OK) {
    bc_media_fail_for_upload_error($errorCode);
}

$tmpName = trim((string)($file['tmp_name'] ?? ''));
if ($tmpName === '' || !is_file($tmpName)) {
    bc_fail('upload_missing', 'The uploaded GIF or image could not be read.', 400);
}

$bytes = file_get_contents($tmpName);
if (!is_string($bytes) || $bytes === '') {
    bc_fail('upload_missing', 'The uploaded GIF or image could not be read.', 400);
}

$byteSize = strlen($bytes);
if ($byteSize > BC_MEDIA_MAX_BYTES) {
    bc_fail('upload_too_large', 'That GIF or image is too large to send. Try one under 8 MB.', 413);
}

$declaredMimeType = trim((string)($_POST['mimeType'] ?? ''));
$mimeType = bc_media_detect_mime_type($tmpName, $declaredMimeType);
$mediaKind = BC_MEDIA_ALLOWED_MIME_TYPES[$mimeType] ?? null;
if ($mediaKind === null) {
    bc_fail(
        'unsupported_media_type',
        'Only GIF, JPEG, PNG, and WebP image uploads are supported right now.',
        415
    );
}

$originalName = bc_media_sanitized_original_name(
    (string)($_POST['filename'] ?? ($file['name'] ?? ''))
);
$mediaKey = bc_secure_random_token(24);

$insert = bc_pdo()->prepare(
    'INSERT INTO message_media
     (owner_user_id, media_key, media_kind, mime_type, original_name, byte_size, blob_data, created_at)
     VALUES
     (:owner_user_id, :media_key, :media_kind, :mime_type, :original_name, :byte_size, :blob_data, UTC_TIMESTAMP())'
);

try {
    $insert->execute([
        ':owner_user_id' => (int)$authUser['id'],
        ':media_key' => $mediaKey,
        ':media_kind' => $mediaKind,
        ':mime_type' => $mimeType,
        ':original_name' => $originalName,
        ':byte_size' => $byteSize,
        ':blob_data' => $bytes,
    ]);
} catch (Throwable $e) {
    bc_fail('upload_failed', 'Could not store that GIF or image right now.', 500);
}

$publicUrl = bc_script_url('media.php', ['key' => $mediaKey]);

bc_json([
    'ok' => true,
    'status' => 'uploaded',
    'media' => [
        'url' => $publicUrl,
        'mimeType' => $mimeType,
        'kind' => $mediaKind,
        'sizeBytes' => $byteSize,
    ],
]);
