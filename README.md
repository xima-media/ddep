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

```sh
# .ddev/commands/host/ddep
#!/usr/bin/env bash
## Description: Run ddep against a remote environment
## Usage: ddep [options] <command>
exec "${DDEV_APPROOT}/vendor/bin/ddep" "$@"
```

### Standalone

Clone the repo (or copy `bin/ddep`) somewhere on your `PATH` and call it
directly — the script is self-contained and location-independent.

## Setup

In the root of your project, create `.docker/ddep.json` with at least an
`app` and `hosts`:

   ```json
   {
     "app": "symfony",
     "hosts": {
       "dev": "user@dev-host",
       "test": "user@test-host",
       "live": "user@live-host"
     }
   }
   ```

`app` must be `typo3` or `symfony` — these are the two application types with
built-in defaults (DB env var names, migration command, rsync
directories/excludes). `hosts` maps a `--host` slug to an SSH target; see
[examples/typo3/ddep.json](examples/typo3/ddep.json) and
[examples/symfony/ddep.json](examples/symfony/ddep.json) for full examples.

### Config options

| Key                  | Required | Description |
|-----------------------|:--------:|--------------|
| `app`                 | yes | `typo3` or `symfony` |
| `hosts`               | yes | Map of host slug → SSH target (`user@host`), at least one entry |
| `environments_path`   | no  | Remote docker-compose base directory. Default: `/opt/docker/compose` |
| `mariadb_version`     | no  | MariaDB image tag used for dump/restore. Default: `lts` |
| `settings.<app>.*`   | no  | Overrides any built-in setting for that application — see below |

Everything is deep-merged over the script's built-in defaults, so you only
need to specify what differs from the defaults for your `app`.

### Overrides

There is a single, standardised way to override any default application
setting: set the same key, at the same path, under `settings.<app>` in
your local config. Whatever you set there **fully replaces** the built-in
default at that path — objects are merged key by key, but arrays and scalars
are replaced outright, never appended to or merged element-by-element.

The built-in defaults for each application (`db.migration`, `db.env.*`,
`db.exclude_tables`, `rsync.max_size_mb`, `rsync.remote_path`,
`rsync.directories`, `rsync.exclude_paths`, `rsync.exclude_extensions`) live in
`load_default_config()` inside `bin/ddep` — copy the path you want to change
from there.

`rsync.remote_path` is the media directory inside the application container
(default `/var/www/html/app/public`); override it if your image lays out the
document root differently.

For example, to replace the built-in `db:pull` table-exclude list for `symfony`:

```json
{
  "app": "symfony",
  "hosts": { "dev": "user@dev-host" },
  "settings": {
    "symfony": {
      "db": {
        "exclude_tables": [
          "^sessions$",
          "^v_media_references_info$"
        ]
      }
    }
  }
}
```

Since this replaces (rather than appends to) the built-in list, include every
table you still want excluded, not just the ones you're adding.

## Commands

| Command | Description |
|---------|--------------|
| `media:push` | Push local media files to the remote application container |
| `media:pull` | Pull media files from the remote application container |
| `db:push` | Import a database dump (read from stdin) into the remote database, then run the application's DB migration |
| `db:pull` | Export the remote database to stdout |
| `ssh [command]` | Open a shell, or execute a command, inside the remote container |
| `logs` | Follow the remote application container's log output |
| `config` | Print the resolved configuration (`.docker/ddep.json` deep-merged over the built-in defaults) as JSON |

`db:push` and `media:push` overwrite data in the remote environment and ask for
confirmation before running. On non-`dev` hosts you must type the host slug to
proceed; pass `--force` to skip the prompt (required in CI, where there is no
terminal).

## Options

Options may appear before or after the command, in any order.

| Option | Description |
|--------|--------------|
| `--debug` | Enable bash execution tracing |
| `--force` | Skip the confirmation prompt for destructive operations (`db:push`, `media:push`). Required for non-interactive/CI use |
| `--host <host>` | Target host from `.docker/ddep.json`. Default: `dev` |
| `--env <environment>` | Remote environment slug — the part of the remote docker-compose project directory name after `<project>_`. Default: interactively pick from the environments currently deployed on `--host` |
| `-h`, `--help` | Show usage and exit |
| `-V`, `--version` | Show version and exit |

## Examples

```sh
# Pull media from the test environment
ddep --host test media:pull --env development

# Push local media to the dev environment
ddep --host dev media:push --env feature_xyz

# Open an interactive shell in the dev application container
ddep --host dev ssh

# Execute a command inside the dev application container
ddep --host dev ssh "vendor/bin/typo3 list"

# Follow the dev application container's log output
ddep --host dev logs

# Import a database dump into the dev environment
ddep --host dev db:push --env feature_xyz < dump.sql

# Export the dev database to a dump file
ddep --host dev db:pull --env feature_xyz > dump.sql

# Pipe an existing dump directly into the remote database
cat dump.sql | ddep --host dev db:push --env feature_xyz

# Inspect the fully resolved configuration (no git repo, host or env needed)
ddep config
ddep config | jq '.settings.symfony.rsync'
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
- **`db:push`/`media:push` overwrite remote data.** They prompt for confirmation
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
- **Always pass `--env`.** Without a TTY there is no interactive environment
  picker; ddep exits with an error asking for it.
- **Pass `--force` for `db:push`/`media:push`.** The confirmation prompt cannot
  be answered without a terminal.
- **Exit codes are reliable.** A successful command returns `0` and any failure
  returns non-zero, so `ddep … && next-step` and pipeline gating behave.

```sh
# Refresh a staging database non-interactively
ddep --host test --env staging --force db:push < dump.sql
```

## Troubleshooting

| Message | Cause / fix |
|---------|-------------|
| `bash >= 4.3 required, but running 3.2…` | macOS' default bash. `brew install bash` and put it before `/bin/bash` on your `PATH`. |
| `required command(s) not found on PATH: …` | Install the missing tool(s) (`jq`, `docker`, `rsync`, `ssh`, `gzip`, `git`). |
| `docker: command not found` when run via `ddev exec` | The ddev web container has no docker client. Run ddep on the **host** (where docker, ssh, and your agent live), not inside the container. |
| `could not determine the project name` | Run ddep from inside the project's git working copy; it needs an `origin` remote. |
| `host '…' is not configured` | The `--host` slug is missing from `hosts` in `.docker/ddep.json`. |
| `No container found for project '…' and environment '…'` | Wrong `--env`, the stack isn't running, or `environments_path`/compose labels don't match. |
| `no --env given and no terminal available` | Non-interactive run (CI/pipe) with no `--env`; pass it explicitly. |
