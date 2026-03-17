<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

header('Content-Type: text/html; charset=utf-8');

function bc_oauth_callback_page(string $title, string $message): void
{
    $safeTitle = htmlspecialchars($title, ENT_QUOTES, 'UTF-8');
    $safeMessage = htmlspecialchars($message, ENT_QUOTES, 'UTF-8');
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">';
    echo '<title>' . $safeTitle . '</title>';
    echo '<style>body{font-family:Arial,sans-serif;padding:24px;background:#f6f8fb;color:#1f2937}.card{max-width:560px;margin:auto;background:white;border-radius:10px;padding:20px;box-shadow:0 6px 24px rgba(0,0,0,.08)}h1{margin-top:0;font-size:22px}</style>';
    echo '</head><body><div class="card"><h1>' . $safeTitle . '</h1><p>' . $safeMessage . '</p><p>You can return to the Backchat app now.</p></div></body></html>';
    exit;
}

$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? '');
if ($method !== 'GET') {
    bc_oauth_callback_page('Invalid Request', 'OAuth callback only accepts GET requests.');
}

$state = trim((string)($_GET['state'] ?? ''));
$code = trim((string)($_GET['code'] ?? ''));
$providerError = trim((string)($_GET['error'] ?? ''));

if ($state === '') {
    bc_oauth_callback_page('Missing State', 'The OAuth callback did not include a valid state parameter.');
}

$findState = bc_pdo()->prepare(
    'SELECT id, provider, state, code_verifier, status
     FROM oauth_pending_states
     WHERE state = :state
       AND expires_at > UTC_TIMESTAMP()
     LIMIT 1'
);
$findState->execute([':state' => $state]);
$stateRow = $findState->fetch();
if (!$stateRow) {
    bc_oauth_callback_page('Session Expired', 'This login session is no longer valid. Please start again from Backchat.');
}

if ((string)$stateRow['status'] !== 'pending') {
    bc_oauth_callback_page('Already Processed', 'This OAuth session was already handled. Please return to Backchat.');
}

if ($providerError !== '') {
    $fail = bc_pdo()->prepare(
        'UPDATE oauth_pending_states
         SET status = :status, error_code = :error_code, completed_at = UTC_TIMESTAMP()
         WHERE id = :id'
    );
    $fail->execute([
        ':status' => 'failed',
        ':error_code' => $providerError,
        ':id' => (int)$stateRow['id'],
    ]);
    bc_oauth_callback_page('Login Cancelled', 'The provider returned: ' . $providerError . '.');
}

if ($code === '') {
    bc_oauth_callback_page('Missing Code', 'The OAuth provider did not return an authorization code.');
}

try {
    $provider = (string)$stateRow['provider'];
    $tokenPayload = bc_exchange_oauth_code(
        $provider,
        $code,
        (string)$stateRow['code_verifier']
    );
    $profile = bc_fetch_oauth_profile($provider, (string)$tokenPayload['access_token']);
    $userRow = bc_find_or_create_user_for_oauth($provider, $profile);
    $userId = (int)$userRow['id'];
    bc_upsert_oauth_identity($userId, $provider, $profile, $tokenPayload);
    $sessionToken = bc_issue_session_token($userId);

    $complete = bc_pdo()->prepare(
        'UPDATE oauth_pending_states
         SET status = :status, user_id = :user_id, session_token = :session_token, completed_at = UTC_TIMESTAMP(), error_code = NULL
         WHERE id = :id'
    );
    $complete->execute([
        ':status' => 'completed',
        ':user_id' => $userId,
        ':session_token' => $sessionToken,
        ':id' => (int)$stateRow['id'],
    ]);

    bc_oauth_callback_page('Login Complete', 'Authorization succeeded for ' . ucfirst($provider) . '.');
} catch (Throwable $e) {
    $fail = bc_pdo()->prepare(
        'UPDATE oauth_pending_states
         SET status = :status, error_code = :error_code, completed_at = UTC_TIMESTAMP()
         WHERE id = :id'
    );
    $fail->execute([
        ':status' => 'failed',
        ':error_code' => 'oauth_callback_failed',
        ':id' => (int)$stateRow['id'],
    ]);

    bc_oauth_callback_page('Login Failed', 'OAuth login failed. Please try again from the app.');
}
