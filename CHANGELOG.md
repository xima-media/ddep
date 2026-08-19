# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Breaking:** flags must now come before the command (e.g. `ddep --host dev
  --env x db:push`, not `ddep db:push --env x`) - previously `ssh` silently
  swallowed any flags placed after it into the remote command instead of
  parsing them (`ddep ssh --env x` ran `--env x` inside the container rather
  than setting the environment, found via real use), and other commands
  quietly accepted trailing flags in a way the docs never actually promised
  consistently. Flags-first removes the ambiguity entirely instead of just
  patching around it for `ssh`, and matches how docker-compose-deploy's own
  `ci/reset.yml` already invokes `ddep` everywhere.

### Changed

- **Breaking:** `app`, host connection info, and `compose_projects_root`
  (`ddep.json`'s former `environments_path` - renamed for consistency with
  docker-compose-deploy's own field name for the same directory) now come
  exclusively from `.docker/hosts.yaml` (the Ansible inventory the
  "docker-compose-deploy" GitLab CI template already requires) - `.docker/
  ddep.json`'s own `app`/`hosts`/`compose_projects_root` keys are no longer
  read at all, not even as a fallback (a warning is printed if a project's
  `ddep.json` still sets any of them, and all are ignored).
  `compose_projects_root` specifically: `all.vars.compose_projects_root` wins
  whenever it's set, falling back to the built-in default when it isn't -
  never to a `ddep.json` value. `.docker/hosts.yaml` is now required;
  `ddep.json` becomes fully optional, scoped only to per-application setting
  overrides (`settings.<app>.*`, `mariadb_version`). Migration: move `app`/
  `hosts`/`compose_projects_root` out of `ddep.json` into `.docker/
  hosts.yaml`'s `all.vars.app_name`/`all.vars.compose_projects_root` and
  `all.children.<dev|test|live>.hosts.<key>.ansible_user`/`ansible_host` -
  see the README's Setup section for the full format.
- Every individual host in a multi-host group (e.g. several SaaS customers
  under `live`) is now addressable by its own hosts.yaml key (`--host
  customer_a`), not just collapsed into one entry per `dev`/`test`/`live`
  slug - `ddep.json`'s old schema had no way to express more than one host
  per slug at all.

### Added

- Reads `.docker/hosts.yaml` via a pinned `mikefarah/yq` Docker image
  rather than requiring a host-installed `yq` binary - avoids depending on a
  tool name ("yq") that resolves to two different, incompatible programs
  depending on the platform's package manager (Debian/Ubuntu's `apt install
  yq` is an unrelated tool from macOS Homebrew's).
- Distribution as a composer package (`xima-media/ddep`), exposing `vendor/bin/ddep`.
- `logs` command to follow the remote application container's log output.
- `-h`/`--help` and `-V`/`--version` flags.
- `--force` flag plus confirmation prompts before destructive remote writes
  (`db:push`, `media:push`); non-`dev` hosts require typing the host slug.
- Preflight check for the required commands and bash >= 4.3.
- Configurable container media path via `rsync.remote_path`.
- EditorConfig, shellcheck configuration, and a bats test suite.
- `db:pull` compresses the dump inside the remote container before transfer, and
  `db:push` transfers gzip input unchanged (compressing plain SQL locally) before
  decompressing it in the remote container. This makes large transfers faster
  while preserving support for plain SQL on stdin.

### Fixed

- Neither the database password nor the other secrets held in the remote
  `.app.env.provision` file are echoed to stderr under `--debug`.
- Environment selection and `ssh` work without a controlling terminal (CI-safe).
- `db:push` rejects empty stdin instead of silently importing nothing.
- Clear error when run outside a git working copy or without an `origin` remote.
- `mariadb` image pull failures are surfaced instead of swallowed.
- Successful runs return exit status 0 (the cleanup trap no longer clobbers it).
- Validation of `--host` and `--env` option arguments.
- `db:pull` now dumps structure for every table (including ones in
  `exclude_tables`) and only omits data for excluded ones, so a table like
  `sessions` still exists after `db:push` on a brand-new environment that
  never had it before.
- Accurate documentation of `ssh` argument handling.

[Unreleased]: https://github.com/xima-media/ddep/commits/main
