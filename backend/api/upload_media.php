<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

const BC_MEDIA_MAX_BYTES = 8 * 1024 * 1024;
const BC_MEDIA_CHUNK_MAX_BYTES = 4096;
const BC_MEDIA_UPLOAD_TTL_HOURS = 6;
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

function bc_media_detect_mime_type_from_bytes(string $bytes, string $fallback): string
{
    $detected = '';
    if (class_exists('finfo')) {
        $finfo = new finfo(FILEINFO_MIME_TYPE);
        $result = $finfo->buffer($bytes);
        if (is_string($result)) {
            $detected = bc_media_normalize_mime_type($result);
        }
    }

    if ($detected !== '' && $detected !== 'application/octet-stream') {
        return $detected;
    }
    return bc_media_normalize_mime_type($fallback);
}

function bc_media_cleanup_stale_uploads(): void
{
    bc_ensure_message_media_upload_tables();
    $stmt = bc_pdo()->prepare(
        'DELETE FROM message_media_uploads
         WHERE updated_at < DATE_SUB(UTC_TIMESTAMP(), INTERVAL :ttl_hours HOUR)'
    );
    $stmt->execute([':ttl_hours' => BC_MEDIA_UPLOAD_TTL_HOURS]);
}

function bc_media_upload_row_for_user_or_fail(int $authUserId, string $uploadToken): array
{
    $trimmedToken = trim($uploadToken);
    if ($trimmedToken === '') {
        bc_fail('upload_missing', 'Upload session was not provided.', 400);
    }

    $stmt = bc_pdo()->prepare(
        'SELECT *
         FROM message_media_uploads
         WHERE owner_user_id = :owner_user_id
           AND upload_token = :upload_token
         LIMIT 1'
    );
    $stmt->execute([
        ':owner_user_id' => $authUserId,
        ':upload_token' => $trimmedToken,
    ]);
    $row = $stmt->fetch();
    if (!$row) {
        bc_fail('upload_not_found', 'That upload session was not found or already expired.', 404);
    }
    return $row;
}

function bc_media_store_final_upload(
    int $authUserId,
    string $mimeType,
    ?string $originalName,
    string $bytes
): array {
    $byteSize = strlen($bytes);
    if ($byteSize <= 0) {
        bc_fail('upload_missing', 'The uploaded GIF or image could not be read.', 400);
    }
    if ($byteSize > BC_MEDIA_MAX_BYTES) {
        bc_fail('upload_too_large', 'That GIF or image is too large to send. Try one under 8 MB.', 413);
    }

    $resolvedMimeType = bc_media_detect_mime_type_from_bytes($bytes, $mimeType);
    $mediaKind = BC_MEDIA_ALLOWED_MIME_TYPES[$resolvedMimeType] ?? null;
    if ($mediaKind === null) {
        bc_fail(
            'unsupported_media_type',
            'Only GIF, JPEG, PNG, and WebP image uploads are supported right now.',
            415
        );
    }

    $mediaKey = bc_secure_random_token(24);
    $insert = bc_pdo()->prepare(
        'INSERT INTO message_media
         (owner_user_id, media_key, media_kind, mime_type, original_name, byte_size, blob_data, created_at)
         VALUES
         (:owner_user_id, :media_key, :media_kind, :mime_type, :original_name, :byte_size, :blob_data, UTC_TIMESTAMP())'
    );

    try {
        $insert->execute([
            ':owner_user_id' => $authUserId,
            ':media_key' => $mediaKey,
            ':media_kind' => $mediaKind,
            ':mime_type' => $resolvedMimeType,
            ':original_name' => $originalName,
            ':byte_size' => $byteSize,
            ':blob_data' => $bytes,
        ]);
    } catch (Throwable $e) {
        bc_fail('upload_failed', 'Could not store that GIF or image right now.', 500);
    }

    return [
        'url' => bc_script_url('media.php', ['key' => $mediaKey]),
        'mimeType' => $resolvedMimeType,
        'kind' => $mediaKind,
        'sizeBytes' => $byteSize,
    ];
}

bc_require_method('POST');
$authUser = bc_auth_user_or_fail();
bc_ensure_message_media_table();
bc_media_cleanup_stale_uploads();

