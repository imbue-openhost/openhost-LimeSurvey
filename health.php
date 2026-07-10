<?php
// Container health: config present, DB reachable, LimeSurvey schema installed.
header('Content-Type: text/plain');

$configFile = __DIR__ . '/application/config/config.php';
if (!is_file($configFile)) {
    http_response_code(503);
    exit("no config\n");
}

if (!defined('BASEPATH')) {
    define('BASEPATH', ''); // config.php refuses direct access without it
}
$config = require $configFile;
$db = $config['components']['db'];

try {
    $pdo = new PDO($db['connectionString'], $db['username'], $db['password'], [
        PDO::ATTR_TIMEOUT => 2,
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
    ]);
    $pdo->query('SELECT 1 FROM ' . $db['tablePrefix'] . 'users LIMIT 1');
} catch (Throwable $e) {
    http_response_code(503);
    exit("unhealthy\n");
}
echo "ok\n";
