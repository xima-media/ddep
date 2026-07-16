#!/usr/bin/env bats
#
# Black-box tests drive the CLI; white-box tests source the script (the sourcing
# guard stops it before the CLI runs) and exercise individual functions.

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

@test "no command exits 1 with guidance" {
    run "$DDEP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No command provided"* ]]
}

@test "unknown argument exits 1" {
    run "$DDEP" frobnicate
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown argument"* ]]
}

@test "--host without a value exits 1" {
    run "$DDEP" --host
    [ "$status" -eq 1 ]
    [[ "$output" == *"--host requires a value"* ]]
}

@test "--host followed by an option is rejected" {
    run "$DDEP" --host --debug logs
    [ "$status" -eq 1 ]
    [[ "$output" == *"--host requires a value"* ]]
}

@test "--env without a value exits 1" {
    run "$DDEP" --env
    [ "$status" -eq 1 ]
    [[ "$output" == *"--env requires a value"* ]]
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

@test "load_config deep-merges local config over the built-in defaults" {
    run bash -c '
        source "$DDEP"
        LOCAL_CONFIG_FILE="$FIXTURES/local.json"
        load_config
        jq -r "
            .mariadb_version,
            .environments_path,
            (.settings.symfony.db.exclude_tables | length),
            .settings.symfony.db.exclude_tables[0],
            (.settings.symfony.db.migration | length > 0),
            (.settings.typo3 | type)
        " "$CONFIG_FILE"
    '
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "11.4" ]                 # scalar override applied
    [ "${lines[1]}" = "/opt/docker/compose" ] # default preserved
    [ "${lines[2]}" = "2" ]                    # array replaced, not appended (default had 1)
    [ "${lines[3]}" = "^only_this$" ]          # replaced with local content
    [ "${lines[4]}" = "true" ]                 # sibling default (migration) preserved
    [ "${lines[5]}" = "object" ]               # unrelated app (typo3) preserved
}
