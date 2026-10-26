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

# Runs a command that changes the server, printing it first.
run() {
    if $check_only; then
        die "internal: '$1' would change the server in --check mode."
    fi

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

# user_field <user> <field>: one field of v-list-user, or nothing.
user_field() {
    v-list-user "$1" json | jq -r --arg u "$1" --arg f "$2" '.[$u][$f] // ""'
}
