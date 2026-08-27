# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `db:pull`/`db:push` no longer inherit `DOCKER_HOST` from the surrounding
  ddep process. Every command exports `DOCKER_HOST=ssh://<remote host>`
  before dispatch (for the remote side); `db:pull`/`db:push`'s `ddev
  import-db`/`ddev exec -s db` calls ran in that same process/pipeline and
  inherited it, so ddev's own internal docker calls queried the *remote*
  daemon instead of the local one its db container actually runs on -
  confirmed against a real run: `ddev-hostname` tried to map the local
  project's hostname to the remote host's IP. Fixed the same way `run_yq`'s
  Docker fallback already guards against this: `DOCKER_HOST=''` on each call.
- `db:export`/`db:import` now pin `--default-character-set=utf8mb4` on every
  `mariadb-dump`/`mariadb` invocation - without it, the client library's own
  default (`latin1`) silently mangled multi-byte UTF-8 content on the way
  through. Confirmed against a real dump containing German typographic
  quotes: the corruption wasn't just mojibake, it produced stray bytes that
  broke SQL statement quoting on re-import (a value's content could get
  misread as a new statement, or even as one of the `mariadb` CLI's own
  backslash meta-commands).
- `db:import` imports with `mariadb --force` - a dump from anywhere other than
  this same app's own `db:export` (a plain mariadb-dump, `ddev export-db`, ...) can
  carry a statement this connection's user can't run as-is, e.g. a view's
  `CREATE` with a `DEFINER` from wherever it was dumped, which fails with
  "Access denied; you need ... SET USER ... privilege" for any other user.
  Without `--force`, that error aborted the whole import before the
  post-import migration (which is what actually re-creates such a view
  correctly) ever ran.
- `db:export`'s table exclusion is now split into two independent settings:
  `exclude_rows` (schema kept, only rows skipped - the old `exclude_tables`
  behavior, for live per-environment state like `sessions` that the app's own
  migration doesn't necessarily recreate) and `exclude_tables` (dropped
  entirely, structure and data both - for a table/view that shouldn't exist
  outside its origin environment at all, e.g. one whose `CREATE VIEW` carries
  a `DEFINER` tied to that server). The built-in defaults for both apps moved
  from `exclude_tables` to `exclude_rows`, since none of them need full
  removal by default.
- **Breaking:** flags must now come before the command (e.g. `ddep --force
  db:import dev x`, not `ddep db:import dev x --force`) - previously `ssh` silently
  swallowed any flags placed after it into the remote command instead of
  parsing them (`ddep ssh --env x` ran `--env x` inside the container rather
  than setting the environment, found via real use), and other commands
  quietly accepted trailing flags in a way the docs never actually promised
  consistently. Flags-first removes the ambiguity entirely instead of just
  patching around it for `ssh`, and matches how docker-compose-deploy's own
  `ci/reset.yml` already invokes `ddep` everywhere.

### Changed

- **Breaking:** `--host`/`--env` are gone; host and environment are now
  positional, after the command (`ddep db:import dev feature_xyz`, not `ddep
  --host dev --env feature_xyz db:import`). Both stay optional everywhere they
  were before (host defaults to `dev`, environment falls back to the
  interactive picker), except `exec` (see below) and `config` (takes neither).
  Migration: replace `--host X --env Y <command>` with `<command> X Y`
  throughout - CI pipelines, wrapper scripts, and any documentation.
- **Breaking:** `ssh` no longer takes a trailing remote command at all -
  it now only ever opens an interactive shell (`ddep ssh [host]
  [environment]`). Running a specific command remotely is a new, separate
  `exec` command instead: `ddep exec <host> <environment> <command>` (all
  three required - quote `<command>` as one argument if it contains spaces).
  Splitting them out removes an unavoidable ambiguity that optional positional
  host/environment would otherwise create for `ssh` alone (e.g. is `ddep ssh
  bash` `host=bash`, or the remote command `bash` with default host/
  environment?) - `exec`'s three required positions have no such ambiguity.
  Migration: `ddep --host dev ssh "some command"` becomes `ddep exec dev
  <environment> "some command"` - environment must now be given explicitly,
  where it previously could fall back to the interactive picker.
- **Breaking:** `db:pull`/`db:push` renamed to `db:export`/`db:import`
  respectively, to free up the `db:pull`/`db:push` names for two new local-dev
  convenience commands (see Added).
- **Breaking:** database credentials are now read from a single fixed set of
  env var names in the remote `.app.env.provision` file - `MARIADB_HOST`,
  `MARIADB_PORT`, `MARIADB_DBNAME`, `MARIADB_USER`, `MARIADB_PASSWORD` -
  instead of per-application names (`TYPO3_CONF_VARS__DB__Connections__
  Default__*` for typo3, `SYMFONY_DATABASE_*` for symfony). The per-app
  `settings.<app>.db.env` override key is gone along with it - it was the
  only reason the two apps' `db` defaults differed at all beyond
  `migration`/`exclude_tables`. Migration: before upgrading, make sure every
  environment's `.app.env.provision` is regenerated to also set the
  `MARIADB_*` names (e.g. as aliases alongside whatever app-specific names
  your provisioning already writes) - `db:export`/`db:import`/`ssh` fail against
  any environment whose `.app.env.provision` doesn't have them yet.
- **Breaking:** `app`, host connection info, and `compose_projects_root`
  (`ddep.json`'s former `environments_path` - renamed for consistency with
  docker-compose-deploy's own field name for the same directory) now come
  exclusively from `.docker/hosts.yaml` (the Ansible inventory the
  "docker-compose-deploy" GitLab CI template already requires) - `.docker/
  ddep.json`'s own `app`/`hosts`/`compose_projects_root` keys are no longer
  read at all, not even as a fallback (a warning is printed if a project's
  `ddep.json` still sets any of them, and all are ignored).
  `compose_projects_root` specifically: required in `all.vars`, no built-in
  default, never a `ddep.json` value. `.docker/hosts.yaml` is now required;
  `ddep.json` becomes fully optional, scoped only to per-application setting
  overrides (`settings.<app>.*`, `mariadb_version`). Migration: move `app`/
  `hosts`/`compose_projects_root` out of `ddep.json` into `.docker/
  hosts.yaml`'s `all.vars.app_name`/`all.vars.compose_projects_root` and
  `all.children.<dev|test|live>.hosts.<key>.ansible_user`/`ansible_host` -
  see the README's Setup section for the full format.
- Every individual host in a multi-host group (e.g. several SaaS customers
  under `live`) is now addressable by its own hosts.yaml key (`ddep ssh
  customer_a`), not just collapsed into one entry per `dev`/`test`/`live`
  slug - `ddep.json`'s old schema had no way to express more than one host
  per slug at all.

### Added

- Colored output when stderr is a terminal (same codes as
  docker-compose-deploy's own `deploy.sh`: red for errors, yellow for
  warnings, cyan for the "Using host/environment" line) - plain otherwise
  (piped output, a CI log file, bats' test capture, etc.), verified against a
  real pty.
- An unrecognized host or environment now falls back to an interactive "not
  found, did you mean?" picker (same mechanism as the existing "none given"
  picker) instead of failing outright - `select_host` for the host argument
  (checked against `.docker/hosts.yaml`), reusing `select_env` with the
  invalid value for the environment argument (checked against what's actually
  deployed on the host). Still fails immediately, same as before, when no
  terminal is available (CI/pipe).
- Every command that resolves a host/environment now prints "Using host
  '<host>', environment '<environment>'." to stderr before running - visible
  feedback for when the host silently defaulted to `dev` or the environment
  was resolved via a picker, without polluting stdout (`db:export`, `db:pull`
  piping into `ddev import-db`, etc. all still get a clean stream). If the
  remote environment's `.env` has `ENVIRONMENT_HOSTNAME_PRIMARY` set, its
  `https://` URL is appended to the same line. Best-effort - a not-yet-deployed
  environment (no `.env` yet) just omits it, never fails the command.
