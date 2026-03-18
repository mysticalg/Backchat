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

function bc_first_env(array $keys): ?string
{
    foreach ($keys as $key) {
        $value = getenv($key);
        if ($value !== false && trim((string)$value) !== '') {
            return trim((string)$value);
        }

        $serverValue = $_SERVER[$key] ?? ($_ENV[$key] ?? null);
        if (is_string($serverValue) && trim($serverValue) !== '') {
            return trim($serverValue);
        }
    }

    return null;
}

function bc_config(): array
{
    static $config = null;
    if ($config !== null) {
        return $config;
    }

    $fileConfig = [];
    $configPath = __DIR__ . '/config.php';
    if (file_exists($configPath)) {
        $loaded = require $configPath;
        if (!is_array($loaded)) {
            bc_fail('server_config_invalid', 'Server config.php must return an array.', 500);
        }
        $fileConfig = $loaded;
    }

    $optional = [
        'google_oauth_client_id' => '',
        'google_oauth_client_secret' => '',
        'google_oauth_redirect_uri' => '',
        'facebook_oauth_client_id' => '',
        'facebook_oauth_client_secret' => '',
        'facebook_oauth_redirect_uri' => '',
        'x_oauth_client_id' => '',
        'x_oauth_client_secret' => '',
        'x_oauth_redirect_uri' => '',
    ];

    $envConfig = array_filter([
        'db_host' => bc_first_env(['BACKCHAT_DB_HOST', 'RDS_HOSTNAME']),
        'db_port' => bc_first_env(['BACKCHAT_DB_PORT', 'RDS_PORT']),
        'db_name' => bc_first_env(['BACKCHAT_DB_NAME', 'RDS_DB_NAME']),
        'db_user' => bc_first_env(['BACKCHAT_DB_USER', 'RDS_USERNAME']),
        'db_pass' => bc_first_env(['BACKCHAT_DB_PASS', 'RDS_PASSWORD']),
        'setup_key' => bc_first_env(['BACKCHAT_SETUP_KEY', 'SETUP_KEY']),
        'google_oauth_client_id' => bc_first_env(['BACKCHAT_GOOGLE_OAUTH_CLIENT_ID']),
        'google_oauth_client_secret' => bc_first_env(['BACKCHAT_GOOGLE_OAUTH_CLIENT_SECRET']),
        'google_oauth_redirect_uri' => bc_first_env(['BACKCHAT_GOOGLE_OAUTH_REDIRECT_URI']),
        'facebook_oauth_client_id' => bc_first_env(['BACKCHAT_FACEBOOK_OAUTH_CLIENT_ID']),
        'facebook_oauth_client_secret' => bc_first_env(['BACKCHAT_FACEBOOK_OAUTH_CLIENT_SECRET']),
        'facebook_oauth_redirect_uri' => bc_first_env(['BACKCHAT_FACEBOOK_OAUTH_REDIRECT_URI']),
        'x_oauth_client_id' => bc_first_env(['BACKCHAT_X_OAUTH_CLIENT_ID']),
        'x_oauth_client_secret' => bc_first_env(['BACKCHAT_X_OAUTH_CLIENT_SECRET']),
        'x_oauth_redirect_uri' => bc_first_env(['BACKCHAT_X_OAUTH_REDIRECT_URI']),
    ], static fn($value) => $value !== null);

    $config = array_merge($optional, $fileConfig, $envConfig);

    $required = ['db_host', 'db_port', 'db_name', 'db_user', 'db_pass', 'setup_key'];
    foreach ($required as $key) {
        if (!array_key_exists($key, $config) || trim((string)$config[$key]) === '') {
            bc_fail(
                'server_config_missing',
                'Server configuration is incomplete. Set Elastic Beanstalk environment variables or provide config.php.',
                500
            );
        }
    }

    $config['db_port'] = (int)$config['db_port'];
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

function bc_base64url_encode(string $bytes): string
{
    return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
}

function bc_secure_random_token(int $bytes = 32): string
{
    return bc_base64url_encode(random_bytes($bytes));
}

function bc_pkce_challenge_s256(string $verifier): string
{
    return bc_base64url_encode(hash('sha256', $verifier, true));
}

function bc_is_supported_oauth_provider(string $provider): bool
{
    return in_array($provider, ['google', 'facebook', 'x'], true);
}

function bc_oauth_provider_settings(string $provider): array
{
    $cfg = bc_config();
    if (!bc_is_supported_oauth_provider($provider)) {
        bc_fail('unsupported_provider', 'Provider is not supported.', 400);
    }

    if ($provider === 'google') {
        return [
            'provider' => 'google',
            'auth_endpoint' => 'https://accounts.google.com/o/oauth2/v2/auth',
            'token_endpoint' => 'https://oauth2.googleapis.com/token',
            'profile_endpoint' => 'https://openidconnect.googleapis.com/v1/userinfo',
            'client_id' => trim((string)$cfg['google_oauth_client_id']),
            'client_secret' => trim((string)$cfg['google_oauth_client_secret']),
            'redirect_uri' => trim((string)$cfg['google_oauth_redirect_uri']),
            'scopes' => ['openid', 'profile', 'email'],
        ];
    }

    if ($provider === 'facebook') {
        return [
            'provider' => 'facebook',
            'auth_endpoint' => 'https://www.facebook.com/dialog/oauth',
            'token_endpoint' => 'https://graph.facebook.com/oauth/access_token',
            'profile_endpoint' => 'https://graph.facebook.com/me?fields=id,name,email,picture.type(large),username',
            'client_id' => trim((string)$cfg['facebook_oauth_client_id']),
            'client_secret' => trim((string)$cfg['facebook_oauth_client_secret']),
            'redirect_uri' => trim((string)$cfg['facebook_oauth_redirect_uri']),
            'scopes' => ['public_profile', 'email'],
        ];
    }

    return [
        'provider' => 'x',
        'auth_endpoint' => 'https://twitter.com/i/oauth2/authorize',
        'token_endpoint' => 'https://api.twitter.com/2/oauth2/token',
        'profile_endpoint' => 'https://api.twitter.com/2/users/me?user.fields=id,name,username,profile_image_url',
        'client_id' => trim((string)$cfg['x_oauth_client_id']),
        'client_secret' => trim((string)$cfg['x_oauth_client_secret']),
        'redirect_uri' => trim((string)$cfg['x_oauth_redirect_uri']),
        'scopes' => ['tweet.read', 'users.read', 'offline.access'],
    ];
}

function bc_assert_oauth_provider_configured(array $providerSettings): void
{
    $missing = [];
    foreach (['client_id', 'client_secret', 'redirect_uri'] as $key) {
        if (trim((string)($providerSettings[$key] ?? '')) === '') {
            $missing[] = $key;
        }
    }
    if (!empty($missing)) {
        bc_fail(
            'oauth_provider_not_configured',
            'OAuth config is incomplete for provider ' . $providerSettings['provider'] . ': ' . implode(', ', $missing) . '.',
            500
        );
    }
}

function bc_http_request(
    string $method,
    string $url,
    array $headers = [],
    ?string $body = null
): array {
    if (!function_exists('curl_init')) {
        throw new RuntimeException('PHP cURL extension is required for OAuth.');
    }

    $ch = curl_init($url);
    if ($ch === false) {
        throw new RuntimeException('Could not initialize OAuth HTTP client.');
    }

    $opts = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HEADER => true,
        CURLOPT_FOLLOWLOCATION => false,
        CURLOPT_TIMEOUT => 15,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_CUSTOMREQUEST => strtoupper($method),
        CURLOPT_HTTPHEADER => $headers,
    ];
    if ($body !== null) {
        $opts[CURLOPT_POSTFIELDS] = $body;
    }

    curl_setopt_array($ch, $opts);
    $raw = curl_exec($ch);
    if (!is_string($raw)) {
        $message = curl_error($ch);
        curl_close($ch);
        throw new RuntimeException('OAuth HTTP request failed: ' . $message);
    }

    $status = (int)curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    $headerSize = (int)curl_getinfo($ch, CURLINFO_HEADER_SIZE);
    curl_close($ch);

    return [
        'status' => $status,
        'headers_raw' => substr($raw, 0, $headerSize),
        'body' => substr($raw, $headerSize),
    ];
}

