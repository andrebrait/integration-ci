# pr-watcher: one data directory, SQLite store, and a CLI for watches

## Goal

- Clients add and remove watches through a command, never by editing files.
  Today every session edits `config.json` by hand, and two sessions editing it
  at the same time can lose each other's changes.
- Everything pr-watcher keeps lives in one data directory. Users configure that
  directory and nothing inside it; the docs do not name the files in it.
- Watches and delivery state keep surviving restarts, as they do today.

Non-goals: an HTTP API, live reload of settings, changes to what is reported
or how it is delivered.

## Runtime

Node.js 24 or newer (current LTS). The store uses the built-in `node:sqlite`
module (`DatabaseSync`); no dependency is added. The unit keeps running its
pinned Node binary.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `PR_WATCHER_DATA_DIR` | `${XDG_STATE_HOME:-~/.local/state}/pr-watcher` | All pr-watcher data |
| `PR_WATCHER_OMPWEB_URL` | `http://127.0.0.1:30185` | omp-web base URL |
| `PR_WATCHER_INTERVAL_SECONDS` | `60` | Poll interval |
| `PR_WATCHER_IGNORE_AUTHORS` | empty | Comma-separated logins never reported |
| `OMP_WEB_TRUSTED_HEADER_SECRET` | none | Unchanged |

Settings are read at service start; changing one needs
`systemctl restart pr-watcher`. They live in the unit's existing environment
file (`/opt/omp-deployment/pr-watcher.env`). The service and the CLI must
resolve the same data directory: leave `PR_WATCHER_DATA_DIR` at its default,
or set it for both. `PR_WATCHER_CONFIG`, `PR_WATCHER_STATE`, `config.json`,
`config.example.json` and the config file watcher are removed.

## Store

One SQLite database in the data directory (created with the directory if
missing), opened with `journal_mode=WAL` and `busy_timeout=5000`, so the
service and any number of CLI invocations can use it at once.

```sql
CREATE TABLE watches (
  pr TEXT NOT NULL,              -- "owner/repo#123", validated by parsePr
  session TEXT NOT NULL,         -- omp session id
  ignore_authors TEXT NOT NULL,  -- JSON array of logins, per watch
  snapshot TEXT,                 -- JSON delivery state from diffPr; NULL = new watch
  added_at INTEGER NOT NULL,
  PRIMARY KEY (pr, session)
);
```

`PRAGMA user_version` records the schema version (1).

The delivery state stays on its watch row. Removing a watch therefore drops its
state, and adding it again starts from a fresh baseline, as today.

## CLI

The service and the CLI are the same script, `pr-watcher/pr-watcher.mjs`, linked
as `pr-watcher` on `PATH` (`~/.local/bin/pr-watcher`).

- `pr-watcher` (no arguments): run the service. `pr-watcher --once` runs one
  cycle, as today.
- `pr-watcher add OWNER/REPO#N --session ID [--ignore-author LOGIN]...`: add a
  watch. Adding an existing `(pr, session)` keeps its delivery state and
  replaces its ignore list.
- `pr-watcher remove OWNER/REPO#N [--session ID]`: remove that watch, or every
  watch on the PR when `--session` is omitted. Removing nothing is not an
  error; the command says so.
- `pr-watcher list [--json]`: one line per watch (PR, session, ignore list,
  last known PR state), or a JSON array.

Input is validated before any write: the PR with `parsePr`, the session id as
`[A-Za-z0-9_-]{1,80}`, logins as `[A-Za-z0-9-]{1,39}` with an optional `[bot]`
suffix. Invalid input exits with status
2 and a usage message; a store error exits with status 1. All SQL uses bound
parameters.

## Service cycle

1. Read all watch rows.
2. For each: fetch the PR, `diffPr(snapshot, …)`, deliver any events through
   omp-web exactly as today (busy session → retry next cycle).
3. After a successful delivery, or for a new watch's baseline,
   `UPDATE watches SET snapshot = ? WHERE pr = ? AND session = ?`. A watch
   removed during the cycle matches no row and stays removed.
4. Once the merged or closed notice has been delivered, delete the row. The
   watch ends by itself; clients no longer remove finished watches.

A new watch waits for the next cycle (at most one interval); its first cycle
only records the baseline, so the delay hides no activity.

## Migration

Runs when the database is created (`user_version` 0), inside the transaction
that creates the schema, whichever of the service or the CLI opens it first:

- Import every valid watch from `~/.config/pr-watcher/config.json` (or the
  path in a still-set `PR_WATCHER_CONFIG`), with its `ignoreAuthors`, and its
  snapshot from the old `state.json` (`<data dir>/state.json`, or
  `PR_WATCHER_STATE`) keyed `"<pr>-><session>"`. Watches with a snapshot keep
  it, so nothing already delivered is delivered again. Watches whose snapshot
  is MERGED or CLOSED are not imported: their final notice was already sent.
- After the commit, rename both files to `*.migrated` (kept for rollback, never
  read again). Settings found in `config.json` that differ from the defaults are
  logged with the environment variable that replaces them.

Rollback: stop the service, rename the `*.migrated` files back, and run the
previous version. Watches added after the migration must be re-added by hand.

## Docs

- `README.md`: the pr-watcher section describes the data directory, the
  settings table, the CLI, and the automatic end of a watch, without naming
  files inside the data directory. The setup block installs the `pr-watcher`
  link instead of copying a config.
- `~/.omp/agent/AGENTS.md` (tracked in `andrebrait/ai-harness-settings`): the
  PR-watching rule registers with `pr-watcher add …` and drops the manual
  cleanup step.

## Testing

`node --test pr-watcher/`, each test on a temporary data directory:

- CLI: add, re-add keeping the snapshot, remove one, remove all of a PR,
  remove nothing, list and `--json`, invalid PR/session rejected with status 2
  and no write.
- Cycle (omp-web and `gh` stubbed): a new watch records a baseline and sends
  nothing; delivered events update the snapshot; a busy session keeps the old
  snapshot; a watch removed mid-cycle is not recreated; a delivered MERGED
  notice deletes the row.
- Migration: watches and snapshots imported, finished watches skipped, old
  files renamed, a second open does not import again.
- Persistence: a second store opened on the same directory sees the first one's
  writes.
- Existing `parsePr`, `diffPr`, and `formatMessage` tests stay.
