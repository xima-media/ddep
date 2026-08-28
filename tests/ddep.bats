#!/usr/bin/env bats
#
# Black-box tests drive the CLI; white-box tests source the script (the sourcing
# guard stops it before the CLI runs) and exercise individual functions.

bats_require_minimum_version 1.5.0

setup() {
    export DDEP="${BATS_TEST_DIRNAME}/../bin/ddep"
    export FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
}

# --- CLI surface (no docker/remote needed; these paths exit before the preflight)

@test "--version prints the version and exits 0" {
    run "$DDEP" --version
    [ "$status" -eq 0 ]
    [[ "$output" == ddep\ * ]]
}

@test "--help prints usage and exits 0" {
    run "$DDEP" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "no command exits 1 with usage" {
    run "$DDEP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "unknown argument exits 1" {
    run "$DDEP" frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "a flag after the command is rejected, not silently absorbed" {
    run "$DDEP" logs --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"flags must come before the command"* ]]
}

@test "positional host/environment after the command parse as such, not as unexpected arguments" {
    # No git repo in BATS_TEST_TMPDIR - if host/environment parsed correctly,
    # arg parsing succeeds and it fails later, for an unrelated reason (no git
    # repo). Distinguishes a regression back to "flags must come before the
    # command"/"unexpected argument(s)" ever firing here, which it must not.
    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" ssh dev dwis-3442'
    [ "$status" -eq 1 ]
    [[ "$output" != *"unexpected argument"* ]]
    [[ "$output" == *"could not determine the project name"* ]]
}

@test "ssh rejects more than two positional arguments" {
    run "$DDEP" ssh dev dwis-3442 extra
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected at most <host> <environment>"* ]]
}

@test "exec requires exactly host, environment, and command" {
    run "$DDEP" exec dev
    [ "$status" -eq 1 ]
    [[ "$output" == *"exec requires exactly <host> <environment> <command>"* ]]

    run "$DDEP" exec dev dwis-3442
    [ "$status" -eq 1 ]
    [[ "$output" == *"exec requires exactly <host> <environment> <command>"* ]]

    run "$DDEP" exec dev dwis-3442 "echo hi" extra
    [ "$status" -eq 1 ]
    [[ "$output" == *"exec requires exactly <host> <environment> <command>"* ]]
}

@test "exec with host, environment, and command parses as such, not as unexpected arguments" {
    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" exec dev dwis-3442 "echo hi"'
    [ "$status" -eq 1 ]
    [[ "$output" != *"unexpected argument"* ]]
    [[ "$output" == *"could not determine the project name"* ]]
}

@test "db:pull/db:push are recognized commands, not misread as unexpected arguments" {
    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" db:pull dev dwis-3442'
    [ "$status" -eq 1 ]
    [[ "$output" != *"unexpected argument"* ]]
    [[ "$output" == *"could not determine the project name"* ]]

    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" db:push dev dwis-3442'
    [ "$status" -eq 1 ]
    [[ "$output" != *"unexpected argument"* ]]
    [[ "$output" == *"could not determine the project name"* ]]
}

@test "config rejects any positional arguments" {
    run "$DDEP" config extra
    [ "$status" -eq 1 ]
    [[ "$output" == *"config takes no arguments"* ]]
}

@test "config prints the resolved config as JSON, outside a git repo" {
    mkdir -p "$BATS_TEST_TMPDIR/.docker"
    cp "$FIXTURES/local.json" "$BATS_TEST_TMPDIR/.docker/ddep.json"
    cp "$FIXTURES/hosts.yaml" "$BATS_TEST_TMPDIR/.docker/hosts.yaml"
    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" config'
    [ "$status" -eq 0 ]
    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" config | jq -r "
        .app,
        .mariadb_version,
        (.settings.symfony.db.exclude_tables | length),
        (.settings.typo3 | type)
    "'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "symfony" ] # from hosts.yaml - ddep.json no longer sets app/hosts
    [ "${lines[1]}" = "11.4" ]    # ddep.json's own override applied
    [ "${lines[2]}" = "2" ]       # array replaced, not appended
    [ "${lines[3]}" = "object" ]  # unrelated app (typo3) preserved from defaults
}

