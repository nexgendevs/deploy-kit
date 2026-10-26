# deploy-kit

The shared deploy setup for our Laravel apps on HestiaCP: a [Deployer](https://deployer.org) recipe and a reusable GitHub Actions workflow.

Each deploy builds a fresh release **on the server** (git archive of the tested commit, `composer install --no-dev`, `npm ci` and `npm run build`) in a new folder next to the live one, runs the migrations, and only then switches the `current` symlink. `/up` is checked afterwards, and a failure switches back to the previous release.

**This repository is public.** It holds only the generic procedure. Hostnames, IP addresses, users, folders, client names, keys and `.env` values never go in here; they stay in each app's own repo or on the server.

## What's in it

| Path | What it is |
|---|---|
| `recipe/laravel-hestia.php` | The Deployer recipe: pre-flight checks, build, migrations behind the maintenance page when any are pending, switch, `artisan reload`, health check with rollback, cleanup |
| `.github/workflows/deploy.yml` | The reusable deploy job: refuses a `live/*` branch whose files are not on `dev`, installs Deployer, logs in with the app's deploy key, runs `dep deploy` for the pushed branch and commit |
| `server/` | The server checklist, and the scripts that set up (or `--check`) the shared Redis instances, a HestiaCP user and a domain the same way every time: `setup-redis`, `add-user`, `add-domain`, `use-redis`, `use-horizon` ([server/README.md](server/README.md)) |

## Using it in an app

1. Require the package (dev only; servers never install it):

   ```json
   "repositories": [
       { "type": "vcs", "url": "https://github.com/nexgendevs/deploy-kit" }
   ],
   "require-dev": {
       "nexgendevs/deploy-kit": "^1.0"
   }
   ```

2. Add `deploy.php` with the app's repository, its sites and any app-specific steps:

   ```php
   <?php

   namespace Deployer;

   require __DIR__.'/vendor/nexgendevs/deploy-kit/recipe/laravel-hestia.php';

   set('application', 'my-app');
   set('repository', 'git@github.com:owner/my-app.git');

   // One site per domain; the branch decides when it deploys.
   site('dev.example.com', 'dev')
       ->setHostname('203.0.113.10')
       ->setRemoteUser('my-app')
       ->setPort(22)
       ->setDeployPath('/home/my-app/web/dev.example.com/public_html')
       ->set('php_version', '8.4');

   // A live site: ->set('production', true) makes the deploy refuse a
   // shared/.env without APP_ENV=production and APP_DEBUG=false.
   ```

3. Pin the server's host key in `deploy/known_hosts` (check it on the server with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`).

4. Call the workflow from the app's deploy workflow, after its tests:

   ```yaml
   on:
     push:
       branches: [dev, 'live/**']

   concurrency:
     group: deploy-${{ github.ref_name }}
     cancel-in-progress: false

   jobs:
     tests:
       uses: ./.github/workflows/_tests.yml
     deploy:
       needs: tests
       uses: nexgendevs/deploy-kit/.github/workflows/deploy.yml@v1.0.0
       secrets:
         ssh_key: ${{ secrets.DEPLOY_SSH_KEY }}
         # composer_auth: '{"http-basic": {...}}'   # only for private Composer repositories
   ```

5. Add `.nvmrc` with the Node major version; the deploy checks the server runs it.

## Server requirements

- PHP CLI, git, Composer and Node for the SSH user; the server can read the app's repo (a read-only deploy key).
- `<deploy_path>/shared/.env` exists before the first deploy; the deploy stops without it.
- On HestiaCP, once per server: web and proxy templates whose document root is `…/public_html/current/public` (a custom document root resolves the symlink to one release), and PHP-FPM with `opcache.revalidate_path = 1` and `realpath_cache_ttl = 2` (otherwise OPcache keeps serving the previous release).

[server/README.md](server/README.md) has the full checklist. Its `add-user` and `add-domain` scripts set up everything per user and per domain.

## Versions

Releases are tags (`v1.0.0`, `v1.1.0`, …). Apps pin the workflow to a tag and the package with `^1.0`; Dependabot proposes updates to both. Breaking changes get a new major version.