- `info` includes `ENVIRONMENT_HOSTNAME_PRIMARY` in its JSON output alongside
  `container_id`, when the remote environment's `.env` has it set.
- `MARIADB_SSL` (`true`/`false`, optional in `.app.env.provision`, defaults to
  `false`): controls whether `--skip-ssl` is passed to every `mariadb`/
  `mariadb-dump` call (`db:import`/`db:export`, and the `exclude_rows`/
  `exclude_tables` table-name lookup). `false` disables SSL outright,
  suppressing the "option --ssl-verify-server-cert is disabled, because of an
  insecure passwordless login" warning these connections otherwise print by
  default (no CA config to verify a certificate against); `true` leaves the
  client's own default opportunistic-SSL behavior alone rather than forcing
  anything further - genuine certificate verification would additionally need
  `--ssl-ca`, not supported yet.
- `db:pull [host] [environment]` - a thin wrapper around `db:export`, piped
  straight into `ddev import-db` for the ddev project in the current working
  directory. Requires `ddev` on `PATH`.
- `db:push [host] [environment]` - the reverse of `db:pull`: dumps the local
  ddev project's database via `ddev export-db`, then applies this project's
  own `exclude_rows`/`exclude_tables` (same semantics as `db:export`) by
  filtering the dump *text* - matching mariadb-dump's own comment markers to
  find each table/view's structure and data sections, since `ddev export-db`
  has no table-exclusion option of its own - then pipes the result into
  `db:import` against the remote. Requires `ddev` on `PATH`. Verified end to
  end against a real dump: filtered output re-imports cleanly, a
  rows-excluded table exists but empty, a tables-excluded view is entirely
  absent. (An earlier version bypassed `ddev export-db` and ran
  `mariadb-dump` directly inside ddev's db container via `ddev exec` instead
  - abandoned after a real run showed `ddev exec`'s trailing arguments don't
  reach the inner script's `"$@"` the way `docker exec`'s do, so the database
  name never reached mariadb-dump.)
