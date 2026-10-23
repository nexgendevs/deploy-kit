<?php

/*
 * Deploy recipe for Laravel apps on HestiaCP (Deployer 8), shared by every
 * app that requires nexgendevs/deploy-kit. Each deploy builds a fresh release
 * on the server next to the live one (git archive, composer, npm), migrates,
 * and only then switches the `current` symlink. /up is checked afterwards
 * and a failing check switches back. Nothing here is specific to one app:
 * the repository, the sites and any app-specific steps are in each app's
 * deploy.php, which requires this file:
 *
 *   require __DIR__.'/vendor/nexgendevs/deploy-kit/recipe/laravel-hestia.php';
 *
 * Layout under each site's deploy_path:
 *   current -> releases/N        the web root is current/public
 *   releases/                    the last `keep_releases` builds
 *   shared/.env, shared/storage  linked into every release
 *   .dep/                        Deployer's repo cache, lock and release log
 */

namespace Deployer;

use Deployer\Host\Host;

require 'recipe/laravel.php';
require 'contrib/npm.php';

set('keep_releases', 5);

// HestiaCP runs PHP-FPM as the site's own SSH user, so releases need no extra
// permissions. Deployer's default mode ("acl") needs setfacl and a separate
// web server user.
set('writable_mode', 'skip');

// true on live sites: the deploy then refuses a .env without
// APP_ENV=production and APP_DEBUG=false.
set('production', false);

/**
 * Register a site. The branch is both the label that
 * `dep deploy branch=<branch>` selects on and the git ref deployed when no
 * --revision is given.
 */
function site(string $domain, string $branch): Host
{
    return host($domain)
        ->setLabels(['branch' => $branch])
        ->set('branch', $branch)
        ->set('url', "https://{$domain}");
}

desc('Checks the server before anything is changed');
task('deploy:preflight', function () {
    if (! test('[ -d {{deploy_path}} ]')) {
        throw error('{{deploy_path}} does not exist on {{hostname}}. Check deploy_path for {{alias}} in deploy.php.');
    }

    // Without this Deployer would quietly copy .env.example into shared/.
    if (! test('[ -s {{deploy_path}}/shared/.env ]')) {
        throw error('{{deploy_path}}/shared/.env is missing or empty. Create it before deploying (docs/deployment.md).');
    }

    if (get('production')) {
        if (! test("grep -Eq '^APP_ENV=\"?production\"?[[:space:]]*$' {{deploy_path}}/shared/.env")) {
            throw error('{{alias}} is a live site but shared/.env does not set APP_ENV=production.');
        }

        if (! test("grep -Eq '^APP_DEBUG=\"?(false|0)\"?[[:space:]]*$' {{deploy_path}}/shared/.env")) {
            throw error('{{alias}} is a live site but shared/.env does not set APP_DEBUG=false.');
        }
    }

    if (! test('[ -x {{bin/php}} ]')) {
        throw error('{{bin/php}} was not found on {{hostname}}. Check php_version / bin/php for {{alias}}.');
    }

    foreach (['git', 'composer', 'node', 'npm'] as $command) {
        if (! commandExist($command)) {
            throw error("`{$command}` is not installed for {{remote_user}} on {{hostname}}.");
        }
    }

    $freeKilobytes = (int) run("df -Pk {{deploy_path}} | awk 'NR==2 {print \$4}'");

    if ($freeKilobytes < 1024 * 1024) {
        throw error('Less than 1 GB free on {{hostname}} for {{deploy_path}}.');
    }
});

desc('Checks the server runs the Node major version in .nvmrc');
task('deploy:check_node', function () {
    if (! test('[ -f {{release_path}}/.nvmrc ]')) {
        return;
    }

    $wanted = explode('.', ltrim(trim(run('cat {{release_path}}/.nvmrc')), 'v'))[0];
    $actual = explode('.', ltrim(run('node --version'), 'v'))[0];

    if ($wanted !== $actual) {
        throw error("The server runs Node {$actual}, but .nvmrc asks for {$wanted}. Install Node {$wanted} on {{hostname}}.");
    }
});

desc('Removes node_modules once the assets are built');
task('npm:prune', function () {
    run('rm -rf {{release_path}}/node_modules');
});

desc('Runs migrations behind the maintenance page, only when any are pending');
task('deploy:migrate', function () {
    if (test('{{bin/php}} {{release_path}}/artisan migrate:status --pending=1 > /dev/null 2>&1')) {
        info('No pending migrations.');

        return;
    }

    // storage/ is shared, so this shows the maintenance page on the live
    // release too until artisan:up runs after the switch.
    invoke('artisan:down');
    invoke('artisan:migrate');
});

desc('Checks /up answers 200, and switches back to the previous release if not');
task('deploy:healthcheck', function () {
    $url = rtrim(get('url'), '/').'/up';

    for ($attempt = 1; $attempt <= 5; $attempt++) {
        $response = [];

        try {
            fetch($url, info: $response, nothrow: true);
        } catch (\Throwable) {
            // Connection errors count as a failed attempt.
        }

        if (($response['http_code'] ?? 0) === 200) {
            info("{$url} answered 200.");

            return;
        }

        sleep(3);
    }

    warning("{$url} did not answer 200. Switching back to the previous release.");

    try {
        invoke('rollback');
    } catch (\Throwable) {
        throw error("Health check failed for {$url}, and there is no previous release to switch back to.");
    }

    throw error("Health check failed for {$url}. The previous release is live again; this one is marked BAD_RELEASE.");
});

desc('Never leaves a failed deploy on the maintenance page');
task('deploy:failed_up', function () {
    run('{{bin/php}} {{release_or_current_path}}/artisan up > /dev/null 2>&1 || rm -f {{deploy_path}}/shared/storage/framework/down {{deploy_path}}/shared/storage/framework/maintenance.php');
});

desc('Deploys the project');
task('deploy', [
    'deploy:preflight',
    'deploy:prepare',
    'deploy:vendors',
    // After composer: Tailwind scans files in vendor/.
    'deploy:check_node',
    'npm:install',
    'npm:build',
    'npm:prune',
    'artisan:storage:link',
    'artisan:optimize',
    'deploy:migrate',
    'deploy:symlink',
    'artisan:up',
    'artisan:reload',
    'deploy:healthcheck',
    'deploy:unlock',
    'deploy:cleanup',
    'deploy:success',
]);

fail('deploy', 'deploy:failed');
after('deploy:failed', 'deploy:failed_up');
after('deploy:failed', 'deploy:unlock');
