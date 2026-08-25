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
with built-in defaults (DB env var names, migration command, rsync
directories/excludes). `ddep` derives its own connection info from this file:

- `app` ← `all.vars.app_name`
- every host is addressable by its own hosts.yaml key as `--host <key>` —
  e.g. `--host customer_a` for one of several hosts under a `live` group
  (`all.children.live.hosts.customer_a`, `.customer_b`, ...)
- `--host dev`/`test`/`live` also work as a convenience default, resolving to
  the **first** host declared under that group, in file order. Reliable only
  for a genuinely single-host group — once a group has more than one host,
  address the one you mean by its own key instead (see above); which host
  `--host live` happens to mean on a multi-host group is an implementation
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
        "exclude_tables": ["^sessions$", "^v_media_references_info$"]
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

`exclude_tables` only ever skips *rows*, never the table itself: `db:pull` dumps
every table's structure (including excluded ones), and only omits data for the
excluded ones. That way a table like `sessions` — deliberately excluded because
it holds live, per-environment data that a dump should never overwrite — still
exists (empty) after a `db:push`, even on a brand-new environment that never
had it before.

## Commands

| Command | Description |
|---------|--------------|
| `media:push` | Push local media files to the remote application container |
| `media:pull` | Pull media files from the remote application container |
| `db:push` | Import a database dump (read from stdin, plain SQL or gzip) into the remote database, then run the application's DB migration |
| `db:pull` | Export the remote database to stdout, gzip-compressed |
| `ssh [command]` | Open a shell, or execute a command, inside the remote container |
| `logs` | Follow the remote application container's log output |
| `config` | Print the resolved configuration (built-in defaults, `.docker/hosts.yaml`, and `.docker/ddep.json`, all deep-merged together) as JSON |
| `info` | Print details about the remote application container as JSON (currently just `container_id`; more may be added) |

`db:push` and `media:push` overwrite data in the remote environment and ask for
confirmation before running. On non-`dev` hosts you must type the host slug to
proceed; pass `--force` to skip the prompt (required in CI, where there is no
terminal).

`db:pull`/`db:push` compress the dump *before* it crosses the SSH-tunnelled
Docker connection (`mariadb-dump | gzip` runs inside the remote container, and
`db:push` sends the compressed bytes as-is and `gunzip`s them inside the
container too), not just at rest — meaningfully faster for large databases
over a slow or distant link. `db:push` also accepts plain, uncompressed SQL on
stdin (detected automatically) for backward compatibility.

## Options

Options must come before the command, in any order among themselves. For `ssh`,
everything after the command is the container command instead of an option -
see [Commands](#commands) above. Every other command takes no further arguments.

| Option | Description |
|--------|--------------|
| `--debug` | Enable bash execution tracing |
| `--force` | Skip the confirmation prompt for destructive operations (`db:push`, `media:push`). Required for non-interactive/CI use |
| `--host <host>` | Target host, from `.docker/hosts.yaml`. Default: `dev` |
| `--env <environment>` | Remote environment slug — the part of the remote docker-compose project directory name after `<project>_`. Default: interactively pick from the environments currently deployed on `--host` |
| `-h`, `--help` | Show usage and exit |
| `-V`, `--version` | Show version and exit |

## Examples

```sh
# Pull media from the test environment
ddep --host test --env development media:pull

# Push local media to the dev environment
ddep --host dev --env feature_xyz media:push

# Open an interactive shell in the dev application container
ddep --host dev ssh

# Execute a command inside the dev application container
ddep --host dev ssh "vendor/bin/typo3 list"

# Follow the dev application container's log output
ddep --host dev logs

# Import a database dump into the dev environment (plain SQL or gzip, both work)
ddep --host dev --env feature_xyz db:push < dump.sql.gz

# Export the dev database to a dump file (already gzip-compressed)
ddep --host dev --env feature_xyz db:pull > dump.sql.gz

# Pipe an existing dump directly into the remote database
cat dump.sql.gz | ddep --host dev --env feature_xyz db:push

# Inspect the fully resolved configuration (no git repo, host or env needed)
ddep config
ddep config | jq '.settings.symfony.rsync'

# Get the dev environment's container id (e.g. for reset-job tooling)
ddep --host dev --env feature_xyz info | jq -r '.container_id'
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
ddep --host test --env staging --force db:push < dump.sql.gz
```

## Troubleshooting

| Message | Cause / fix |
|---------|-------------|
| `bash >= 4.3 required, but running 3.2…` | macOS' default bash. `brew install bash` and put it before `/bin/bash` on your `PATH`. |
| `required command(s) not found on PATH: …` | Install the missing tool(s) (`jq`, `docker`, `rsync`, `ssh`, `gzip`, `git`). |
| `docker: command not found` when run via `ddev exec` | The ddev web container has no docker client. Run ddep on the **host** (where docker, ssh, and your agent live), not inside the container. |
| `could not determine the project name` | Run ddep from inside the project's git working copy; it needs an `origin` remote. |
| `host '…' is not configured` | The `--host` slug/key isn't declared anywhere under `all.children.*.hosts` in `.docker/hosts.yaml` (ddep.json's own `hosts`, if it has one, is ignored - see Setup). Run `ddep config \| jq .hosts` to see every currently resolvable value. |
| `No container found for project '…' and environment '…'` | Wrong `--env`, the stack isn't running, or `compose_projects_root`/compose labels don't match. |
| `no --env given and no terminal available` | Non-interactive run (CI/pipe) with no `--env`; pass it explicitly. |
