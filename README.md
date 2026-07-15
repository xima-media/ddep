# ddep

Developer tooling for access to containerised environments.

`ddep.sh` pushes/pulls media and database dumps between your local machine and
a remote Docker Compose environment over SSH, and lets you open a shell in the
remote application container.

## Requirements

**Local machine:** `jq`, `docker`, `ssh`, `rsync`, `gzip`.

- Must be run from inside the project's git working copy — the project name
  and remote docker-compose directory are derived from `git remote get-url origin`.
- Passwordless SSH access to the target host is required, since every command
  makes at least one SSH/Docker-over-SSH round trip.

## Setup

1. Copy `ddep.sh` somewhere on your `PATH` (or call it via a relative/absolute path).
2. In the root of your project, create `.docker/ddep.json` with at least an
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
`db.exclude_tables`, `rsync.max_size_mb`, `rsync.directories`,
`rsync.exclude_paths`, `rsync.exclude_extensions`) live in `load_default_config()`
inside `ddep.sh` — copy the path you want to change from there.

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

## Options

Options may appear before or after the command, in any order.

| Option | Description |
|--------|--------------|
| `--debug` | Enable bash execution tracing |
| `--host <host>` | Target host from `.docker/ddep.json`. Default: `dev` |
| `--env <environment>` | Remote environment slug — the part of the remote docker-compose project directory name after `<project>_`. Default: interactively pick from the environments currently deployed on `--host` |

## Examples

```sh
# Pull media from the test environment
ddep.sh --host test media:pull --env development

# Push local media to the dev environment
ddep.sh --host dev media:push --env feature_xyz

# Open an interactive shell in the dev application container
ddep.sh --host dev ssh

# Execute a command inside the dev application container
ddep.sh --host dev ssh "vendor/bin/typo3 list"

# Follow the dev application container's log output
ddep.sh --host dev logs

# Import a database dump into the dev environment
ddep.sh --host dev db:push --env feature_xyz < dump.sql

# Export the dev database to a dump file
ddep.sh --host dev db:pull --env feature_xyz > dump.sql

# Pipe an existing dump directly into the remote database
cat dump.sql | ddep.sh --host dev db:push --env feature_xyz
```
