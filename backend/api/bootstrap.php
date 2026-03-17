<?php
declare(strict_types=1);

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Headers: Content-Type, Authorization, X-Auth-Token');
header('Access-Control-Allow-Methods: GET, POST, OPTIONS');
if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

function bc_json(array $payload, int $status = 200): void
{
    http_response_code($status);
    echo json_encode($payload, JSON_UNESCAPED_SLASHES);
    exit;
}

function bc_fail(string $status, string $message, int $httpStatus = 400, array $extra = []): void
{
    bc_json(array_merge([
        'ok' => false,
        'status' => $status,
        'message' => $message,
    ], $extra), $httpStatus);
}

function bc_require_method(string $method): void
{
    if ($_SERVER['REQUEST_METHOD'] !== strtoupper($method)) {
        bc_fail('method_not_allowed', 'Invalid request method.', 405);
    }
}

function bc_read_json_body(): array
{
    $raw = file_get_contents('php://input');
    if ($raw === false || trim($raw) === '') {
        return [];
    }
    $decoded = json_decode($raw, true);
    if (!is_array($decoded)) {
        bc_fail('invalid_json', 'Request body must be valid JSON.', 400);
    }
    return $decoded;
}

function bc_config(): array
{
    static $config = null;
    if ($config !== null) {
        return $config;
    }

    $configPath = __DIR__ . '/config.php';
    if (!file_exists($configPath)) {
        bc_fail('server_config_missing', 'Server config.php is missing.', 500);
    }

    $loaded = require $configPath;
    if (!is_array($loaded)) {
        bc_fail('server_config_invalid', 'Server config.php must return an array.', 500);
    }

    $required = ['db_host', 'db_port', 'db_name', 'db_user', 'db_pass', 'setup_key'];
    foreach ($required as $key) {
        if (!array_key_exists($key, $loaded)) {
            bc_fail('server_config_invalid', "Missing config key: {$key}", 500);
        }
    }
    $config = $loaded;
    return $config;
}

function bc_pdo(): PDO
{
    static $pdo = null;
    if ($pdo !== null) {
        return $pdo;
    }

    $cfg = bc_config();
    $dsn = sprintf(
        'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
        $cfg['db_host'],
        (int)$cfg['db_port'],
        $cfg['db_name']
    );

    try {
        $pdo = new PDO($dsn, (string)$cfg['db_user'], (string)$cfg['db_pass'], [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => false,
        ]);
        return $pdo;
    } catch (Throwable $e) {
        bc_fail('db_connect_failed', 'Could not connect to database.', 500);
    }
}

function bc_validate_username(string $username): bool
{
    return preg_match('/^[a-zA-Z0-9_]{3,24}$/', $username) === 1;
}

function bc_validate_email(string $email): bool
{
    return filter_var($email, FILTER_VALIDATE_EMAIL) !== false;
}

function bc_normalize_username(string $username): string
{
    return strtolower(trim($username));
}

function bc_extract_auth_token(): ?string
{
    $auth = $_SERVER['HTTP_AUTHORIZATION'] ?? ($_SERVER['REDIRECT_HTTP_AUTHORIZATION'] ?? '');
    if (is_string($auth) && preg_match('/Bearer\s+(.+)/i', $auth, $matches) === 1) {
        return trim($matches[1]);
    }

    $alt = $_SERVER['HTTP_X_AUTH_TOKEN'] ?? '';
    if (is_string($alt) && trim($alt) !== '') {
        return trim($alt);
    }
    return null;
}

function bc_hash_token(string $token): string
{
    return hash('sha256', $token);
}

function bc_issue_session_token(int $userId): string
{
    $token = bin2hex(random_bytes(32));
    $tokenHash = bc_hash_token($token);

    $sql = 'INSERT INTO sessions (user_id, token_hash, created_at, last_seen_at, expires_at)
            VALUES (:user_id, :token_hash, UTC_TIMESTAMP(), UTC_TIMESTAMP(), DATE_ADD(UTC_TIMESTAMP(), INTERVAL 30 DAY))';
    $stmt = bc_pdo()->prepare($sql);
    $stmt->execute([
        ':user_id' => $userId,
        ':token_hash' => $tokenHash,
    ]);

    return $token;
}

function bc_auth_user_or_fail(): array
{
    $token = bc_extract_auth_token();
    if ($token === null || $token === '') {
        bc_fail('unauthorized', 'Missing auth token.', 401);
    }

    $sql = 'SELECT u.id, u.username, u.normalized_username
            FROM sessions s
            INNER JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = :token_hash
              AND s.revoked_at IS NULL
              AND (s.expires_at IS NULL OR s.expires_at > UTC_TIMESTAMP())
            LIMIT 1';
    $stmt = bc_pdo()->prepare($sql);
    $stmt->execute([':token_hash' => bc_hash_token($token)]);
    $user = $stmt->fetch();

    if (!$user) {
        bc_fail('unauthorized', 'Invalid or expired auth token.', 401);
    }

    $touch = bc_pdo()->prepare(
        'UPDATE sessions SET last_seen_at = UTC_TIMESTAMP() WHERE token_hash = :token_hash'
    );
    $touch->execute([':token_hash' => bc_hash_token($token)]);

    return $user;
}

function bc_user_payload(array $row): array
{
    return [
        'id' => 'username:' . ($row['normalized_username'] ?? ''),
        'username' => (string)($row['username'] ?? ''),
        'displayName' => (string)($row['username'] ?? ''),
        'avatarUrl' => '',
        'provider' => 'username',
        'status' => 'online',
    ];
}
