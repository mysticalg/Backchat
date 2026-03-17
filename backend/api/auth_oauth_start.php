<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('POST');
$payload = bc_read_json_body();
$provider = trim(strtolower((string)($payload['provider'] ?? '')));

if (!bc_is_supported_oauth_provider($provider)) {
    bc_fail('unsupported_provider', 'Provider must be one of: google, facebook, x.', 400);
}

$settings = bc_oauth_provider_settings($provider);
bc_assert_oauth_provider_configured($settings);

$state = bc_secure_random_token(32);
$codeVerifier = bc_secure_random_token(64);
$authorizationUrl = bc_build_oauth_authorize_url($provider, $state, $codeVerifier);

$stmt = bc_pdo()->prepare(
    'INSERT INTO oauth_pending_states (provider, state, code_verifier, status, created_at, expires_at)
     VALUES (:provider, :state, :code_verifier, :status, UTC_TIMESTAMP(), DATE_ADD(UTC_TIMESTAMP(), INTERVAL 10 MINUTE))'
);
$stmt->execute([
    ':provider' => $provider,
    ':state' => $state,
    ':code_verifier' => $codeVerifier,
    ':status' => 'pending',
]);

bc_json([
    'ok' => true,
    'status' => 'pending',
    'provider' => $provider,
    'state' => $state,
    'authorizationUrl' => $authorizationUrl,
    'expiresInSeconds' => 600,
]);
