# pr-watcher Store and CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move pr-watcher's watches and delivery state into a SQLite store in one data directory, managed through a `pr-watcher add/remove/list` CLI.

**Architecture:** A new `pr-watcher/store.mjs` owns the database (schema, migration, CRUD). `pr-watcher.mjs` keeps polling/diff/delivery, reads settings from env, and dispatches CLI subcommands. The cycle takes its dependencies as arguments so tests stub `gh` and omp-web.

**Tech Stack:** Node.js ≥24, `node:sqlite` (`DatabaseSync`), `node:test`.

**Spec:** `docs/specs/2026-10-12-pr-watcher-store-design.md`

## Global Constraints

- Node.js 24 or newer; no npm dependencies.
- Data dir: `PR_WATCHER_DATA_DIR`, default `${XDG_STATE_HOME:-~/.local/state}/pr-watcher`. Docs never name files inside it.
- Settings env: `PR_WATCHER_OMPWEB_URL` (default `http://127.0.0.1:30185`), `PR_WATCHER_INTERVAL_SECONDS` (default `60`), `PR_WATCHER_IGNORE_AUTHORS` (comma-separated, default empty).
- SQLite: `journal_mode=WAL`, `busy_timeout=5000`, `PRAGMA user_version = 1`, bound parameters only.
- Session id `^[A-Za-z0-9_-]{1,80}$`; login `^[A-Za-z0-9-]{1,39}(\[bot\])?$`; PR via `parsePr`.
- CLI exit codes: 0 ok, 2 invalid input (no write), 1 store error.

## Review Focus

1. Invoked through the `~/.local/bin/pr-watcher` symlink: `process.argv[1]` is the link, not the module path, so the current `argv[1] === fileURLToPath(import.meta.url)` guard never runs `main`. Expect the CLI to work through the link (Task 3 test).
2. Service and CLI started concurrently on a fresh data dir both try to migrate: exactly one import, no duplicate-key crash (Task 1 test).
3. A watch removed while the cycle is fetching its PR must not reappear (Task 2 test).
4. `PR_WATCHER_INTERVAL_SECONDS` set to garbage (`abc`, `0`, `-5`): fall back to 60, never a hot loop (Task 2 test).
5. Corrupt `snapshot` JSON in a row: log and treat as a new watch (baseline), never crash the cycle (Task 2 test).

---

### Task 1: Store module with migration

**Files:**
- Create: `pr-watcher/store.mjs`
- Test: `pr-watcher/store.test.mjs`

**Interfaces:**
- Produces:
  - `dataDir(env = process.env): string`
  - `openStore(dir: string, legacy?: { config?: string, state?: string }): Store` — creates the dir and DB, runs migration when `user_version` is 0. `legacy` defaults to `{ config: env.PR_WATCHER_CONFIG ?? ~/.config/pr-watcher/config.json, state: env.PR_WATCHER_STATE ?? <dir>/state.json }`.
  - `Store`: `list(): Watch[]`, `add(pr, session, ignoreAuthors: string[]): void`, `remove(pr, session?): number` (rows removed), `saveSnapshot(pr, session, snapshot): boolean` (false when the row is gone), `close(): void`.
  - `Watch = { pr, session, ignoreAuthors: string[], snapshot: object | undefined, addedAt: number }`; `snapshot` is `undefined` for NULL or unparsable JSON.

- [ ] **Step 1: Write failing tests** (each on `mkdtempSync` dirs)
  - `add then list returns the watch with no snapshot`
  - `re-add keeps the snapshot and replaces ignoreAuthors`
  - `remove with session removes one; without session removes every watch of the PR; returns counts 1, 2, 0`
  - `saveSnapshot returns false for a removed watch and does not recreate it`
  - `a second openStore on the same dir sees the first one's writes`
  - `migration imports watches and snapshots, skips MERGED/CLOSED snapshots, renames both files to *.migrated` — fixture config `{ ompwebUrl: "http://x", watches: [{pr:"a/b#1",session:"s1"},{pr:"a/b#2",session:"s1"},{pr:"a/b#3",session:"s2",ignoreAuthors:["bot[bot]"]}] }`, state `{ "a/b#1->s1": {seen:["c1"],state:"OPEN"}, "a/b#2->s1": {state:"MERGED"} }`; expect rows `#1` (snapshot seen `["c1"]`) and `#3` (no snapshot, ignore list kept), and `config.json.migrated`/`state.json.migrated` exist.
  - `migration runs once: reopening with a recreated config.json imports nothing`
  - `two openStore calls racing on a fresh dir import once` — open twice before closing either; expect 3→2 rows, no throw.
  - `invalid watches in the legacy config are skipped`

- [ ] **Step 2: Run** `node --test pr-watcher/store.test.mjs` — Expected: FAIL (module missing).

- [ ] **Step 3: Implement `pr-watcher/store.mjs`**
  Schema from the spec. Migration inside `BEGIN IMMEDIATE`; re-check `user_version` after acquiring the lock (that is what makes the race test pass); set `user_version = 1` in the same transaction; rename legacy files after `COMMIT` ignoring `ENOENT`. Log non-default `ompwebUrl`/`intervalSeconds`/`ignoreAuthors` with the replacing env var name. `add` is `INSERT … ON CONFLICT(pr, session) DO UPDATE SET ignore_authors = excluded.ignore_authors`.

- [ ] **Step 4: Run** `node --test pr-watcher/store.test.mjs` — Expected: PASS.

- [ ] **Step 5: Commit** `git add pr-watcher/store.* && git commit -m "pr-watcher: SQLite store with legacy import"`

### Task 2: Service cycle on the store, settings from env

