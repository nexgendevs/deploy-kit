# shellcheck shell=bash
#
# Shared by add-user and add-domain: output, the --check guard and the
# HestiaCP lookups. Sourced, never run on its own.
#
# Every change to the server goes through run(), which refuses in --check
# mode. That is what makes --check safe to run on a live server.

set -euo pipefail
umask 022

export PATH="$PATH:/usr/local/hestia/bin"

# Commands run as a site user (runuser) start here, not in root's home.
cd /

check_only=false
open_items=0
temp_files=()

# Set by the scripts that work on one domain: its site user, shared/.env, the
# current release and its PHP binary. env_backup is set by backup_env.
user=''
env_file=''
current=''
php_bin=''
env_backup=''

trap 'rm -f "${temp_files[@]}"' EXIT

say() { printf '  %-7s %s\n' "$1" "$2"; }
ok() { say ok "$1"; }
added() { say added "$1"; }
later() { say later "$1"; }
todo() {
    say todo "$1"
    open_items=$((open_items + 1))
}
warn() {
    say warn "$1"
    open_items=$((open_items + 1))
}
section() { printf '\n%s\n' "$1"; }

die() {
    printf '\nError: %s\n' "$1" >&2
    exit 1
}

# needs "<what>": in --check mode reports <what> as to do and returns 1;
# otherwise returns 0 so the caller makes the change.
needs() {
    if $check_only; then
        todo "$1"
        return 1
    fi
}

# Stops the script if it is about to change something in --check mode.
refuse_in_check_mode() {
    if $check_only; then
        die "internal: '$1' would change the server in --check mode."
    fi
}

# Runs a command that changes the server, printing it first.
run() {
    refuse_in_check_mode "$1"

    printf '          $ %s\n' "$*"

    local output
    if ! output=$("$@" 2>&1); then
        printf '%s\n' "$output" >&2
        die "'$1' failed (output above)."
    fi

    if [[ -n $output ]]; then
        printf '%s\n' "$output" | sed 's/^/          /'
    fi
}

# Writes $1 to a new file in /tmp that only root can read, and sets
# $secret_path to it. HestiaCP's v-* commands read a password from a /tmp
# file, so it never shows up in the process list. Removed on exit.
make_secret_file() {
    secret_path=$(mktemp /tmp/deploy-kit.XXXXXXXX)
    temp_files+=("$secret_path")
    printf '%s\n' "$1" > "$secret_path"
}

random_password() {
    local characters
    characters=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
    printf '%s' "${characters:0:32}"
}

finish() {
    echo
    if ((open_items == 0)); then
        echo "All checks passed."
        exit 0
    fi

    echo "$open_items item(s) above need you (todo / warn). Running this again is safe."
    exit 1
}

require_root_and_hestia() {
    if [[ $EUID -ne 0 ]]; then
        die 'Run this as root.'
    fi

    if [[ ! -x /usr/local/hestia/bin/v-list-user ]]; then
        die 'HestiaCP was not found in /usr/local/hestia.'
    fi

    local tool
    for tool in jq dig curl runuser ssh-keygen mariadb openssl; do
        if ! command -v "$tool" > /dev/null; then
            die "$tool is not installed (server/README.md, server checklist)."
        fi
    done
}

user_exists() {
    v-list-user "$1" json > /dev/null 2>&1
}

