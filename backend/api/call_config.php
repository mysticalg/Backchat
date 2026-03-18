<?php
declare(strict_types=1);

require __DIR__ . '/bootstrap.php';

bc_require_method('GET');
bc_auth_user_or_fail();

$config = bc_call_ice_config();

bc_json([
    'ok' => true,
    'status' => 'ok',
    'iceServers' => $config['iceServers'],
    'turnConfigured' => $config['turnConfigured'],
    'recommendedPollIntervalMs' => $config['recommendedPollIntervalMs'],
]);