function bc_http_get_json(string $url, array $headers = []): array
{
    $response = bc_http_request('GET', $url, $headers, null);
    $decoded = json_decode((string)$response['body'], true);
    if (!is_array($decoded)) {
        throw new RuntimeException('OAuth provider returned invalid JSON.');
    }
    return [
        'status' => (int)$response['status'],
        'json' => $decoded,
    ];
}

function bc_http_post_form_json(string $url, array $form, array $headers = []): array
{
    $allHeaders = array_merge(
        ['Content-Type: application/x-www-form-urlencoded'],
        $headers
    );
    $response = bc_http_request(
        'POST',
        $url,
        $allHeaders,
        http_build_query($form)
    );
    $decoded = json_decode((string)$response['body'], true);
    if (!is_array($decoded)) {
        throw new RuntimeException('OAuth provider returned invalid JSON.');
    }
    return [
        'status' => (int)$response['status'],
        'json' => $decoded,
    ];
}

function bc_build_oauth_authorize_url(string $provider, string $state, string $codeVerifier): string
{
    $settings = bc_oauth_provider_settings($provider);
    bc_assert_oauth_provider_configured($settings);
    $challenge = bc_pkce_challenge_s256($codeVerifier);

    $query = [
        'client_id' => $settings['client_id'],
        'redirect_uri' => $settings['redirect_uri'],
        'response_type' => 'code',
        'scope' => implode(' ', $settings['scopes']),
        'state' => $state,
    ];

    if ($provider === 'google') {
        $query['access_type'] = 'offline';
        $query['prompt'] = 'consent';
        $query['code_challenge'] = $challenge;
        $query['code_challenge_method'] = 'S256';
    } elseif ($provider === 'facebook') {
        $query['auth_type'] = 'rerequest';
    } else {
        $query['code_challenge'] = $challenge;
        $query['code_challenge_method'] = 'S256';
    }

    return $settings['auth_endpoint'] . '?' . http_build_query($query);
}