@test "config exits 1 without .docker/hosts.yaml, even with .docker/ddep.json present" {
    mkdir -p "$BATS_TEST_TMPDIR/.docker"
    cp "$FIXTURES/local.json" "$BATS_TEST_TMPDIR/.docker/ddep.json"
    run bash -c 'cd "$BATS_TEST_TMPDIR" && "$DDEP" config'
    [ "$status" -eq 1 ]
    [[ "$output" == *"hosts.yaml"* ]]
    [[ "$output" == *"missing"* ]]
}

# --- functions (sourced)

@test "get_env_value returns the value for a matching key" {
    run bash -c 'source "$DDEP"; printf "FOO=bar\nBAZ=qux\n" | get_env_value BAZ'
    [ "$status" -eq 0 ]
    [ "$output" = "qux" ]
}

@test "get_env_value returns nothing for a missing key" {
    run bash -c 'source "$DDEP"; printf "FOO=bar\n" | get_env_value NOPE'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# get_mariadb_credentials needs a real external `ssh` stub on PATH (same reason
# as _stub_docker below - a shell-function stub isn't found the same way).
# Responds to the two remote calls the function makes: "test -f ..." (file
# exists) and "cat ..." (its content).
_stub_ssh() {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "$stub/ssh" <<'STUB'
#!/bin/sh
# Every real call is `ssh -n host command` - drop -n if present, so $1 =
# host, $2 = remote command string regardless of whether a future call site
# adds other flags before the host too. SSH_CAT_OUTPUT/SSH_FAIL are read
# from this stub's own inherited environment at invocation time, not baked
# in when the stub is written (the heredoc above is quoted for exactly this
# reason).
[ "$1" = "-n" ] && shift
if [ "$SSH_FAIL" = "true" ]; then
    exit 1
fi
case "$2" in
    test\ -f*) exit 0 ;;
    cat*) printf '%s' "$SSH_CAT_OUTPUT" ;;
esac
STUB
    chmod +x "$stub/ssh"
    echo "$stub"
}

@test "get_mariadb_credentials reads the canonical MARIADB_* names, not per-app ones" {
    local stub; stub="$(_stub_ssh)"
    PATH="$stub:$PATH" SSH_CAT_OUTPUT=$'MARIADB_HOST=10.0.0.8\nMARIADB_DBNAME=mydb\nMARIADB_USER=myuser\nMARIADB_PASSWORD=mypass\nMARIADB_PORT=3307\nMARIADB_SSL=true\nSYMFONY_DATABASE_HOST=should-be-ignored\n' \
        run bash -c '
        source "$DDEP"
        REMOTE_DOCKER_HOST=dummy; COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=staging
        get_mariadb_credentials h n u p port ssl
        echo "HOST=$h NAME=$n USER=$u PASS=$p PORT=$port SSL=$ssl"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"HOST=10.0.0.8 NAME=mydb USER=myuser PASS=mypass PORT=3307 SSL=true"* ]]
}

@test "get_mariadb_credentials defaults the port to 3306 and ssl to false when unset" {
    local stub; stub="$(_stub_ssh)"
    PATH="$stub:$PATH" SSH_CAT_OUTPUT=$'MARIADB_HOST=10.0.0.8\nMARIADB_DBNAME=mydb\nMARIADB_USER=myuser\nMARIADB_PASSWORD=mypass\n' \
        run bash -c '
        source "$DDEP"
        REMOTE_DOCKER_HOST=dummy; COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=staging
        get_mariadb_credentials h n u p port ssl
        echo "PORT=$port SSL=$ssl"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"PORT=3306 SSL=false"* ]]
}

