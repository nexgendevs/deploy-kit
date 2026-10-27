# Server setup (HestiaCP)

The one-time steps for a HestiaCP server that hosts apps deployed with deploy-kit, and the scripts that set up the server, users and domains the same way every time:

| Script | Run | What it sets up |
|---|---|---|
| `setup-redis` | once per server | the two shared Redis instances (cache; sessions and queues) |
| `add-user` | once per user (one per brand) | the HestiaCP user, shell, GitHub read access, the deploy key |
| `add-domain` | once per domain, and again after its first deploy | web domain, HTTPS, templates, `shared/.env`, database, Redis user, cron |
| `use-redis` | once per domain set up before Redis | moves its cache and sessions to Redis |
| `use-horizon` | once per domain, when its app has `laravel/horizon` | runs its queue with Horizon under Supervisor |

All run as root, only add what is missing (running them again is safe), and with `--check` only report. Like the rest of this repository, nothing here names a server, a client or a secret: those are arguments, or live in each app's `docs/deployment.md`.

Terms: **server** = the HestiaCP host · **user** = a HestiaCP (and SSH) user, one per brand · **domain** = one installation of an app, under a user.

## Server checklist (once per server)

The scripts expect HestiaCP with Apache, the nginx proxy, PHP-FPM and MariaDB.