function bc_exchange_oauth_code(string $provider, string $code, string $codeVerifier): array
{
    $settings = bc_oauth_provider_settings($provider);
    bc_assert_oauth_provider_configured($settings);

    if ($provider === 'x') {
        $basic = base64_encode($settings['client_id'] . ':' . $settings['client_secret']);
        $response = bc_http_post_form_json(
            $settings['token_endpoint'],
            [
                'grant_type' => 'authorization_code',
                'code' => $code,
                'redirect_uri' => $settings['redirect_uri'],
                'code_verifier' => $codeVerifier,
            ],
            ['Authorization: Basic ' . $basic]
        );
    } elseif ($provider === 'google') {
        $response = bc_http_post_form_json(
            $settings['token_endpoint'],
            [
                'client_id' => $settings['client_id'],
                'client_secret' => $settings['client_secret'],
                'code' => $code,
                'grant_type' => 'authorization_code',
                'redirect_uri' => $settings['redirect_uri'],
                'code_verifier' => $codeVerifier,
            ]
        );
    } else {
        $response = bc_http_post_form_json(
            $settings['token_endpoint'],
            [
                'client_id' => $settings['client_id'],
                'client_secret' => $settings['client_secret'],
                'code' => $code,
                'grant_type' => 'authorization_code',
                'redirect_uri' => $settings['redirect_uri'],
            ]
        );
    }

    if ($response['status'] >= 400) {
        $message = $response['json']['error_description']
            ?? $response['json']['error']['message']
            ?? $response['json']['error']
            ?? 'Token exchange failed.';
        throw new RuntimeException((string)$message);
    }

    $accessToken = trim((string)($response['json']['access_token'] ?? ''));
    if ($accessToken === '') {
        throw new RuntimeException('Provider did not return access_token.');
    }

    return [
        'access_token' => $accessToken,
        'refresh_token' => (string)($response['json']['refresh_token'] ?? ''),
        'token_type' => (string)($response['json']['token_type'] ?? ''),
        'scope' => (string)($response['json']['scope'] ?? ''),
        'expires_in' => (int)($response['json']['expires_in'] ?? 0),
        'raw' => $response['json'],
    ];
}