# env_value <key>: the value of <key> in $env_file (the domain's shared/.env)
# without surrounding quotes, or nothing. If the key is set twice, the last
# line counts.
env_value() {
    local value double_quoted='^"([^"]*)"' single_quoted="^'([^']*)'"
    value=$(grep -E "^$1=" "$env_file" 2> /dev/null | tail -n 1 || true)
    value=${value#*=}
    value=${value%$'\r'}

    if [[ $value =~ $double_quoted || $value =~ $single_quoted ]]; then
        # Quoted: anything after the closing quote is a comment.
        value=${BASH_REMATCH[1]}
    else
        # Unquoted: a # after whitespace starts a comment, as in Laravel.
        value=${value%%[[:space:]]#*}
        value=${value%"${value##*[![:space:]]}"}
    fi

    printf '%s' "$value"
}

# set_env <key> <value>: sets KEY=value in $env_file as the site user ($user),
# replacing every KEY= line, or adding one at the end (on a new line even if
# the file does not end with one). The value goes over stdin, so it shows up
# neither in the process list nor in this output.
set_env() {
    refuse_in_check_mode "set $1"
    printf '          $ set %s in shared/.env\n' "$1"

    # shellcheck disable=SC2016
    runuser -u "$user" -- bash -c '
        IFS= read -r value
        if grep -q "^$2=" "$1"; then
            sed -i "s|^$2=.*|$2=$value|" "$1"
        else
            if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then
                echo >> "$1"
            fi
            printf "%s=%s\n" "$2" "$value" >> "$1"
        fi' _ "$env_file" "$1" <<< "$2" || die "Could not set $1 in $env_file."
}

# backup_env: copies $env_file to .env.bak-<date> as the site user, and sets
# $env_backup to the copy.
backup_env() {
    env_backup="$env_file.bak-$(date +%Y%m%d-%H%M%S)"
    run runuser -u "$user" -- cp -p "$env_file" "$env_backup"
}

# optimize_or_restore: rebuilds the deployed release's caches after a
# change to $env_file. If that fails, puts $env_backup back first: a failed
# optimize has already cleared the config cache, so the site would read the
# new .env on every request.
optimize_or_restore() {
    local output
    refuse_in_check_mode 'artisan optimize'
    printf '          $ runuser -u %s -- %s %s/artisan optimize\n' "$user" "$php_bin" "$current"

    if ! output=$(runuser -u "$user" -- "$php_bin" "$current/artisan" optimize 2>&1); then
        printf '%s\n' "$output" >&2
        runuser -u "$user" -- cp -p "$env_backup" "$env_file"
        runuser -u "$user" -- "$php_bin" "$current/artisan" optimize > /dev/null 2>&1 || true
        die "artisan optimize failed with the new shared/.env (output above). The backup is back in place and the config cache rebuilt, so the site runs as before."
    fi

    printf '%s\n' "$output" | sed 's/^/          /'
}

# user_field <user> <field>: one field of v-list-user, or nothing.
user_field() {
    v-list-user "$1" json | jq -r --arg u "$1" --arg f "$2" '.[$u][$f] // ""'
}

# --- Redis (setup-redis, use-redis, add-domain) ------------------------------
#
# Two instances set up by setup-redis: "cache" (evicts, nothing on disk) and
# "data" (sessions and queues: never evicts, saved to disk). Each domain logs
# in as its own ACL user, named after the domain, that may only use keys and
# channels under "<domain>:" and no dangerous commands (FLUSHALL, FLUSHDB,
# KEYS, CONFIG...). The "admin" user, whose password only root can read, is
# what these scripts use to manage them.

redis_admin_password_file=/etc/redis/admin.pass
redis_cache_port=6380
redis_data_port=6381
redis_instances=("cache:$redis_cache_port" "data:$redis_data_port")

redis_ready() {
    [[ -s $redis_admin_password_file ]] \
        && systemctl is-active --quiet redis-server@cache \
        && systemctl is-active --quiet redis-server@data
}

# redis_as <port> <user> <password> <command>...: runs the commands (one per
# argument) logged in as <user> and prints their replies, one per line. The
# login goes over stdin, so no password shows up in the process list. Fails
# when the login is refused.
redis_as() {
    local port=$1 user=$2 password=$3 replies
    shift 3

    replies=$({ printf 'AUTH %s %s\n' "$user" "$password"; printf '%s\n' "$@"; } | redis-cli -p "$port" 2>&1 || true)

    if [[ ${replies%%$'\n'*} != OK ]]; then
        return 1
    fi

    printf '%s\n' "${replies#*$'\n'}"
}

# redis_admin <port> <command>...: redis_as, logged in as admin.
redis_admin() {
    local port=$1
    shift
    redis_as "$port" admin "$(cat "$redis_admin_password_file")" "$@"
}

# redis_user_problem <user> <password>: prints what is wrong with a domain's
# Redis user on either instance, or nothing when it logs in with this
# password, may use its own keys, and is refused other keys and FLUSHDB.
# ACL DRYRUN only asks; nothing is run.
redis_user_problem() {
    local user=$1 password=$2 instance name port
    local -a replies

    for instance in "${redis_instances[@]}"; do
        name=${instance%%:*}
        port=${instance##*:}

        if ! redis_as "$port" "$user" "$password" PING > /dev/null; then
            echo "$user cannot log in to Redis $name with the password in shared/.env"
            return
        fi

        mapfile -t replies < <(redis_admin "$port" \
            "ACL DRYRUN $user SET $user:deploy-kit-check 1" \
            "ACL DRYRUN $user GET deploy-kit-outside:check" \
            "ACL DRYRUN $user FLUSHDB")

        if [[ ${replies[0]:-} != OK ]]; then
            echo "$user may not use its own keys on Redis $name"
            return
        fi

        if [[ ${replies[1]:-} == OK || ${replies[2]:-} == OK ]]; then
            echo "$user may use other domains' keys or FLUSHDB on Redis $name"
            return
        fi
    done
}

# redis_set_user <user> <password>: creates or resets a domain's user on both
# instances and saves it to their ACL files. Prints what it does without the
# password.
redis_set_user() {
    local user=$1 password=$2 instance replies
    refuse_in_check_mode 'ACL SETUSER'

    for instance in "${redis_instances[@]}"; do
        printf '          $ ACL SETUSER %s reset on >(password from shared/.env) ~%s:* &%s:* +@all -@dangerous  (Redis %s)\n' \
            "$user" "$user" "$user" "${instance%%:*}"

        replies=$(redis_admin "${instance##*:}" \
            "ACL SETUSER $user reset on >$password ~$user:* &$user:* +@all -@dangerous" \
            'ACL SAVE') || die "Could not log in to Redis ${instance%%:*} as admin."

        if [[ $replies != $'OK\nOK' ]]; then
            die "Redis ${instance%%:*} refused the user $user: $replies"
        fi
    done
}

# --- Supervisor (use-horizon, setup-reverb, use-reverb) ----------------------

# program_status <program>: Supervisor's status line for the program, once it
# is no longer STARTING (it is for a second or so after a start), or nothing
# when Supervisor has not loaded it. Does not wait in --check mode.
program_status() {
    local status=''

    for _ in 1 2 3 4 5; do
        status=$(supervisorctl status "$1" 2> /dev/null || true)
        if [[ $status != *STARTING* ]] || $check_only; then
            break
        fi
        sleep 1
    done

    printf '%s' "$status"
}

# --- Reverb (setup-reverb, use-reverb, add-domain) ---------------------------
#
# One shared Reverb server, run from one domain whose app has laravel/reverb
# (setup-reverb), with one Reverb app per domain that broadcasts (use-reverb).
# Reverb listens on localhost only: browsers reach it through nginx (wss on
# 443 at /app/ on the Reverb domain), and the apps on this server publish to
# it directly. setup-reverb records where it runs in $reverb_conf.

reverb_conf=/etc/deploy-kit/reverb.conf

# reverb_setting <name>: user, domain, port, php or apps from $reverb_conf,
# or nothing.
reverb_setting() {
    sed -n "s/^$1=//p" "$reverb_conf" 2> /dev/null | tail -n 1
}

# random_token <length>: lower-case letters and digits, like Reverb's own
# app keys and secrets.
random_token() {
    local characters
    characters=$(openssl rand -base64 96 | tr -dc 'a-z0-9')
    printf '%s' "${characters:0:$1}"
}

# reverb_api <port> <app id> <key> <secret> <path>: a GET request to Reverb's
# HTTP API on localhost, signed with the app's secret as the app's
# broadcaster signs them (Pusher protocol). Prints the reply's body, then its
# status code on a line of its own (000 when nothing answers). The secret
# goes to PHP ($php_bin) over stdin, so it shows up neither in the process
# list nor in this output.
reverb_api() {
    local port=$1 key=$3 secret=$4 path="/apps/$2$5" query signature
    query="auth_key=$key&auth_timestamp=$(date +%s)&auth_version=1.0"

    # shellcheck disable=SC2016
    signature=$({ printf '%s\n' "$secret"; printf 'GET\n%s\n%s' "$path" "$query"; } \
        | "$php_bin" -r '$secret = rtrim(fgets(STDIN), "\n"); echo hash_hmac("sha256", stream_get_contents(STDIN), $secret);')

    curl -sS --max-time 10 -w '\n%{http_code}' "http://127.0.0.1:$port$path?$query&auth_signature=$signature" 2> /dev/null || true
}

# reverb_first_event <url> <domain>: opens a WebSocket connection to <url>
# (https://<Reverb domain>/app/<key>) the way a browser on https://<domain>
# would, and prints the first event Reverb sends: pusher:connection_established
# when it accepts the key and the origin, pusher:error when it refuses them,
# nothing when nothing answers. Takes 3 seconds.
reverb_first_event() {
    local frames
    frames=$(curl -sS -N --http1.1 --max-time 3 \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" -H "Origin: https://$2" \
        "$1?protocol=7&client=deploy-kit&version=1.0&flash=false" 2> /dev/null | tr -d '\0' || true)

    grep -ao '"event":"[^"]*"' <<< "$frames" | head -n 1 | cut -d '"' -f 4 || true
}