@test "get_environment_hostname_primary strips the surrounding quotes .env writes" {
    local stub; stub="$(_stub_ssh)"
    PATH="$stub:$PATH" SSH_CAT_OUTPUT=$'ENVIRONMENT_ID="proj_dev"\nENVIRONMENT_HOSTNAME_PRIMARY="dev.example.com"\n' \
        run bash -c '
        set -euo pipefail
        source "$DDEP"
        REMOTE_DOCKER_HOST=dummy; COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=dev
        echo "value=[$(get_environment_hostname_primary)]"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"value=[dev.example.com]"* ]]
}

@test "get_environment_hostname_primary is best-effort - an ssh failure yields empty, not a script abort" {
    local stub; stub="$(_stub_ssh)"
    PATH="$stub:$PATH" SSH_FAIL=true \
        run bash -c '
        set -euo pipefail
        source "$DDEP"
        REMOTE_DOCKER_HOST=dummy; COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=dev
        echo "value=[$(get_environment_hostname_primary)]"
        echo "reached-after"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *"value=[]"* ]]
    [[ "$output" == *"reached-after"* ]]
}

# Real ssh reads (and discards) from its inherited stdin to set up the
# session, even for a no-input remote command like `true`/`cat somefile` -
# unless called with -n. Every ssh call in bin/ddep runs while this
# process's own stdin could be a caller's real piped stream (e.g.
# db:import's dump) - confirmed as the actual cause of intermittent
# db:import corruption, silently eating megabytes off the front of the
# stream before db:import's own stdin read even began. This stub
# reproduces that specific behavior (not the canned-output one _stub_ssh
# provides) so a future ssh call that forgets -n fails these tests instead
# of shipping.
_stub_ssh_stdin_guard() {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "$stub/ssh" <<'STUB'
#!/bin/sh
has_n=0
for arg in "$@"; do
    [ "$arg" = "-n" ] && has_n=1
done
[ "$has_n" = "1" ] || dd bs=1024 count=1 of=/dev/null 2>/dev/null
exit 0
STUB
    chmod +x "$stub/ssh"
    echo "$stub"
}

@test "get_environment_hostname_primary's ssh call does not consume piped stdin" {
    local stub; stub="$(_stub_ssh_stdin_guard)"
    local payload; payload="$(head -c 100000 /dev/zero | tr '\0' 'X')"
    PATH="$stub:$PATH" run bash -c '
        source "$DDEP"
        REMOTE_DOCKER_HOST=dummy; COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=dev
        get_environment_hostname_primary >/dev/null
        cat
    ' <<< "$payload"
    [ "$status" -eq 0 ]
    [ "$output" = "$payload" ]
}

@test "get_mariadb_credentials's ssh calls do not consume piped stdin" {
    local stub; stub="$(_stub_ssh_stdin_guard)"
    local payload; payload="$(head -c 100000 /dev/zero | tr '\0' 'X')"
    PATH="$stub:$PATH" run bash -c '
        source "$DDEP"
        REMOTE_DOCKER_HOST=dummy; COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=dev
        get_mariadb_credentials h n u p port ssl >/dev/null
        cat
    ' <<< "$payload"
    [ "$status" -eq 0 ]
    [ "$output" = "$payload" ]
}

@test "mariadb_ssl_args adds --skip-ssl unless MARIADB_SSL is true" {
    run bash -c '
        source "$DDEP"
        args=(); mariadb_ssl_args args "false"
        echo "false=${args[*]-}"
        args=(); mariadb_ssl_args args ""
        echo "empty=${args[*]-}"
        args=(); mariadb_ssl_args args "true"
        echo "true=${args[*]-}"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "false=--skip-ssl" ]
    [ "${lines[1]}" = "empty=--skip-ssl" ]
    [ "${lines[2]}" = "true=" ]
}