function bc_fetch_oauth_profile(string $provider, string $accessToken): array
{
    $settings = bc_oauth_provider_settings($provider);
    $response = bc_http_get_json(
        $settings['profile_endpoint'],
        ['Authorization: Bearer ' . $accessToken]
    );

    if ($response['status'] >= 400) {
        throw new RuntimeException('Could not fetch profile from provider.');
    }

    $profile = $response['json'];
    if ($provider === 'x' && isset($profile['data']) && is_array($profile['data'])) {
        $profile = $profile['data'];
    }

    $providerUserId = '';
    $providerUsername = '';
    $displayName = '';
    $email = '';
    $avatarUrl = '';

    if ($provider === 'google') {
        $providerUserId = trim((string)($profile['sub'] ?? ''));
        $providerUsername = trim((string)($profile['email'] ?? ''));
        $displayName = trim((string)($profile['name'] ?? ''));
        $email = trim((string)($profile['email'] ?? ''));
        $avatarUrl = trim((string)($profile['picture'] ?? ''));
    } elseif ($provider === 'facebook') {
        $providerUserId = trim((string)($profile['id'] ?? ''));
        $providerUsername = trim((string)($profile['username'] ?? ($profile['email'] ?? '')));
        $displayName = trim((string)($profile['name'] ?? ''));
        $email = trim((string)($profile['email'] ?? ''));
        $avatarData = $profile['picture']['data'] ?? null;
        if (is_array($avatarData)) {
            $avatarUrl = trim((string)($avatarData['url'] ?? ''));
        }
    } else {
        $providerUserId = trim((string)($profile['id'] ?? ''));
        $providerUsername = trim((string)($profile['username'] ?? ''));
        $displayName = trim((string)($profile['name'] ?? ''));
        $email = '';
        $avatarUrl = trim((string)($profile['profile_image_url'] ?? ''));
    }

    if ($providerUserId === '') {
        throw new RuntimeException('Provider profile is missing user id.');
    }

    return [
        'provider_user_id' => $providerUserId,
        'provider_username' => $providerUsername,
        'display_name' => $displayName,
        'email' => $email,
        'avatar_url' => $avatarUrl,
        'raw_profile' => $profile,
    ];
}

function bc_username_candidate_from_social(array $profile): string
{
    $candidate = trim((string)($profile['provider_username'] ?? ''));
    if ($candidate === '') {
        $candidate = trim((string)($profile['display_name'] ?? ''));
    }
    if ($candidate === '') {
        $candidate = 'user_' . substr(trim((string)($profile['provider_user_id'] ?? '')), -8);
    }

    $candidate = preg_replace('/[^a-zA-Z0-9_]+/', '_', $candidate) ?? '';
    $candidate = trim($candidate, '_');
    if ($candidate === '') {
        $candidate = 'user';
    }
    if (strlen($candidate) < 3) {
        $candidate .= str_repeat('_', 3 - strlen($candidate));
    }
    if (strlen($candidate) > 24) {
        $candidate = substr($candidate, 0, 24);
    }
    if (!bc_validate_username($candidate)) {
        $candidate = 'user_' . substr(hash('sha256', $candidate), 0, 8);
    }
    return $candidate;
}

