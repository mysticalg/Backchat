<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_json([
    'ok' => true,
    'status' => 'api_root',
    'message' => 'Backchat API is online.',
    'endpoints' => [
        'health' => '/health.php',
        'auth' => '/auth_username.php',
        'recover' => '/recover_username.php',
        'contacts' => '/contacts.php',
        'invite' => '/invite_by_username.php',
        'sendMessage' => '/send_message.php',
        'pollMessages' => '/poll_messages.php',
    ],
]);
