# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Distribution as a composer package (`xima-media/ddep`), exposing `vendor/bin/ddep`.
- `logs` command to follow the remote application container's log output.
- `-h`/`--help` and `-V`/`--version` flags.
- `--force` flag plus confirmation prompts before destructive remote writes
  (`db:push`, `media:push`); non-`dev` hosts require typing the host slug.
- Preflight check for the required commands and bash >= 4.3.
- Configurable container media path via `rsync.remote_path`.
- EditorConfig, shellcheck configuration, and a bats test suite.

### Fixed

- The database password is no longer echoed to stderr under `--debug`.
- Environment selection and `ssh` work without a controlling terminal (CI-safe).
- `db:push` rejects empty stdin instead of silently importing nothing.
- Clear error when run outside a git working copy or without an `origin` remote.
- `mariadb` image pull failures are surfaced instead of swallowed.
- Successful runs return exit status 0 (the cleanup trap no longer clobbers it).
- Validation of `--host` and `--env` option arguments.
- Accurate documentation of `ssh` argument handling.

[Unreleased]: https://github.com/xima-media/ddep/commits/main