function bc_unique_username(string $baseCandidate): string
{
    $base = bc_username_candidate_from_social(['provider_username' => $baseCandidate]);
    $pdo = bc_pdo();
    for ($i = 0; $i < 5000; $i++) {
        $suffix = $i === 0 ? '' : '_' . (string)$i;
        $trimTo = max(3, 24 - strlen($suffix));
        $candidate = substr($base, 0, $trimTo) . $suffix;
        $normalized = bc_normalize_username($candidate);

        $stmt = $pdo->prepare(
            'SELECT id FROM users WHERE normalized_username = :normalized LIMIT 1'
        );
        $stmt->execute([':normalized' => $normalized]);
        if (!$stmt->fetch()) {
            return $candidate;
        }
    }

    bc_fail('username_generation_failed', 'Could not generate a unique username.', 500);
}

function bc_unique_recovery_email(string $preferred, string $provider, string $providerUserId): string
{
    $pdo = bc_pdo();
    $candidate = $preferred;
    if (!bc_validate_email($candidate)) {
        $candidate = $provider . '_' . preg_replace('/[^a-zA-Z0-9]/', '', $providerUserId) . '@social.backchat.local';
    }

    for ($i = 0; $i < 5000; $i++) {
        $trial = $candidate;
        if ($i > 0) {
            $parts = explode('@', $candidate, 2);
            $local = $parts[0];
            $domain = $parts[1] ?? 'social.backchat.local';
            $trial = $local . '+' . $i . '@' . $domain;
        }
        $stmt = $pdo->prepare(
            'SELECT id FROM users WHERE LOWER(recovery_email) = :email LIMIT 1'
        );
        $stmt->execute([':email' => strtolower($trial)]);
        if (!$stmt->fetch()) {
            return $trial;
        }
    }

    bc_fail('email_generation_failed', 'Could not generate a unique recovery email.', 500);
}

function bc_load_user_row_by_id(int $userId): array
{
    $stmt = bc_pdo()->prepare(
        'SELECT id, username, normalized_username, recovery_email
         FROM users
         WHERE id = :id
         LIMIT 1'
    );
    $stmt->execute([':id' => $userId]);
    $row = $stmt->fetch();
    if (!$row) {
        bc_fail('user_not_found', 'User not found.', 404);
    }
    return $row;
}

function bc_find_or_create_user_for_oauth(string $provider, array $profile): array
{
    $pdo = bc_pdo();

    $existingIdentity = $pdo->prepare(
        'SELECT u.id, u.username, u.normalized_username, u.recovery_email
         FROM oauth_identities oi
         INNER JOIN users u ON u.id = oi.user_id
         WHERE oi.provider = :provider
           AND oi.provider_user_id = :provider_user_id
         LIMIT 1'
    );
    $existingIdentity->execute([
        ':provider' => $provider,
        ':provider_user_id' => $profile['provider_user_id'],
    ]);
    $linkedUser = $existingIdentity->fetch();
    if ($linkedUser) {
        return $linkedUser;
    }

    $email = trim((string)($profile['email'] ?? ''));
    if ($email !== '' && bc_validate_email($email)) {
        $existingEmail = $pdo->prepare(
            'SELECT id, username, normalized_username, recovery_email
             FROM users
             WHERE LOWER(recovery_email) = :email
             LIMIT 1'
        );
        $existingEmail->execute([':email' => strtolower($email)]);
        $emailUser = $existingEmail->fetch();
        if ($emailUser) {
            return $emailUser;
        }
    }

    $username = bc_unique_username(bc_username_candidate_from_social($profile));
    $recoveryEmail = bc_unique_recovery_email(
        $email,
        $provider,
        (string)$profile['provider_user_id']
    );
    $normalized = bc_normalize_username($username);

    $insert = $pdo->prepare(
        'INSERT INTO users (username, normalized_username, recovery_email, created_at)
         VALUES (:username, :normalized_username, :recovery_email, UTC_TIMESTAMP())'
    );
    $insert->execute([
        ':username' => $username,
        ':normalized_username' => $normalized,
        ':recovery_email' => $recoveryEmail,
    ]);
    $newUserId = (int)$pdo->lastInsertId();
    return bc_load_user_row_by_id($newUserId);
}

