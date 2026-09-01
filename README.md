# ddep

Developer tooling for access to containerised environments.

`ddep` pushes/pulls media and database dumps between your local machine and
a remote Docker Compose environment over SSH, and lets you open a shell in the
remote application container.

## Requirements

**Local machine:** `bash` >= 4.3, `jq`, `docker`, `ssh`, `rsync`, `gzip`.

- macOS ships bash 3.2 by default. Install a modern bash (`brew install bash`)
  and make sure it precedes `/bin/bash` on your `PATH`, or the script fails with
  cryptic errors (it uses `mapfile`, namerefs, and `${var,,}`).
- Must be run from inside the project's git working copy — the project name
  and remote docker-compose directory are derived from `git remote get-url origin`.
- Passwordless SSH access to the target host is required, since every command
  makes at least one SSH/Docker-over-SSH round trip.
- `.docker/hosts.yaml` must exist, declaring at least `app_name` and one
  host — see [Setup](#setup) below. No other local `yq` install needed;
  reading it runs a pinned Docker image instead (see Setup).

## Installation

### As a composer package (recommended)

ddep is distributed as a composer package and pinned per project, so every
developer and every CI job runs the exact version the project was tested with.

It is **not** published on Packagist — add the repository explicitly, then
require it as a dev dependency:

```json
{
  "repositories": [
    { "type": "vcs", "url": "git@github.com:xima-media/ddep.git" }
  ]
}
```

```sh
composer require --dev xima-media/ddep:^1.0
```

This exposes the binary as `vendor/bin/ddep`. Releases are cut as git tags, so
`composer.lock` binds the tool version to the project.

For local ergonomics with ddev, add a host-scoped custom command that forwards
to the pinned binary (runs on the host, where docker/ssh/agent already live):

# .ddev/commands/host/ddep
```sh
#!/usr/bin/env bash

## Description: Run ddep against a remote environment
## Usage: ddep [options] <command> [host] [environment]

exec "${DDEV_APPROOT}/vendor/bin/ddep" "$@"
```

### Standalone

Clone the repo (or copy `bin/ddep`) somewhere on your `PATH` and call it
directly — the script is self-contained and location-independent.

## Setup

In the root of your project, create `.docker/hosts.yaml` — a plain
Ansible inventory (the same file the ["docker-compose-deploy" GitLab CI
template](https://git.xintern.de/typo3/intern/devops/docker-compose-deploy)
requires, if your project uses it):

```yaml
all:
  vars:
    app_name: symfony   # required - "typo3" or "symfony"
  children:
    dev:
      hosts:
        dev:
          ansible_host: dev-host
          ansible_user: user
    test:
      hosts:
        test:
          ansible_host: test-host
          ansible_user: user
    live:
      hosts:
        live:
          ansible_host: live-host
          ansible_user: user
```

`app_name` must be `typo3` or `symfony` — these are the two application types
with built-in defaults (migration command, rsync directories/excludes). DB
credentials themselves are read from a fixed set of env var names
(`MARIADB_HOST`/`MARIADB_PORT`/`MARIADB_DBNAME`/`MARIADB_USER`/
`MARIADB_PASSWORD`) in the remote `.app.env.provision` file, the same for
every app - see [Security](#security). `ddep` derives its own connection info
from this file:

`MARIADB_SSL` (`true`/`false`, optional in that same file - defaults to
`false`) controls only whether `--skip-ssl` is passed to every `mariadb`/
`mariadb-dump` call: `false` disables SSL outright (suppresses the client's
"option --ssl-verify-server-cert is disabled, because of an insecure
passwordless login" warning, which fires by default since these connections
carry no CA config to verify a certificate against); `true` leaves the
client's own default (opportunistic SSL, verification still silently
disabled the same way) alone rather than forcing anything further - genuine
certificate verification would additionally need `--ssl-ca`, not supported
by `ddep` today.

- `app` ← `all.vars.app_name`
- every host is addressable by its own hosts.yaml key as the `host` argument —
  e.g. `ddep ssh customer_a` for one of several hosts under a `live` group
  (`all.children.live.hosts.customer_a`, `.customer_b`, ...)
- `dev`/`test`/`live` also work as a convenience default, resolving to
  the **first** host declared under that group, in file order. Reliable only
  for a genuinely single-host group — once a group has more than one host,
  address the one you mean by its own key instead (see above); which host
  `live` happens to mean on a multi-host group is an implementation
  detail (file order), not something to rely on.

This is the **only** place `app`, host connection info, and
`compose_projects_root` (the remote docker-compose base directory) come from —
all three required, and `ddep.json` (below) can no longer set or override any
of them, even as a fallback. This is deliberate: exactly one file owns "which
app template," "how do I connect to this host," and "where do deployed
environments live," so it can never silently disagree with itself.

No new local dependency is required to read it: `ddep` prefers a verified
host-installed [`mikefarah/yq`](https://github.com/mikefarah/yq) and otherwise
runs the pinned Docker image. This matters because "yq" is not one tool across
platforms — e.g. Debian/Ubuntu's `apt install yq` installs an unrelated Python
package ([kislyuk/yq](https://github.com/kislyuk/yq)) with different syntax
and flags. Verifying the local implementation and pinning the fallback image
avoid accidentally invoking that incompatible tool.

### `.docker/ddep.json` (optional)

Everything **except** `app`, hosts, and `compose_projects_root` — per-application
setting overrides, `mariadb_version` — can optionally be set in
`.docker/ddep.json`:

```json
{
  "mariadb_version": "11.4",
  "settings": {
    "symfony": {
      "db": {
        "exclude_rows": ["^sessions$"],
        "exclude_tables": ["^v_media_references_info$"]
      }
    }
  }
}
```

See [examples/typo3/](examples/typo3/) and [examples/symfony/](examples/symfony/)
for full examples of both files together, including a multi-host `live` group
in the symfony example. A project that needs no per-application overrides at
all doesn't need a `ddep.json` file — `.docker/hosts.yaml` alone is
enough for `ddep` to run (see [examples/typo3/ddep.json](examples/typo3/ddep.json),
deliberately empty).

### Config options

| Key                       | Required | Description |
|---------------------------|:--------:|--------------|
| `compose_projects_root`   | yes | Remote docker-compose base directory. Set in `.docker/hosts.yaml`'s `all.vars.compose_projects_root` - no built-in default, never read from `.docker/ddep.json` |
| `mariadb_version`         | no  | MariaDB image tag used for dump/restore. Default: `lts` |
| `settings.<app>.*`        | no  | Overrides any built-in setting for that application — see below |

Everything is deep-merged over the script's built-in defaults, so you only
need to specify what differs from the defaults for your `app`.

### Overrides

There is a single, standardised way to override any default application
setting: set the same key, at the same path, under `settings.<app>` in
your local config. Whatever you set there **fully replaces** the built-in
default at that path — objects are merged key by key, but arrays and scalars
are replaced outright, never appended to or merged element-by-element.

The built-in defaults for each application (`db.migration`, `db.exclude_rows`,
`db.exclude_tables`, `rsync.max_size_mb`, `rsync.remote_path`,
`rsync.directories`, `rsync.exclude_paths`, `rsync.exclude_extensions`) live in
`load_default_config()` inside `bin/ddep` — copy the path you want to change
from there.

`rsync.remote_path` is the media directory inside the application container
(default `/var/www/html/app/public`); override it if your image lays out the
document root differently.

For example, to replace the built-in `db:export` table-exclude lists for `symfony`:

```json
{
  "app": "symfony",
  "hosts": { "dev": "user@dev-host" },
  "settings": {
    "symfony": {
      "db": {
        "exclude_rows": [
          "^sessions$"
        ],
        "exclude_tables": [
          "^v_media_references_info$"
        ]
      }
    }
  }
}
```

Since this replaces (rather than appends to) the built-in list, include every
table you still want excluded, not just the ones you're adding — each of
`exclude_rows`/`exclude_tables` replaces independently, so overriding one
doesn't affect the other.

`db:export` supports two, independent kinds of table exclusion:

- `exclude_rows` — schema kept, only rows are skipped. Use this for live,
  per-environment state the application's schema still manages (e.g. a
  `sessions` table) — an empty table survives a `db:import` even on a brand-new
  environment, without depending on a migration to recreate it.
- `exclude_tables` — dropped entirely, structure and data both. `db:export`
  doesn't dump it at all, and nothing recreates it afterward: `db.migration`
  (`database:updateschema` for typo3, `doctrine:migrations:migrate` for
  symfony) only replays committed migration *files* — if the table/view was
  never created by one (a hand-written view like `v_media_references_info`
  usually wasn't; it's not something Doctrine's schema tooling generates on
  its own), the target environment simply ends up without it, permanently,
  until something else creates it. Use `exclude_tables` only for something
  you're fine losing entirely, or that you separately guarantee gets recreated.
  If the app needs the table/view to exist, even empty, use `exclude_rows`
  instead — it never depends on a migration running at all.

  To actually guarantee recreation for something like a hand-written view,
  chain a raw-SQL step onto `db.migration` rather than relying on it alone.
  For example, override `db.migration` for `symfony` to replay a checked-in
  `.sql` file via `dbal:run-sql` after the regular migrations:

  ```json
  "migration": "/usr/bin/php bin/console doctrine:migrations:migrate --no-interaction --quiet && /usr/bin/php bin/console dbal:run-sql -- \"$(cat migrations/v_media_references_info.sql)\""
  ```

## Commands

| Command | Description |
|---------|--------------|
| `media:push [host] [env]` | Push local media files to the remote application container |
| `media:pull [host] [env]` | Pull media files from the remote application container |
| `db:import [host] [env]` | Import a database dump (read from stdin, plain SQL or gzip) into the remote database, then run the application's DB migration |
| `db:export [host] [env]` | Export the remote database to stdout, gzip-compressed |
| `db:pull [host] [env]` | Local-dev convenience wrapper: `db:export` piped into `ddev import-db` for the ddev project in the current working directory. Requires `ddev` on `PATH` |
| `db:push [host] [env]` | Local-dev convenience wrapper, the reverse of `db:pull`: dumps the local ddev project's database (same `exclude_rows`/`exclude_tables` filtering as `db:export`) and pipes it into `db:import`. Requires `ddev` on `PATH` |
| `ssh [host] [env]` | Open an interactive shell inside the remote container |
| `exec <host> <env> <cmd>` | Execute a command inside the remote container - all three are required, and `cmd` should be quoted as one argument if it contains spaces |
| `logs [host] [env]` | Follow the remote application container's log output |
| `config` | Print the resolved configuration (built-in defaults, `.docker/hosts.yaml`, and `.docker/ddep.json`, all deep-merged together) as JSON - takes no arguments |
| `info [host] [env]` | Print details about the remote application container as JSON (currently just `container_id`; more may be added) |

`host` and `environment` are positional, after the command, and stay optional
for every command except `exec` (see above) and `config` (takes neither):
`host` defaults to `dev`; `environment`, if omitted, is picked interactively
from the environments currently deployed on `host`. A `host` or `environment`
that doesn't match anything falls back to the same interactive picker ("not
found, did you mean?") instead of failing outright - both still fail
immediately, same as an omitted value, when no terminal is available (CI).
Once resolved, the host/environment actually in use are always printed to
stderr before anything runs.

`db:import` and `media:push` overwrite data in the remote environment and ask for
confirmation before running. On non-`dev` hosts you must type the host slug to
proceed; pass `--force` to skip the prompt (required in CI, where there is no
terminal).

`db:export`/`db:import` compress the dump *before* it crosses the SSH-tunnelled
Docker connection (`mariadb-dump | gzip` runs inside the remote container, and
`db:import` sends the compressed bytes as-is and `gunzip`s them inside the
container too), not just at rest — meaningfully faster for large databases
over a slow or distant link. `db:import` also accepts plain, uncompressed SQL on
stdin (detected automatically) for backward compatibility.

## Options

Options must always come before the command - `host`/`environment`/`cmd` are
positional, after the command, not flags (see [Commands](#commands) above).

| Option | Description |
|--------|--------------|
| `--debug` | Enable bash execution tracing |
| `--force` | Skip the confirmation prompt for destructive operations (`db:import`, `media:push`). Required for non-interactive/CI use |
| `-h`, `--help` | Show usage and exit |
| `-V`, `--version` | Show version and exit |

## Examples

```sh
# Pull media from the test environment
ddep media:pull test development

# Push local media to the dev environment
ddep media:push dev feature_xyz

# Open an interactive shell in the dev application container
ddep ssh dev

# Execute a command inside the dev application container
ddep exec dev feature_xyz "vendor/bin/typo3 list"

# Copy a local file into the dev application container - exec forwards
# stdin (docker exec -i), so a plain redirect works, binary-safe
ddep exec dev feature_xyz "cat > /path/in/container/file" < local-file

# Follow the dev application container's log output
ddep logs dev

# Import a database dump into the dev environment (plain SQL or gzip, both work)
ddep db:import dev feature_xyz < dump.sql.gz

# Export the dev database to a dump file (already gzip-compressed)
ddep db:export dev feature_xyz > dump.sql.gz

# Pipe an existing dump directly into the remote database
cat dump.sql.gz | ddep db:import dev feature_xyz

# Pull the dev database straight into the local ddev project (requires ddev)
ddep db:pull dev feature_xyz

# Push the local ddev project's database to the dev environment (requires ddev)
ddep db:push dev feature_xyz

# Inspect the fully resolved configuration (no git repo, host or env needed)
ddep config
ddep config | jq '.settings.symfony.rsync'

# Get the dev environment's container id (e.g. for reset-job tooling)
ddep info dev feature_xyz | jq -r '.container_id'
```

## Security

Every command talks to the **remote Docker daemon over SSH**
(`DOCKER_HOST=ssh://…`). Docker access is root-equivalent on the target host:
anyone who can reach the daemon can mount the host filesystem, read every
container's secrets, and start privileged containers. The SSH user ddep connects
as therefore has to be in the host's `docker` group (or root), so **granting a
developer ddep access to a host is effectively granting them root on it.**

Weigh this before rolling it out:

- **Restrict production.** Prefer giving developers `dev`/`test` hosts only, and
  keep `live` operations in CI with a dedicated, scoped identity.
- **Reduce blast radius.** Consider fronting the daemon with a
  [docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy) that
  exposes only the API endpoints ddep needs, or rootless Docker on the host.
- **`db:import`/`media:push` overwrite remote data.** They prompt for confirmation
  (type the host slug on non-`dev` hosts); `--force` bypasses that, so treat
  `--force` against a non-`dev` host as a privileged operation.
- **Secrets stay off the command line and out of traces.** The database password
  is read from the remote `.app.env.provision` file and passed via the `MYSQL_PWD`
  environment variable, never as an argument. Both reading that file and using the
  password are excluded from `--debug` tracing, so neither the password nor the
  file's other secrets are echoed.

## Continuous integration

ddep runs in CI as long as you account for the lack of a terminal:

- **Provide SSH access.** The runner needs the private key and the host in its
  `known_hosts` so the `ssh://` Docker connection authenticates non-interactively.
- **Always pass environment explicitly.** Without a TTY there is no interactive
  environment picker; ddep exits with an error asking for it.
- **Pass `--force` for `db:import`/`media:push`.** The confirmation prompt cannot
  be answered without a terminal.
- **Exit codes are reliable.** A successful command returns `0` and any failure
  returns non-zero, so `ddep … && next-step` and pipeline gating behave.

```sh
# Refresh a staging database non-interactively
ddep --force db:import test staging < dump.sql.gz
```

## Troubleshooting

| Message | Cause / fix |
|---------|-------------|
| `bash >= 4.3 required, but running 3.2…` | macOS' default bash. `brew install bash` and put it before `/bin/bash` on your `PATH`. |
| `required command(s) not found on PATH: …` | Install the missing tool(s) (`jq`, `docker`, `rsync`, `ssh`, `gzip`, `git`). |
| `docker: command not found` when run via `ddev exec` | The ddev web container has no docker client. Run ddep on the **host** (where docker, ssh, and your agent live), not inside the container. |
| `could not determine the project name` | Run ddep from inside the project's git working copy; it needs an `origin` remote. |
| `host '…' is not configured` | The host argument isn't declared anywhere under `all.children.*.hosts` in `.docker/hosts.yaml` (ddep.json's own `hosts`, if it has one, is ignored - see Setup). Run `ddep config \| jq .hosts` to see every currently resolvable value. |
| `No container found for project '…' and environment '…'` | Wrong environment, the stack isn't running, or `compose_projects_root`/compose labels don't match. |
| `no environment given and no terminal available` | Non-interactive run (CI/pipe) with no environment argument; pass it explicitly. |