# get_container_id needs a real external `docker` stub on PATH (a shell-function
# stub would not be found by `command -v`/exec the same way and complicates the
# nameref call). This helper writes one that prints $DOCKER_PS_OUTPUT for `ps`.
_stub_docker() {
    local stub="${BATS_TEST_TMPDIR}/bin"
    mkdir -p "$stub"
    cat > "$stub/docker" <<'STUB'
#!/bin/sh
case "$1" in
    ps) printf '%s' "$DOCKER_PS_OUTPUT"; [ -n "$DOCKER_PS_OUTPUT" ] && printf '\n' ;;
esac
STUB
    chmod +x "$stub/docker"
    echo "$stub"
}

_run_get_container_id() {
    local stub; stub="$(_stub_docker)"
    # Call it the way real callers do — inside a condition, so the sourced
    # `set -e` does not abort on the intended non-zero returns.
    PATH="$stub:$PATH" DOCKER_PS_OUTPUT="$1" run bash -c '
        source "$DDEP"
        COMPOSE_PROJECTS_ROOT=/opt; git_project_name=proj; target_env=staging; APP_NAME=app
        cid=""
        rc=0
        get_container_id cid || rc=$?
        echo "RC=$rc CID=$cid"
        exit "$rc"
    '
}

@test "get_container_id returns 0 and the id for exactly one match" {
    _run_get_container_id "abc123"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RC=0 CID=abc123"* ]]
}

@test "get_container_id returns 1 and reports 'no container' for zero matches" {
    _run_get_container_id ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"no container found"* ]]
}

@test "get_container_id returns 2 and reports 'multiple' for more than one match" {
    _run_get_container_id "$(printf 'aaa\nbbb')"
    [ "$status" -eq 2 ]
    [[ "$output" == *"multiple containers matched"* ]]
    [[ "$output" != *"no container found"* ]]
}

@test "load_config deep-merges local config over the built-in defaults" {
    run bash -c '
        source "$DDEP"
        HOSTS_FILE="$FIXTURES/hosts.yaml"
        LOCAL_CONFIG_FILE="$FIXTURES/local.json"
        load_config
        jq -r "
            .mariadb_version,
            .compose_projects_root,
            (.settings.symfony.db.exclude_tables | length),
            .settings.symfony.db.exclude_tables[0],
            (.settings.symfony.db.migration | length > 0),
            (.settings.typo3 | type)
        " "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "11.4" ]                 # scalar override applied
    [ "${lines[1]}" = "/opt/docker/compose" ] # hosts.yaml's own value, untouched by local.json
    [ "${lines[2]}" = "2" ]                    # array replaced, not appended (default had 0)
    [ "${lines[3]}" = "^only_this$" ]          # replaced with local content
    [ "${lines[4]}" = "true" ]                 # sibling default (migration) preserved
    [ "${lines[5]}" = "object" ]               # unrelated app (typo3) preserved
}

# --- .docker/hosts.yaml integration

@test "load_hosts_config derives app and per-host addressing from hosts.yaml" {
    run bash -c '
        source "$DDEP"
        HOSTS_FILE="$FIXTURES/hosts.yaml"
        load_hosts_config
    '
    [ "$status" -eq 0 ]
    run bash -c "echo '$output' | jq -r '
        .app,
        .hosts.dev,
        .hosts.test,
        .hosts.customer_a,
        .hosts.customer_b,
        .hosts.live
    '"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "symfony" ]                        # all.vars.app_name
    [ "${lines[1]}" = "dev-user@dev-host" ]               # dev's one host (key "shared", deliberately != "dev") - tier default works regardless of the host's own key name
    [ "${lines[2]}" = "test-user@test-host" ]             # test's one host (key "test") - tier default
    [ "${lines[3]}" = "customer-a-user@customer-a-host" ] # addressable by its own key, not just via "live"
    [ "${lines[4]}" = "customer-b-user@customer-b-host" ] # ditto - never collapsed into one "live" entry
    [ "${lines[5]}" = "customer-a-user@customer-a-host" ] # tier default = FIRST host in file order (customer_a)
}