- `exec <host> <environment> <command>` - run a command in the remote
  container, split out from `ssh` (see Changed).
- Reads `.docker/hosts.yaml` via a pinned `mikefarah/yq` Docker image
  rather than requiring a host-installed `yq` binary - avoids depending on a
  tool name ("yq") that resolves to two different, incompatible programs
  depending on the platform's package manager (Debian/Ubuntu's `apt install
  yq` is an unrelated tool from macOS Homebrew's).
- Distribution as a composer package (`xima-media/ddep`), exposing `vendor/bin/ddep`.
- `logs` command to follow the remote application container's log output.
- `-h`/`--help` and `-V`/`--version` flags.
- `--force` flag plus confirmation prompts before destructive remote writes
  (`db:import`, `media:push`); non-`dev` hosts require typing the host slug.
- Preflight check for the required commands and bash >= 4.3.
- Configurable container media path via `rsync.remote_path`.
- EditorConfig, shellcheck configuration, and a bats test suite.
- `db:export` compresses the dump inside the remote container before transfer, and
  `db:import` transfers gzip input unchanged (compressing plain SQL locally) before
  decompressing it in the remote container. This makes large transfers faster
  while preserving support for plain SQL on stdin.

### Fixed

- Neither the database password nor the other secrets held in the remote
  `.app.env.provision` file are echoed to stderr under `--debug`.
- Environment selection and `ssh` work without a controlling terminal (CI-safe).
- `db:import` rejects empty stdin instead of silently importing nothing.
- Clear error when run outside a git working copy or without an `origin` remote.
- `mariadb` image pull failures are surfaced instead of swallowed.
- Successful runs return exit status 0 (the cleanup trap no longer clobbers it).
- Validation of `--host` and `--env` option arguments.
- `db:export` now dumps structure for every table (including ones in
  `exclude_tables`) and only omits data for excluded ones, so a table like
  `sessions` still exists after `db:import` on a brand-new environment that
  never had it before.
- Accurate documentation of `ssh` argument handling.

[Unreleased]: https://github.com/xima-media/ddep/commits/main