**Files:**
- Modify: `pr-watcher/pr-watcher.mjs` (remove `readJson`/`writeJson`, `CONFIG`/`STATE`, `fs.watch`, `lastGoodConfig`)
- Delete: `pr-watcher/config.example.json`
- Test: `pr-watcher/pr-watcher.test.mjs`

**Interfaces:**
- Consumes: `openStore`, `dataDir`, `Store` (Task 1).
- Produces:
  - `settings(env = process.env): { ompwebUrl: string, intervalSeconds: number, ignoreAuthors: string[] }`
  - `cycle(store: Store, deps: { fetchPr(pr): Promise<Snap>, notify(session, message): Promise<boolean>, self: string, ignoreAuthors: string[] }): Promise<void>`

- [ ] **Step 1: Write failing tests** (temp store; `fetchPr`/`notify` stubs recording calls)
  - `settings applies defaults and parses PR_WATCHER_IGNORE_AUTHORS "a, b,"` → `["a","b"]`
  - `settings falls back to 60 for interval "abc", "0", "-5"`
  - `a new watch stores a baseline and notifies nothing`
  - `new activity is delivered and the snapshot advances`
  - `a busy session (notify → false) keeps the old snapshot`
  - `a watch removed during fetchPr is not recreated` — stub `fetchPr` calls `store.remove` before resolving; expect `list()` empty.
  - `a delivered MERGED notice deletes the watch`
  - `a fetch error leaves the row untouched and other watches proceed`
  - `a row with corrupt snapshot JSON is treated as new` (write the bad value with a raw `DatabaseSync` on the store file)

- [ ] **Step 2: Run** `node --test pr-watcher/` — Expected: new tests FAIL.

- [ ] **Step 3: Implement** `settings` and `cycle`. Per watch: `ignore = new Set([self, ...deps.ignoreAuthors, ...watch.ignoreAuthors])`; on events, `notify`; when delivered (or no events), `saveSnapshot`, then `remove(pr, session)` if `next.state` is MERGED/CLOSED (covers a watch added after the PR finished: nothing will ever be reported). `main()` opens the store once, loops on `settings().intervalSeconds`, builds `notify` from the existing `OmpWeb` class with `settings().ompwebUrl`.

- [ ] **Step 4: Run** `node --test pr-watcher/` — Expected: PASS.

- [ ] **Step 5: Commit** `git commit -am "pr-watcher: poll watches from the store; settings from env"` (include the deleted example).

### Task 3: CLI subcommands

**Files:**
- Modify: `pr-watcher/pr-watcher.mjs` (entry guard, `main` dispatch)
- Test: `pr-watcher/cli.test.mjs`

**Interfaces:**
- Consumes: `openStore`, `dataDir`, `parsePr`.
- Produces: `cli(argv: string[], { store, out, err }): number` (exit code); entry guard compares `realpathSync(process.argv[1])` with the module path.

- [ ] **Step 1: Write failing tests** — unit tests call `cli()`; two tests spawn `node` with `PR_WATCHER_DATA_DIR` set:
  - `add validates and writes; invalid PR, session or login returns 2 and writes nothing`
  - `add repeats --ignore-author`
  - `remove reports "removed 1 watch" / "no matching watch"` (both exit 0)
  - `list prints "owner/repo#N  session  [ignore]  state"; list --json prints the Watch array`
  - `unknown subcommand prints usage and returns 2`
  - `spawned through a symlink, "list --json" runs main and prints []` (symlink in a temp dir)
  - `spawned "add" from a different cwd uses PR_WATCHER_DATA_DIR`

- [ ] **Step 2: Run** `node --test pr-watcher/` — Expected: new tests FAIL.

- [ ] **Step 3: Implement** `cli` with `node:util` `parseArgs` (`session`: string, `ignore-author`: string multiple, `json`: boolean, `once`: boolean). No subcommand → service; `--once` → one cycle. Store errors caught at the top → message on stderr, exit 1. `chmod +x pr-watcher/pr-watcher.mjs`.

- [ ] **Step 4: Run** `node --test pr-watcher/` — Expected: PASS.

- [ ] **Step 5: Commit** `git commit -am "pr-watcher: add/remove/list CLI"`

### Task 4: Docs, rollout, and live migration

**Files:**
- Modify: `README.md` (pr-watcher section), `/root/git/ai-harness-settings/ai-dev/omp/agent/AGENTS.md` (PR-watching rule)

- [ ] **Step 1: README** — "Node.js 24 or newer"; replace Configuration/State bullets with the data-dir + settings table from the spec; describe the CLI and that a watch ends by itself after the merged/closed notice; setup block: `ln -s /root/git/integration-ci/pr-watcher/pr-watcher.mjs ~/.local/bin/pr-watcher` instead of copying a config; remove `config.example.json` mention.
- [ ] **Step 2: AGENTS.md** — Register: `pr-watcher add OWNER/REPO#N --session <id>` (also for fork review copies); Clean up: removed (the watcher ends the watch); keep the session-id derivation command. Commit in `ai-harness-settings`.
- [ ] **Step 3: Live rollout** — `ln -s …`; `systemctl restart pr-watcher`; Expected: `journalctl -u pr-watcher -n 20` shows the import with the 31→N imported count and no error; `pr-watcher list | wc -l` equals the number of non-finished legacy watches; `ls ~/.config/pr-watcher` shows `config.json.migrated`.
- [ ] **Step 4: Smoke** — `pr-watcher add andrebrait/integration-ci#1 --session smoke-test` then `pr-watcher remove andrebrait/integration-ci#1`; Expected: list shows then drops it; journal shows no errors over one cycle.
- [ ] **Step 5: Commit and push** `integration-ci` (`git push origin main`) and `ai-harness-settings`.