function bc_upsert_oauth_identity(
    int $userId,
    string $provider,
    array $profile,
    array $tokenPayload
): void {
    $expiresAt = null;
    if (($tokenPayload['expires_in'] ?? 0) > 0) {
        $expiresAt = gmdate('Y-m-d H:i:s', time() + (int)$tokenPayload['expires_in']);
    }
    $rawProfileJson = json_encode($profile['raw_profile'] ?? [], JSON_UNESCAPED_SLASHES);

    $stmt = bc_pdo()->prepare(
        'INSERT INTO oauth_identities
         (
             user_id, provider, provider_user_id, provider_username, display_name, email, avatar_url,
             access_token, refresh_token, token_type, scope, token_expires_at, raw_profile_json, created_at, updated_at
         )
         VALUES
         (
             :user_id, :provider, :provider_user_id, :provider_username, :display_name, :email, :avatar_url,
             :access_token, :refresh_token, :token_type, :scope, :token_expires_at, :raw_profile_json, UTC_TIMESTAMP(), UTC_TIMESTAMP()
         )
         ON DUPLICATE KEY UPDATE
             user_id = VALUES(user_id),
             provider_username = VALUES(provider_username),
             display_name = VALUES(display_name),
             email = VALUES(email),
             avatar_url = VALUES(avatar_url),
             access_token = VALUES(access_token),
             refresh_token = VALUES(refresh_token),
             token_type = VALUES(token_type),
             scope = VALUES(scope),
             token_expires_at = VALUES(token_expires_at),
             raw_profile_json = VALUES(raw_profile_json),
             updated_at = UTC_TIMESTAMP()'
    );
    $stmt->execute([
        ':user_id' => $userId,
        ':provider' => $provider,
        ':provider_user_id' => (string)$profile['provider_user_id'],
        ':provider_username' => (string)($profile['provider_username'] ?? ''),
        ':display_name' => (string)($profile['display_name'] ?? ''),
        ':email' => (string)($profile['email'] ?? ''),
        ':avatar_url' => (string)($profile['avatar_url'] ?? ''),
        ':access_token' => (string)($tokenPayload['access_token'] ?? ''),
        ':refresh_token' => (string)($tokenPayload['refresh_token'] ?? ''),
        ':token_type' => (string)($tokenPayload['token_type'] ?? ''),
        ':scope' => (string)($tokenPayload['scope'] ?? ''),
        ':token_expires_at' => $expiresAt,
        ':raw_profile_json' => (string)$rawProfileJson,
    ]);
}

function bc_enriched_user_payload(array $userRow): array
{
    $providerRowStmt = bc_pdo()->prepare(
        'SELECT provider, display_name, avatar_url
         FROM oauth_identities
         WHERE user_id = :user_id
         ORDER BY updated_at DESC
         LIMIT 1'
    );
    $providerRowStmt->execute([':user_id' => (int)$userRow['id']]);
    $identity = $providerRowStmt->fetch();

    return [
        'id' => 'username:' . ($userRow['normalized_username'] ?? ''),
        'username' => (string)($userRow['username'] ?? ''),
        'displayName' => (string)($identity['display_name'] ?? ($userRow['username'] ?? '')),
        'avatarUrl' => (string)($identity['avatar_url'] ?? ''),
        'provider' => (string)($identity['provider'] ?? 'username'),
        'status' => 'online',
    ];
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
    $provider = (string)($row['provider'] ?? 'username');
    if ($provider === '') {
        $provider = 'username';
    }
    $avatarUrl = (string)($row['avatar_url'] ?? '');
    $displayName = (string)($row['display_name'] ?? ($row['username'] ?? ''));
    $status = (string)($row['status'] ?? 'online');
    if (!in_array($status, ['online', 'offline', 'busy'], true)) {
        $status = 'online';
    }
    return [
        'id' => 'username:' . ($row['normalized_username'] ?? ''),
        'username' => (string)($row['username'] ?? ''),
        'displayName' => $displayName,
        'avatarUrl' => $avatarUrl,
        'provider' => $provider,
        'status' => $status,
        'lastSeenAtUtc' => isset($row['last_seen_at']) ? (string)$row['last_seen_at'] : null,
    ];
}