@test "load_hosts_config returns {} when hosts.yaml doesn't exist" {
    run bash -c '
        source "$DDEP"
        HOSTS_FILE="$BATS_TEST_TMPDIR/.docker/hosts.yaml"
        load_hosts_config
    '
    [ "$status" -eq 0 ]
    [ "$output" = "{}" ]
}

@test "load_config uses hosts.yaml's app/hosts when .docker/ddep.json is absent" {
    run bash -c '
        source "$DDEP"
        HOSTS_FILE="$FIXTURES/hosts.yaml"
        LOCAL_CONFIG_FILE="$BATS_TEST_TMPDIR/.docker/ddep.json"
        load_config
        jq -r ".app, .hosts.customer_b, .mariadb_version" "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "symfony" ]     # from hosts.yaml, no ddep.json needed at all
    [ "${lines[1]}" = "customer-b-user@customer-b-host" ]
    [ "${lines[2]}" = "lts" ]         # built-in default, untouched by either file
}

@test "load_config: compose_projects_root is required, no built-in default" {
    run bash -c '
        source "$DDEP"
        HOSTS_FILE="$FIXTURES/hosts.yaml"
        LOCAL_CONFIG_FILE="$BATS_TEST_TMPDIR/.docker/ddep.json"
        load_config
        jq -r ".compose_projects_root" "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "/opt/docker/compose" ] # hosts.yaml's own explicit value

    run bash -c '
        source "$DDEP"
        HOSTS_FILE="$FIXTURES/hosts_custom_root.yaml"
        LOCAL_CONFIG_FILE="$BATS_TEST_TMPDIR/.docker/ddep.json"
        load_config
        jq -r ".compose_projects_root" "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "$output" = "/srv/apps" ]

    mkdir -p "$BATS_TEST_TMPDIR/.docker"
    cat > "$BATS_TEST_TMPDIR/.docker/hosts_no_root.yaml" <<'YAML'
all:
  vars:
    app_name: symfony
  children:
    dev:
      hosts:
        dev:
          ansible_host: dev-host
          ansible_user: dev-user
YAML
    # validate_config directly, not `ddep config` - that command deliberately
    # skips validation, so a still-incomplete config can be inspected.
    run --separate-stderr bash -c '
        source "$DDEP"
        HOSTS_FILE="$BATS_TEST_TMPDIR/.docker/hosts_no_root.yaml"
        LOCAL_CONFIG_FILE="$BATS_TEST_TMPDIR/.docker/ddep.json"
        load_config
        validate_config
    '
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"compose_projects_root"* ]]
}

@test "load_config: ddep.json is not allowed to override app/hosts/compose_projects_root - hosts.yaml wins, with a warning" {
    run --separate-stderr bash -c '
        source "$DDEP"
        HOSTS_FILE="$FIXTURES/hosts.yaml"
        LOCAL_CONFIG_FILE="$FIXTURES/local_with_legacy_hosts.json"
        load_config
        jq -r ".app, .hosts.dev, .hosts.customer_a, .compose_projects_root, .mariadb_version" "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "symfony" ]
    [ "${lines[1]}" = "dev-user@dev-host" ]                # hosts.yaml's value, NOT local_with_legacy_hosts.json's "user@dev-host"
    [ "${lines[2]}" = "customer-a-user@customer-a-host" ]  # hosts.yaml's own multi-host entry, untouched
    [ "${lines[3]}" = "/opt/docker/compose" ]              # hosts.yaml's own value - NOT local_with_legacy_hosts.json's "/legacy/path"
    [ "${lines[4]}" = "11.4" ]                             # non-app/hosts/compose_projects_root overrides from ddep.json still apply
    [[ "$stderr" == *"ignored"* ]]                         # warns that ddep.json's app/hosts/compose_projects_root were ignored
}