$contentType = strtolower(trim((string)($_SERVER['CONTENT_TYPE'] ?? '')));
if (str_starts_with($contentType, 'application/json')) {
    bc_ensure_message_media_upload_tables();
    $payload = bc_read_json_body();
    $mode = trim((string)($payload['mode'] ?? ''));

    if ($mode === 'chunked_start') {
        $declaredMimeType = bc_media_normalize_mime_type((string)($payload['mimeType'] ?? ''));
        if (!isset(BC_MEDIA_ALLOWED_MIME_TYPES[$declaredMimeType])) {
            bc_fail(
                'unsupported_media_type',
                'Only GIF, JPEG, PNG, and WebP image uploads are supported right now.',
                415
            );
        }

        $originalName = bc_media_sanitized_original_name((string)($payload['filename'] ?? ''));
        $uploadToken = bc_secure_random_token(24);
        $insert = bc_pdo()->prepare(
            'INSERT INTO message_media_uploads
             (owner_user_id, upload_token, declared_mime_type, original_name, total_bytes, next_chunk_index, created_at, updated_at)
             VALUES
             (:owner_user_id, :upload_token, :declared_mime_type, :original_name, 0, 0, UTC_TIMESTAMP(), UTC_TIMESTAMP())'
        );
        $insert->execute([
            ':owner_user_id' => (int)$authUser['id'],
            ':upload_token' => $uploadToken,
            ':declared_mime_type' => $declaredMimeType,
            ':original_name' => $originalName,
        ]);

        bc_json([
            'ok' => true,
            'status' => 'chunked_upload_started',
            'upload' => [
                'token' => $uploadToken,
                'maxChunkBytes' => BC_MEDIA_CHUNK_MAX_BYTES,
            ],
        ]);
    }

    if ($mode === 'chunked_append') {
        $uploadToken = (string)($payload['uploadToken'] ?? '');
        $chunkBase64 = trim((string)($payload['chunkBase64'] ?? ''));
        if ($chunkBase64 === '') {
            bc_fail('upload_missing', 'The upload chunk was empty.', 400);
        }

        $chunkBytes = base64_decode($chunkBase64, true);
        if (!is_string($chunkBytes) || $chunkBytes === '') {
            bc_fail('upload_invalid', 'The upload chunk could not be decoded.', 400);
        }
        $chunkSize = strlen($chunkBytes);
        if ($chunkSize > BC_MEDIA_CHUNK_MAX_BYTES) {
            bc_fail(
                'upload_chunk_too_large',
                'That upload chunk exceeded the current upload limit.',
                413
            );
        }

        $pdo = bc_pdo();
        try {
            $pdo->beginTransaction();
            $select = $pdo->prepare(
                'SELECT *
                 FROM message_media_uploads
                 WHERE owner_user_id = :owner_user_id
                   AND upload_token = :upload_token
                 LIMIT 1
                 FOR UPDATE'
            );
            $select->execute([
                ':owner_user_id' => (int)$authUser['id'],
                ':upload_token' => trim($uploadToken),
            ]);
            $uploadRow = $select->fetch();
            if (!$uploadRow) {
                $pdo->rollBack();
                bc_fail('upload_not_found', 'That upload session was not found or already expired.', 404);
            }

            $totalBytes = (int)$uploadRow['total_bytes'] + $chunkSize;
            if ($totalBytes > BC_MEDIA_MAX_BYTES) {
                $pdo->rollBack();
                bc_fail('upload_too_large', 'That GIF or image is too large to send. Try one under 8 MB.', 413);
            }

            $chunkIndex = (int)$uploadRow['next_chunk_index'];
            $insertChunk = $pdo->prepare(
                'INSERT INTO message_media_upload_chunks
                 (upload_id, chunk_index, chunk_size, chunk_data, created_at)
                 VALUES
                 (:upload_id, :chunk_index, :chunk_size, :chunk_data, UTC_TIMESTAMP())'
            );
            $insertChunk->execute([
                ':upload_id' => (int)$uploadRow['id'],
                ':chunk_index' => $chunkIndex,
                ':chunk_size' => $chunkSize,
                ':chunk_data' => $chunkBytes,
            ]);

            $updateUpload = $pdo->prepare(
                'UPDATE message_media_uploads
                 SET total_bytes = :total_bytes,
                     next_chunk_index = :next_chunk_index,
                     updated_at = UTC_TIMESTAMP()
                 WHERE id = :id'
            );
            $updateUpload->execute([
                ':total_bytes' => $totalBytes,
                ':next_chunk_index' => $chunkIndex + 1,
                ':id' => (int)$uploadRow['id'],
            ]);

            $pdo->commit();
        } catch (Throwable $e) {
            if ($pdo->inTransaction()) {
                $pdo->rollBack();
            }
            bc_fail('upload_failed', 'Could not receive that upload chunk right now.', 500);
        }

        bc_json([
            'ok' => true,
            'status' => 'chunked_upload_appended',
        ]);
    }

    if ($mode === 'chunked_finish') {
        $uploadRow = bc_media_upload_row_for_user_or_fail(
            (int)$authUser['id'],
            (string)($payload['uploadToken'] ?? '')
        );
        if ((int)$uploadRow['total_bytes'] <= 0) {
            bc_fail('upload_missing', 'No GIF or image data was uploaded.', 400);
        }

        $stmt = bc_pdo()->prepare(
            'SELECT chunk_data
             FROM message_media_upload_chunks
             WHERE upload_id = :upload_id
             ORDER BY chunk_index ASC'
        );
        $stmt->execute([':upload_id' => (int)$uploadRow['id']]);
        $bytes = '';
        foreach ($stmt->fetchAll() as $row) {
            $bytes .= (string)($row['chunk_data'] ?? '');
        }

        if (strlen($bytes) !== (int)$uploadRow['total_bytes']) {
            bc_fail('upload_incomplete', 'The GIF or image upload was incomplete. Please try again.', 400);
        }

        $media = bc_media_store_final_upload(
            (int)$authUser['id'],
            (string)$uploadRow['declared_mime_type'],
            isset($uploadRow['original_name']) ? (string)$uploadRow['original_name'] : null,
            $bytes
        );

        $delete = bc_pdo()->prepare(
            'DELETE FROM message_media_uploads WHERE id = :id'
        );
        $delete->execute([':id' => (int)$uploadRow['id']]);

        bc_json([
            'ok' => true,
            'status' => 'uploaded',
            'media' => $media,
        ]);
    }

    bc_fail('invalid_upload_mode', 'Unsupported media upload mode.', 400);
}

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

$declaredMimeType = trim((string)($_POST['mimeType'] ?? ''));
$originalName = bc_media_sanitized_original_name(
    (string)($_POST['filename'] ?? ($file['name'] ?? ''))
);
$mimeType = bc_media_detect_mime_type($tmpName, $declaredMimeType);
$media = bc_media_store_final_upload(
    (int)$authUser['id'],
    $mimeType,
    $originalName,
    $bytes
);

bc_json([
    'ok' => true,
    'status' => 'uploaded',
    'media' => $media,
]);
