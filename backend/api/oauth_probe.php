<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('GET');

$cfg = bc_config();

$providerConfigured = [
    'google' =>
        trim((string)$cfg['google_oauth_client_id']) !== '' &&
        trim((string)$cfg['google_oauth_client_secret']) !== '' &&
        trim((string)$cfg['google_oauth_redirect_uri']) !== '',
    'facebook' =>
        trim((string)$cfg['facebook_oauth_client_id']) !== '' &&
        trim((string)$cfg['facebook_oauth_client_secret']) !== '' &&
        trim((string)$cfg['facebook_oauth_redirect_uri']) !== '',
    'x' =>
        trim((string)$cfg['x_oauth_client_id']) !== '' &&
        trim((string)$cfg['x_oauth_client_secret']) !== '' &&
        trim((string)$cfg['x_oauth_redirect_uri']) !== '',
];

$allProvidersConfigured = true;
foreach ($providerConfigured as $configured) {
    if (!$configured) {
        $allProvidersConfigured = false;
        break;
    }
}

$curlAvailable = function_exists('curl_init');

$schemaReady = true;
$schemaMessage = '';
try {
    $pdo = bc_pdo();
    $pdo->query('SELECT 1 FROM oauth_pending_states LIMIT 1');
    $pdo->query('SELECT 1 FROM oauth_identities LIMIT 1');
} catch (Throwable $e) {
    $schemaReady = false;
    $schemaMessage = 'OAuth schema missing. Run setup.php after deployment.';
}

$oauthReady = $curlAvailable && $schemaReady && $allProvidersConfigured;

$message = 'OAuth readiness checks passed.';
if (!$curlAvailable) {
    $message = 'Server is missing PHP cURL extension required for OAuth.';
} elseif (!$schemaReady) {
    $message = $schemaMessage;
} elseif (!$allProvidersConfigured) {
    $message = 'One or more social providers are not configured in config.php.';
}

bc_json([
    'ok' => true,
    'status' => 'ok',
    'oauthReady' => $oauthReady,
    'message' => $message,
    'runtime' => [
        'curlAvailable' => $curlAvailable,
        'schemaReady' => $schemaReady,
    ],
    'providers' => [
        'google' => ['configured' => $providerConfigured['google']],
        'facebook' => ['configured' => $providerConfigured['facebook']],
        'x' => ['configured' => $providerConfigured['x']],
    ],
]);