1. **PHP CLI** for every PHP version a site uses, at `/usr/bin/php<version>`, with the extensions the apps need (`php8.4 -m`; Laravel needs at least `mbstring`, `pdo_mysql`, `intl`, `fileinfo`, `gd`).
2. **Composer 2** at `/usr/local/bin/composer` ([getcomposer.org/download](https://getcomposer.org/download/), checking the installer's hash).
3. **Node** from NodeSource, the major version in the apps' `.nvmrc`; the deploy checks it.
4. **Tools the scripts use:** `jq`, `dig` and `curl`. HestiaCP installs them; otherwise `apt install jq bind9-dnsutils curl`.
5. **SSH:** port 22 open to GitHub's runners (HestiaCP firewall, and any firewall at the hosting provider), key-only logins, fail2ban.
6. **`laravel` web and proxy templates.** A custom document root resolves the `current` symlink once and freezes the site on one release, so these templates have the web root `public_html/current/public` written in. A domain needs both: the default proxy template serves static files (json, pdf, jpg…) straight from all of `public_html`, which would expose `shared/storage`. As root:

   ```bash
   cd /usr/local/hestia/data/templates/web
   R='%home%/%user%/web/%domain%/public_html/current/public'
   for f in apache2/php-fpm/default.tpl apache2/php-fpm/default.stpl nginx/default.tpl nginx/default.stpl; do
     new="$(dirname "$f")/laravel.${f##*.}"
     sed -e "s#%sdocroot%#$R#g" -e "s#%docroot%#$R#g" "$f" > "$new"
   done
   grep -c "docroot%" apache2/php-fpm/laravel.* nginx/laravel.*   # 0 for all four
   ```

   HestiaCP upgrades update the `default` templates but not these copies. After an upgrade, run the loop again and then `v-rebuild-web-domains <user>` for each user.

7. **Release-switch settings for PHP-FPM**, once per PHP version a site uses. Without them OPcache keeps serving the previous release until PHP-FPM restarts. As root, for 8.4:

   ```bash
   printf '%s\n' '; Release folders: resolve current -> releases/N on each request' 'opcache.revalidate_path = 1' 'realpath_cache_ttl = 2' > /etc/php/8.4/fpm/conf.d/99-release-switch.ini
   systemctl reload php8.4-fpm
   php-fpm8.4 -i 2>/dev/null | grep -E "revalidate_path|realpath_cache_ttl"   # On, 2
   ```

8. **CLI PHP allows the `pcntl_*` functions**, which `queue:work` needs when the scheduler starts it. Ubuntu's `/etc/php/<version>/cli/php.ini` lists them in `disable_functions`; keep a backup, then empty that line (`disable_functions =`). PHP-FPM has its own `php.ini` and is not affected.
9. **This repository** at `/opt/deploy-kit`, on a release tag:

   ```bash
   git clone https://github.com/nexgendevs/deploy-kit.git /opt/deploy-kit
   git -C /opt/deploy-kit checkout v1.1.0
   ```

   To update: `git -C /opt/deploy-kit fetch --tags && git -C /opt/deploy-kit checkout <tag>`.

10. **Redis**, shared by every domain: `apt install redis-server php8.4-redis` (the extension for every PHP version a site uses), then `/opt/deploy-kit/server/setup-redis`. It adds two instances next to Redis's own (which it leaves alone), both on localhost only and run by systemd's `redis-server@` template with the settings in `server/redis/`:

    | Instance | Port | For | Memory | When full | On disk |
    |---|---|---|---|---|---|
    | `cache` | 6380 | caches | 256 MB | evicts the least recently used keys | nothing |
    | `data` | 6381 | sessions and queues | 512 MB | refuses writes, never drops a session or job | append-only file every second, plus snapshots |

    Logins are ACL users. The `default` user is off. `admin`, whose password is in `/etc/redis/admin.pass` (readable by root only), is what the scripts use. Every domain has its own user, named after the domain, that may only use keys under `<domain>:` and no dangerous commands (`FLUSHALL`, `FLUSHDB`, `KEYS`, `CONFIG`…). One portal can't read another's sessions or queued mail. Because of this, `php artisan cache:clear` (which runs `FLUSHDB`) is refused; caches expire on their own. `setup-redis` also sets `vm.overcommit_memory = 1`, which Redis needs to save in the background reliably.

11. **Supervisor**, which keeps each domain's Horizon running: `apt install supervisor`. Its programs live in `/etc/supervisor/conf.d/` (written by `use-horizon`), their logs in `/var/log/supervisor/`.

`add-domain` refuses to run without items 6, 7 and 10, so a missed step shows up there.

## A new user: `add-user`

```bash
/opt/deploy-kit/server/add-user <user> <owner/repo> --email <address>
```

`--email` is the contact address HestiaCP needs to create the user. It is only needed when the user does not exist yet. In order, the script:

1. creates the HestiaCP user with a random password (nobody signs in to HestiaCP as it; set one with `v-change-user-password` if needed);
2. sets the shell to bash, so deploys can log in;
3. creates the read key `~/.ssh/github_<repo>` and selects it for `github.com` in `~/.ssh/config`;
4. adds GitHub's SSH host keys from `api.github.com`;
5. tests that the user can read the repository. The first time it cannot. The script prints the public key and the GitHub page to add it on (Settings → Deploy keys, write access off); then run it again;
6. adds the public half of the app's `DEPLOY_SSH_KEY` to `authorized_keys` with the comment `github-deploy-<repo>`. If another user already has that key, the script copies it from there; otherwise it asks you to paste it.

## A new domain: `add-domain`

```bash
/opt/deploy-kit/server/add-domain <user> <domain> <database> [--live] [--php 8.4]
```

`<database>` is the name without the `<user>_` prefix HestiaCP adds: `ngd` gives the database and login `<user>_ngd`. `--live` marks a live site, so the new `shared/.env` gets `APP_ENV=production` (otherwise `staging`).

The whole sequence for a new domain:

1. **DNS:** an A record pointing at the server, and no AAAA record (HestiaCP serves the domain over IPv4 only). HestiaCP adds `www.<domain>` as an alias to a two-part domain (`example.com`), so `www` needs a record too, or remove the alias. The script checks with a public resolver and stops before Let's Encrypt if anything is missing.
2. **`add-domain`:** web domain with the PHP-FPM backend, Let's Encrypt, HTTPS redirect and HSTS, no custom document root, both `laravel` templates (checked in the generated Apache and nginx files), `shared/.env`, then the database and the domain's Redis user with the passwords from `shared/.env`. The new `.env` has only what every app needs: `APP_ENV`, a new `APP_KEY`, `APP_DEBUG=false`, `APP_URL`, `LOG_LEVEL`, the database login, `SESSION_SECURE_COOKIE=true`, and cache and sessions in Redis (`CACHE_STORE`, `SESSION_DRIVER`, the `REDIS_*` login, the ports and the prefix `<domain>:`). The app's `config/database.php` must read `REDIS_CACHE_PORT` for its `cache` connection, so caches go to the cache instance.
3. **The app's own settings:** add them to `shared/.env` as the user, before the first deploy. The app's `docs/deployment.md` lists them (`APP_NAME`, queue, mail…).
4. **Deploy:** add the site to the app's `deploy.php` and deploy.
5. **`add-domain` again:** adds the scheduler's cron entry, then checks the site: `/up` answers 200, HTTP redirects to HTTPS, the HSTS header is sent, and `/.env`, `/shared/.env`, `/composer.json` and the like answer 404. The cron entry waits for the first deploy because HestiaCP emails cron output to the user's contact address, and `cd current` would fail every minute until then.
6. **First administrator:** the app's `docs/deployment.md`.

The script never changes an existing `shared/.env`. It only reports problems it finds there (the wrong `APP_URL`, a database login that fails, and with `--live` an `APP_ENV` other than production or `APP_DEBUG` not false), and you fix them by hand.

## An existing domain to Redis: `use-redis`

Domains set up before Redis keep their cache and sessions in the database until this runs, once per domain (`add-domain --check` reports them):

```bash
/opt/deploy-kit/server/use-redis <user> <domain>
```

First the app's `config/database.php` must read `REDIS_CACHE_PORT` for its `cache` connection, and that change must be deployed; the script stops before changing anything if it isn't. Then the script:

1. creates the domain's Redis user on both instances;
2. backs up `shared/.env` as `.env.bak-<date>`, then sets `CACHE_STORE=redis`, `SESSION_DRIVER=redis` and the `REDIS_*` login, ports and prefix in it. The values never appear in its output;
3. rebuilds the config cache (`artisan optimize`) and checks that the app now uses Redis, that `/up` and `/login` answer, and that sessions arrive in Redis.

Everybody signed in to the domain is signed out once: sessions don't move. Queues stay as they are and move to Redis together with Horizon.

## A domain's queue with Horizon: `use-horizon`

Apps with `laravel/horizon` run their queue with Horizon: one `php artisan horizon` process per domain, kept running by Supervisor. Once the app's Horizon change is deployed and the domain is on Redis (`use-redis`, or `add-domain` for new domains), run once per domain:

```bash
/opt/deploy-kit/server/use-horizon <user> <domain>
```

It stops before changing anything if the deployed app has no Horizon or the domain isn't on Redis. Otherwise:

1. if the queue was the database, it works off the jobs still waiting there (`queue:work database --stop-when-empty`);
2. backs up `shared/.env`, sets `QUEUE_CONNECTION=redis` and rebuilds the config cache, putting the backup back if that fails;
3. writes the Supervisor program `/etc/supervisor/conf.d/<domain>-horizon.conf`: `php artisan horizon` from `current/` as the domain's user, restarted whenever it exits, log in `/var/log/supervisor/<domain>-horizon.log`;
4. starts it, then checks that `horizon:status` reports running and that `https://<domain>/horizon` refuses visitors who are not signed in.

Deploys need nothing more: `artisan reload` ends Horizon with `horizon:terminate`, and Supervisor starts it again on the new release. The app keeps Horizon's keys under its Redis prefix (`<domain>:horizon:`), the only keys its Redis user may use. `add-domain --check` reports a deployed app with Horizon whose queue doesn't run with it yet.

## Checking: `--check`

`--check` changes nothing: every change goes through one function that refuses to run in this mode. It is safe on live servers at any time, for example after a HestiaCP upgrade:

```text
# /opt/deploy-kit/server/add-domain --check shop shop.example.com ngd
Checking shop.example.com for shop (nothing will be changed)

Web domain
  ok      shop.example.com
  ok      PHP-FPM backend PHP-8_4
...
After the first deploy
  ok      deployed (current -> releases/3)
  ok      scheduler cron entry
  ok      https://shop.example.com/up answers 200
...
All checks passed.
```

Each line is `ok`, `added`, `todo` (missing, and the script can add it), `warn` (needs a person), `later` (after the first deploy) or `note`. The exit code is 0 when nothing is `todo` or `warn`.

## Conventions

- Read key: `~/.ssh/github_<repo>` (dashes become underscores), selected for `github.com` in `~/.ssh/config`. One per user, added on GitHub as a read-only deploy key titled `<server> <user> (read-only)`.
- Deploy key: one per app (the `DEPLOY_SSH_KEY` secret). Its public half is in every user that hosts the app, with the one-word comment `github-deploy-<repo>`. HestiaCP splits comments at spaces, and `add-user` uses the comment to find the key.
- Database: `<user>_<name>`, with a login of the same name.
- Redis: one ACL user per domain, named after the domain, on both instances with the same password (`REDIS_USERNAME` / `REDIS_PASSWORD`), limited to keys under `REDIS_PREFIX=<domain>:`. A Horizon prefix must start with it too (`<domain>:horizon:`).
- Horizon: Supervisor program `<domain>-horizon`, log `/var/log/supervisor/<domain>-horizon.log`.
- `shared/.env`: mode 600, owned by the user, written once. Deploys and these scripts never change it.
