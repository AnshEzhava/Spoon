# Spoon: Product & Technical Specification

> A fast, native, open-source Git client for macOS. Everything Fork does, plus first-class multi-repository workflows.

| | |
|---|---|
| **Status** | Draft v0.1 |
| **Date** | 2026-11-06 |
| **Platform** | macOS 15 Sequoia and later, universal binary (Apple Silicon + Intel) |
| **License** | GPL-3.0 (proposed; see §12) |
| **Reference product** | Fork 2.71 for Mac (23 Oct 2026) by Dan & Tanya Pristupov, fork.dev |

---

## How to read this spec

- **Priority**
  - **P0** — MVP / first public beta. Spoon is not usable as a daily driver without it.
  - **P1** — 1.0. Fork parity plus the headline improvements.
  - **P2** — after 1.0.
- **Origin**
  - **F** — Fork has it (parity).
  - **F~** — Fork has a partial or weaker version; Spoon improves it.
  - **S** — new in Spoon (Fork lacks it). Usually backed by a Fork tracker request, cited as `#NNN` (github.com/fork-dev/Tracker).
- **IDs** like `GRP-03` are stable. Use them in issues, PRs and commits.
- **Fork version numbers** in parentheses (e.g. "Fork 2.26") are the Fork Mac release that introduced the behavior, taken from Fork's public release notes. They are context, not requirements.
- **"> Fork:"** blocks describe how Fork does it today, so the reference is explicit. The text after a block is what Spoon does.

## Contents

1. [Vision & principles](#1-vision--principles)
2. [Positioning: Fork vs Spoon](#2-positioning-fork-vs-spoon)
3. [Signature feature: Repository Groups & Group Sync](#3-signature-feature-repository-groups--group-sync)
4. [Architecture](#4-architecture)
5. [UI & UX specification](#5-ui--ux-specification)
6. [Feature catalogue (full parity list)](#6-feature-catalogue)
7. [Top improvements over Fork](#7-top-improvements-over-fork)
8. [Preferences](#8-preferences)
9. [Keyboard shortcuts](#9-keyboard-shortcuts)
10. [Non-functional requirements](#10-non-functional-requirements)
11. [Roadmap](#11-roadmap)
12. [Open decisions](#12-open-decisions)
13. [Appendix: research sources](#13-appendix-research-sources)

---

## 1. Vision & principles

Fork is the best-loved Git GUI on the Mac. It is fast, native and sensibly designed, but it is closed source, has a two-person roadmap, and is built around one repository at a time. Spoon matches Fork's polish feature for feature, is open source, and treats *many repositories* as the normal case: grouping them, watching them, and syncing them safely in one action.

**Principles**

1. **Native and fast.** AppKit-grade performance for lists and diffs. No Electron. No web views for core UI. Interactions respond in under 100 ms.
2. **Real git.** Every mutation and network operation runs through `git` itself, so hooks, config, credential helpers, LFS filters, `~/.ssh/config`, signing and `includeIf` all behave exactly as in the terminal. Spoon never reimplements write operations.
3. **Safe by default.** Preview first and predict conflicts. Never lose work: every destructive operation can be undone or has a recoverable backup. Unattended operations never leave a repo half-merged.
4. **Many repos are normal.** Groups are first-class, not a bookmark folder.
5. **Keyboard first, mouse friendly.** Every action is in Quick Launch and every shortcut can be remapped. Drag and drop works where it is natural.
6. **Transparent.** Spoon shows the exact git commands it runs, has no telemetry, and asks before it changes your git config.
7. **Open.** GPL-licensed, with a public roadmap. It is extensible through custom commands and a CLI rather than a plugin runtime.

**Non-goals for 1.0**

- Windows or Linux builds. SpoonKit (§4.2) stays free of AppKit so that a future Linux front end is possible. Linux is Fork's #1 request (#153, 458 👍).
- The Mac App Store (sandboxing is incompatible with a git client; see §4.11).
- Repos on remote machines over SSH (#929).
- Being a code editor or a code-review platform.
- Version control systems other than git (jj is a P2 research item).

---

## 2. Positioning: Fork vs Spoon

| Area | Fork 2.71 | Spoon 1.0 |
|---|---|---|
| Price / source | $59.99 one-time, closed source | Free, open source (GPL-3.0) |
| Platforms | macOS, Windows | macOS (core kept portable) |
| Repo organisation | Repository Manager folders (2016) + Workspaces (2.26), now per window (2.71) | **Groups**: nested, many-to-many, ordered, smart groups, per-group identity and settings |
| Multi-repo fetch/pull | **None.** Maintainer declined it (#2520: "write a simple Bash script") | **Group Sync**: sequential by default, a safety preflight for each repo, a result for each repo, undo, scheduling, CLI |
| Group status overview | None (#379) | **Group Dashboard**: branch, dirty state, ahead/behind, last fetch, last sync result |
| Clone a whole org | None (#1578) | Mirror a GitHub org or GitLab group as a group (P2) |
| Undo | None (#981, #2175) | Operation log with ⌘Z / ⇧⌘Z for commits, resets, rebases, discards, branch deletes and group pulls |
| Hook `$PATH` problems | Long-standing (#1227, #1889, #311) | Login-shell environment resolved automatically, with overrides |
| SSH commit signing | No (#1512) | Yes, including 1Password `op-ssh-sign` and verification badges |
| Co-authors | No (#890) | Autocomplete from repo history |
| Uncommitted changes in graph | No (#308) | Yes, as a "working copy" row |
| Vertical layout | No on Mac (#756) | Horizontal or vertical layout, switchable |
| UI zoom / font size | No (#1178, #1955) | ⌘= / ⌘− zoom, per-area font sizes |
| Configurable shortcuts | No (#62) | Full keymap editor, `keybindings.json` |
| Custom branch colors | No (#2358) | Rules from branch-name pattern to color |
| Multi-file / range diff | No (#261) | Continuous multi-file diff; diff of a commit range |
| Word diff, moved lines | No (#100, #1443) | Yes (P2) |
| AI providers | Claude Code, Codex and Cursor CLI agents only | CLI agents, OpenAI-compatible endpoints (Ollama, LM Studio) and the Anthropic API. Opt-in, consent per repo |
| PRs | Create PR only (opens the browser) | PR list in sidebar, check out a PR locally, create PR in-app; group PR inbox (P2) |
| Stacked branches | `--update-refs` checkbox | Stack tracking stored in git config, restack, push stack (P2) |
| Forgejo / Codeberg | No (#2124) | Yes |
| Bare repos | Declined (#247) | Read-only view (P2) |

**Lessons from the competition (things to borrow)**

- **GitKraken** offers multi-repo fetch and pull on Workspaces, but it is an Electron app and the feature needs the paid Pro plan. Spoon makes the same thing native, free and safer.
- **Tower** has ⌘Z undo, snapshots, branch stacks stored in git config, conflict prediction, and a "Branches Review" cleanup screen.
- **Sublime Merge** has the strongest search query language and a command palette that users can extend. Its custom fast *reader* sits beside real git for every *write*.
- **GitUp** has unlimited undo and snapshots.
- **GitButler** has an operations log and first-class conflicts.
- **lazygit** builds custom patches, can amend an old commit, and undoes via the reflog.
- **gita, myrepos (`mr`), meta and Android `repo`** contribute group contexts, a per-repo update command, retry when back online, shareable manifests, "clone missing repos", and output grouped per repo.
- **Sourcetree** is a cautionary tale. Its repo browser's status badges went stale with about 50 repos for years. Spoon shows how old the remote status is, and keeps the local refresh separate from the network fetch.

---

## 3. Signature feature: Repository Groups & Group Sync

### 3.1 Concepts

| Term | Definition |
|---|---|
| **Repository** | A local working copy known to Spoon. Identity is the canonical path of its common git dir, so linked worktrees resolve to one repository. Attributes: display name, color, tags, pinned, last opened. |
| **Group** | A named, **ordered** collection of repositories. Groups can nest (`Work/Payments`). A repository can belong to any number of groups. The order is the default sync order. |
| **Smart Group** (P1) | A saved query whose membership is computed and read-only. Examples: path under `~/Code/acme`, remote host `gitlab.acme.com`, tag `backend`, has uncommitted changes, behind upstream. |
| **Scoped window** | A window bound to one group. Its tab bar, Quick Launch "recent" list and Home show only that group. This replaces Fork's Workspaces. |
| **Group run** | One action (Fetch, Pull, Push, custom command) executed over the members of a group, with a result for each repo. |

### 3.2 Group management

| ID | Feature | P | Origin |
|---|---|---|---|
| GRP-01 | Create, rename and delete groups. Nest by dragging, or by typing `/` in the name. | P0 | F~ |
| GRP-02 | Add repos to a group: drag from Home or Finder, multi-select then "Add to Group…", or choose a group in the Clone and Open dialogs. | P0 | S |
| GRP-03 | Reorder members by dragging. The order is the sync order. | P0 | S |
| GRP-04 | Group color and SF Symbol icon. | P1 | F~ |
| GRP-05 | A repository can be in many groups. Removing it from a group never removes it from the library. | P0 | S |
| GRP-06 | "Create Group from Folder…": scans a directory (configurable depth, default 3), lists the repos found with checkboxes, and optionally creates nested groups that mirror subfolders. | P0 | F~ |
| GRP-07 | Smart groups (rules on path, remote host or owner, tag, dirty, behind, last-opened age). | P1 | S |
| GRP-08 | "Open All in Tabs" for a group. Asks for confirmation above 15 repos (#1915, #497). | P1 | S |
| GRP-09 | Scope a window to a group. ⌘-click a group opens it in a new scoped window. | P1 | F |
| GRP-10 | **Group identity.** Per-group `user.name`, `user.email`, signing key and SSH key. Spoon writes these to a Spoon-managed include file `~/.config/spoon/gitconfig.d/<group>.gitconfig` and adds one `includeIf "gitdir:<member path>/"` line per member to `~/.gitconfig`. It shows the exact diff first and asks for confirmation. No secrets are stored (#1903, #2396). | P1 | S |
| GRP-11 | **Manifest export/import** (`*.spoon-group.json`, §3.7). Import offers "Clone missing repos" into a chosen root. | P1 | S |
| GRP-12 | **Mirror an org.** Pick a GitHub org, GitLab group, Gitea/Forgejo org or Bitbucket workspace from a connected account, filter out archived repos and forks, choose a root folder, then clone in sequence and create the group. Later, "Check for new repos" offers to clone additions and flags repos that were archived or deleted (#1578). | P2 | S |
| GRP-13 | Group commands in Quick Launch: "Switch to Group…", "Fetch Group…", "Pull Group…", "Open Group Dashboard…". | P0 | S |
| GRP-14 | Per-member overrides: exclude from sync, its own pull strategy, its own remote. | P1 | S |

### 3.3 Group Dashboard

> **Fork:** Repository Manager shows one repo at a time: README, size, commit count, remotes. It has no per-repo status in the tree (#379) and no batch actions (#2520).

Selecting a group in Home shows the Dashboard: a native table with one row per member.

```
┌ Work / Payments ─────────────────────────────────────────────────────────────────────────────┐
│ [⤓ Fetch All] [⇣ Pull All ▾ ff-only]  [■ Stop]     All · Dirty 2 · Behind 5 · Diverged 1 · Failed 0   🔍 │
├──┬───────────────────┬──────────────┬──────────┬────────┬────────────┬──────────────┬─────────────────┤
│☑ │ Repository        │ Branch       │ Changes  │ ↑ / ↓  │ Fetched    │ Last commit  │ Last sync       │
├──┼───────────────────┼──────────────┼──────────┼────────┼────────────┼──────────────┼─────────────────┤
│☑ │ payments-api      │ ⎇ main       │ clean    │ 0 / 4  │ 3 min ago  │ 2h · Alex    │ ✓ +4 commits    │
│☑ │ ledger            │ ⎇ feat/x     │ ● 3      │ 1 / 2  │ 3 min ago  │ 1d · Sam     │ ⏭ Uncommitted   │
│☑ │ web-checkout      │ ⎇ main       │ clean    │ 2 / 5  │ 3 min ago  │ 5h · Kim     │ ⏭ Diverged      │
│☐ │ legacy-billing    │ ⎇ master     │ clean    │ — / —  │ never      │ 3mo · Lee    │ excluded        │
└──┴───────────────────┴──────────────┴──────────┴────────┴────────────┴──────────────┴─────────────────┘
  Pulling 2 of 3 — ledger: fetching origin… (12 s)                                        [Cancel]
```

- **Columns.** Include checkbox, Repository (name with path below in secondary text), Branch, Changes (`clean` / `● n` / `⚠ conflicts` / `rebase in progress`), Ahead/Behind, Fetched (age of the remote-tracking data), Last commit (age and author), Last sync (result icon and short reason). Columns are hideable and sortable, but sorting never changes the stored sync order.
- **Filter chips** with live counts: All, Dirty, Behind, Diverged, Failed, Skipped, No upstream.
- **Freshness rules**
  - Local status (branch, dirty, in-progress operation) is refreshed from FSEvents and costs nothing.
  - Remote status comes from the *last fetch* and always shows its age.
  - Opening the dashboard **never** touches the network, unless the group setting "Fetch when opened" is on.
  - **Refresh** (⌘R, local only) and **Fetch All** (network) are separate actions.
- **Row actions**
  - Double-click opens the repo in a tab.
  - Context menu: Open, Open in New Window, Fetch, Pull, Push, Open in Terminal, Show in Finder, Copy Path, Exclude from Sync, Remove from Group, Locate… (when missing).
- **Run progress.**
  - The footer shows the current repo and step, elapsed time, and Cancel.
  - Each row shows a live step: `queued → preflight → fetching → integrating → done`.
  - After a run the footer shows a summary, e.g. `18 updated · 3 up to date · 2 skipped · 0 failed`, with **Retry failed & skipped**, **Undo this sync** and **Show log**.
- **Keyboard.** ⌃⇧⌘F Fetch All, ⌃⇧⌘L Pull All (plain ⇧⌘F / ⇧⌘L also act on the group while the dashboard has focus), ⌘. Stop, Space to toggle the include checkbox, Return to open.

### 3.4 Group Sync engine

**Actions**
- **Fetch** (P0).
- **Pull** (P0): fetch, then integrate.
- **Push** (P2): only repos that are ahead and not behind. Spoon shows the list for confirmation first.
- **Run custom command** (P1, §6.18).

**Run options.** Defaults come from the group's settings and can be overridden per run.

| Option | Values | Default | Notes |
|---|---|---|---|
| Strategy | Fast-forward only · Rebase · Merge | **Fast-forward only** | ff-only can never create conflicts or new commits |
| Fetch scope | Upstream remote · All remotes | Upstream remote | `--prune` follows `fetch.prune`, default on; tags follow config |
| Local changes | Skip repo · Autostash | **Skip repo** | Autostash uses `--autostash`; a conflict on reapply leaves the stash intact and is reported |
| Other branches | Leave · Fast-forward local branches that are strictly behind their upstream | Leave | Uses `update-ref <new> <old>` only if the move is a true fast-forward and the branch is not checked out in any worktree |
| Submodules | Follow `submodule.recurse` · Always update · Never | Follow config | |
| Concurrency | 1–8 | **1 (sequential)** | Sequential keeps hosting rate limits happy (the concern Fork raised in #2520) and keeps auth prompts sane |
| Delay between repos | 0–30 s | 0 s | For strict rate-limited hosts |
| Stall timeout | 30–600 s without output | 90 s | Paused while an auth prompt is pending |
| On failure | Continue · Stop run | Continue | |

**Per-repository algorithm**

```text
PREFLIGHT (no network, no mutation)
  path missing                                   → SKIP "Missing"            (offer Locate…)
  not a git work tree                            → SKIP "Not a repository"
  excluded from sync                             → SKIP "Excluded"
  .git/index.lock exists                         → SKIP "Locked by another git process"
  MERGE_HEAD | rebase-merge/ | rebase-apply/ |
  CHERRY_PICK_HEAD | REVERT_HEAD | BISECT_LOG    → SKIP "<operation> in progress"
  HEAD detached                                  → mark "Detached", fetch only
  current branch has no upstream / remote gone   → mark "No upstream", fetch only

FETCH
  git fetch [--prune] <upstream-remote | --all>  → FAIL on auth / network / stall
  (Fetch action ends here → FETCHED "n new commits on <upstream>")

INTEGRATE (Pull only, skipped for "fetch only" marks)
  (ahead, behind) = git rev-list --left-right --count HEAD...@{u}
  behind == 0                                    → UP_TO_DATE  (note "n to push" if ahead > 0)
  tracked changes present && policy == skip      → SKIP "Uncommitted changes"
  ahead == 0                                     → git merge --ff-only @{u}          → UPDATED
  ahead > 0  && strategy == ff-only              → SKIP "Diverged (↑a ↓b)"
  ahead > 0  && strategy == rebase               → git rebase [--autostash] @{u}
                 conflict → git rebase --abort   → FAIL "Conflicts — repo restored"
  ahead > 0  && strategy == merge                → git merge --no-edit [--autostash] @{u}
                 conflict → git merge --abort    → FAIL "Conflicts — repo restored"

POST
  optional submodule update; optional fast-forward of other branches
  write OpLog entry {repo, branch, HEAD before, HEAD after, run id}
```

**Invariants**

1. An unattended group run never leaves a repo mid-merge or mid-rebase. Any conflict is aborted, and HEAD, index and worktree return to their exact pre-run state.
2. Cancel kills the process (SIGTERM, then SIGKILL after 5 s) only during the **fetch** step. During integrate, Spoon lets the step finish, or aborts it cleanly, before it stops.
3. Background status reads use `--no-optional-locks`, so they never fight the user's terminal for `index.lock`.
4. `GIT_TERMINAL_PROMPT=0` is always set. Auth prompts go through Spoon's askpass helper (§4.7). They are queued, one at a time, and attributed to their repo row.
5. A row whose ssh-agent or 1Password approval is pending shows **"Waiting for authentication"**, and its stall timer pauses. 1Password holds approval prompts while the requesting app is in the background, so an unattended run would otherwise look hung.

**Result model**

```swift
enum RepoSyncResult {
  case updated(branch: String, from: SHA, to: SHA, commits: Int)
  case upToDate(ahead: Int)
  case fetched(newCommits: Int)
  case skipped(SkipReason)        // missing, notRepo, excluded, locked, inProgress(op), dirty, diverged(a,b), noUpstream, detached
  case failed(SyncError, log: ActivityID)
  case cancelled
}
```

**Undo a group sync (P1).** "Undo this sync" resets each `updated` repo's branch to its pre-sync SHA, but only where HEAD still equals the post-sync SHA and the worktree is clean. Repos that changed since the sync are listed and left alone.

### 3.5 Scheduling & background (P1)

- **Group schedule.**
  - Off, or **Fetch** every 15 min / 30 min / 1 h / 4 h.
  - Scheduled **Pull** is a separate opt-in, and fast-forward only.
- **Triggers:** app launch, wake from sleep, network becoming available (missed runs execute once; the myrepos-style retry), group opened.
- **Conditions:**
  - Skip in Low Power Mode.
  - Skip on expensive or constrained networks (`NWPathMonitor`).
  - Optionally skip on battery.
- **Single-repo auto-fetch.**
  - Fork parity, but the interval is configurable (#1269): default 10 min, and off per remote.
  - "Fetch on open" is optional (#1205).
  - Spoon deduplicates with group schedules, so no repo is fetched twice within a 2-minute window.
- **Keeping Spoon running.** Runs happen while Spoon is running. Optionally Spoon stays alive as a menu-bar extra with no windows (P2), and a login item via `SMAppService` is optional.
- **Notifications.** One summary per run, sent only when something changed or failed (configurable). Clicking it opens the dashboard filtered to that run's results.

### 3.6 CLI (P1)

The `spoon` binary is installed from Settings → Integrations as a symlink into the app bundle. Group commands run **headless** on SpoonKit, so they work from cron or launchd without the GUI.

```text
spoon [open] [path]                       open repo (Fork-compatible verbs)
spoon status | spoon log [-- <path>]      open Local Changes / history / file history
spoon -C <path> …                         run against another repo
spoon diff <a> <b> [-- <path>]            open Spoon's diff window (#2267)
spoon group list
spoon group add <group> <path>…
spoon group sync <group> [--fetch-only] [--strategy ff-only|rebase|merge] [--jobs N] [--json]
spoon group export <group> > payments.spoon-group.json
spoon group import <file> [--clone-into <dir>]
```

The exit code is non-zero if any repo failed. `--json` prints one result object per repo.

### 3.7 Storage & manifest format

- **Library.** Stored in `~/Library/Application Support/Spoon/library.json`: repositories, groups, smart-group rules and per-member overrides. Codable JSON, atomic writes, a schema `version` field, and the last 5 versions kept as backups.
- **Manifest.** Shareable, so it can be committed to a "meta" repo. Paths are relative to the manifest file, or to a root chosen on import.

```json
{
  "spoonGroup": 1,
  "name": "Acme Backend",
  "defaults": { "strategy": "ff-only", "fetchAllRemotes": false },
  "repos": [
    { "path": "payments-api", "url": "git@github.com:acme/payments-api.git", "branch": "main" },
    { "path": "ledger",       "url": "git@github.com:acme/ledger.git", "strategy": "rebase" },
    { "path": "tools/infra",  "url": "https://gitlab.acme.com/ops/infra.git", "exclude": true }
  ]
}
```

- **Importers (P2).** Read-only importers for `.meta` (meta), `.mrconfig` (myrepos), gita's repo list and Android `repo` manifests.

### 3.8 Acceptance scenarios (automated integration tests)

| # | Setup | Expected |
|---|---|---|
| 1 | 20 clean repos, each behind its local bare "origin" | Sequential ff-only pull → all `updated`; every HEAD equals its upstream |
| 2 | Dirty repo, policy Skip | `skipped(dirty)`; worktree and index byte-identical before and after |
| 3 | Diverged repo, ff-only | `skipped(diverged(1,2))`, no mutation |
| 4 | Diverged repo, rebase, conflicting | `failed(conflicts)`; HEAD, index, worktree and refs identical to before; no `rebase-merge/` dir |
| 5 | Member directory deleted | `skipped(missing)` with a Locate… action; run continues |
| 6 | Network cut at repo 7 | Remaining repos `failed(network)` quickly; "Retry failed" completes them once back online |
| 7 | Cancel during repo 7 fetch | git process gone within 5 s; repo 7 `cancelled`; repos 8+ `cancelled`; no lock files left |
| 8 | SSH key needs agent approval | Row shows "Waiting for authentication"; no stall timeout while waiting |
| 9 | Undo after scenario 1 | All 20 branches back at their pre-sync SHAs |
| 10 | `spoon group sync X --json` with scenario 2 + 3 repos | Exit code 0 (skips are not failures); JSON lists the reasons |

---

## 4. Architecture

### 4.1 Stack decisions

| Concern | Decision | Why |
|---|---|---|
| Language | Swift 6, strict concurrency | Native, safe, and matches Fork's stack |
| UI shell | **AppKit** (`NSWindow`, `NSSplitViewController`, `NSToolbar`, native tabs) hosting **SwiftUI** for low-volume views: settings, sheets and dialogs, Home, Dashboard, popovers | SwiftUI `List`/`Table` slow down somewhere between 20k and 50k rows even on macOS 26. Repos routinely have more than 100k commits. |
| Commit list | View-based **`NSTableView`** with a fixed row height and reused cells. The data source indexes into flat arrays and does no identity diffing. | Scales to millions of rows, and that is proven in Fork. |
| File trees | `NSOutlineView` | Fast trees with large expansion state |
| Diff view | **Custom virtualized line view** (Core Text, drawing only visible lines) for read-only and stageable diffs. An editable text view only for the merge result and the commit message. | Line and hunk staging, side-by-side alignment, gutters, minimap and huge files are all easier when lines are rows. TextKit 2 has known layout bugs. |
| Git backend | **Bundled git CLI for every mutation and every network operation.** System, Homebrew or custom git is selectable. | Hooks, credential helpers, LFS, `~/.ssh/config`, signing, `includeIf`, fsmonitor and new index formats all just work. Fork, Tower, Sublime Merge, GitHub Desktop and lazygit all do this, and GitKraken is migrating *to* it. |
| Fast reads (phase 2) | Optional **gitoxide (gix) reader** through a small C ABI, used for rev-walk, refs, ahead/behind and object reads. Only added if profiling demands it. | Fork ships a Rust core for reads, and Sublime Merge has a custom reader. gix push, merge and rebase are not ready, so mutations never route through it. |
| Syntax highlighting | **tree-sitter** via swift-tree-sitter (BSD-3), with grammars bundled as needed | Incremental and accurate. Highlightr (JavaScriptCore) is too slow for large diffs. |
| Updates | **Sparkle 2** with EdDSA-signed appcast on GitHub Releases | Standard for non-App-Store Mac apps |
| Persistence | JSON files (Codable) in Application Support. No database at first. | The library holds hundreds of rows, so a database is unnecessary. Add SQLite when the op log or a search index outgrows JSON. |
| Package layout | Swift Package Manager workspace | No Xcode-project merge conflicts in the modules |

### 4.2 Modules

```
Spoon.xcodeproj  (app target only)
Packages/
  SpoonKit/        Pure Swift, no AppKit. Builds and tests on Linux.
    Git/           GitRunner, parsers (log, status v2, diff, refs, blame, config), models
    Repo/          RepositoryState, refresh coordinator, FSEvents watcher (macOS-conditional)
    Library/       Repositories, Groups, SmartGroup rules, manifest import/export
    Sync/          GroupSyncEngine, preflight, result model, scheduling policy
    OpLog/         operation journal + undo planner
    Graph/         lane layout
    Env/           login-shell environment resolution, askpass protocol
  SpoonUI/         AppKit + SwiftUI views and controllers
  SpoonCLI/        `spoon` executable (links SpoonKit only)
  SpoonAskpass/    tiny helper executable used as GIT_ASKPASS / SSH_ASKPASS
```

SpoonKit has no UI dependencies. That keeps the CLI headless, makes the core testable without a window server, and leaves a Linux or GTK front end possible later.

### 4.3 Git execution layer

**`GitRunner`**
- Wraps `Foundation.Process`.
- Arguments are always passed as an array, never through a shell.
- Every invocation is prefixed with:
  ```
  git --no-pager -c color.ui=false -c core.quotepath=false [-c credential.helper=… when Spoon holds the token] <cmd>
  ```
- Environment:

  | Variable | Value |
  |---|---|
  | (base) | resolved login-shell env (§4.8) |
  | `GIT_TERMINAL_PROMPT` | `0` |
  | `GIT_ASKPASS` / `SSH_ASKPASS` | SpoonAskpass |
  | `SSH_ASKPASS_REQUIRE` | `force` |
  | `GIT_OPTIONAL_LOCKS` | `0` for background reads |
  | `LC_ALL` | `C` for parsed output |
  | `GIT_EDITOR` | `true` / a sequence-editor shim for scripted interactive rebase |

**Parsing**
- Output is machine-readable only: `-z`, `--porcelain=v2`, and `--format` with `%x00`/`%x1f` separators.
- Spoon never parses human-oriented output.

**Long-lived helpers.** One `git cat-file --batch` process per open repo serves blob and commit reads, so there is no process spawn per object.

**Concurrency**
- Each repository is a Swift `actor` with:
  - a **serial mutation queue**, because git ops on one repo must not overlap;
  - a concurrent read pool, capped at 4 per repo.
- A global network limiter: default 4 concurrent network ops across the app, and 1 per group run.

**Cancellation**
- Cancel sends SIGTERM to the process group, then SIGKILL after 5 s.
- Mutations that cannot be cancelled safely (index writes) are marked non-cancellable, and the UI disables Cancel for them.

**Activity log**
- Every invocation records its command line (secrets redacted), working directory, start and end time, exit code, and truncated stdout/stderr.
- These records feed the Activity Manager (§5.16).

**git version policy**
- The bundled git is the latest stable release, rebuilt per Spoon release.
- Minimum supported external git is **2.39**, which gives `--update-refs`, SSH signing and fsmonitor on macOS.
- Spoon feature-detects and degrades with a clear message.

### 4.4 Reading repository state

| Data | Command | Notes |
|---|---|---|
| Refs | `for-each-ref --format=… refs/heads refs/remotes refs/tags` + `refs/stash` reflog | Includes upstream, `upstream:track`, `worktreepath`, objectname |
| HEAD / state | read `.git/HEAD`, `MERGE_HEAD`, `rebase-merge/`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG` directly | Cheap, and exact |
| Status | `status --porcelain=v2 -z --branch --untracked-files=all [--ignored]` | `--no-optional-locks` when triggered by the background |
| History | `log --topo-order --format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%D%x00%s%x00 -z --all` streamed | Streams rows in pages of 2,000, so the first screen renders before the walk finishes. No hard 50k cap (Fork's default limit). |
| Ahead/behind | `rev-list --left-right --count A...B` | Batched per refresh |
| Diff | `diff --no-color --no-ext-diff -z -M --patch[ --cached][ -w][ -U<n>]` | Patch engine for staging (§4.4.1) |
| Blame | `blame --porcelain --incremental` | Streams; honors `blame.ignoreRevsFile` (#2301) |
| Commit-graph | Suggest `git commit-graph write --reachable --changed-paths` for repos above 50k commits, with consent | Speeds up log and path-limited history |

#### 4.4.1 Partial staging engine
- **Hunk and line staging.** Spoon generates a minimal patch for the selected lines and applies it with `git apply --cached --unidiff-zero --recount`:
  - stage: forward patch to the index;
  - unstage: reverse patch to the index;
  - discard: reverse patch to the worktree.
- **Untracked files** are staged partially through `git add -N`, which records intent-to-add first.
- **Round-trip guarantee.** After every partial operation, Spoon recomputes the diff and verifies the selection moved. On a mismatch it reverts, using its saved index backup, and shows the error.
- Index backup before a discard: the discarded content is written as a blob to `refs/spoon/discarded/<timestamp>`. That makes **"Discard" undoable** (UNDO-02).

### 4.5 Commit graph layout

- **Row order.** Git's `--topo-order`, or `--date-order` as a user option, matching Fork's "Sort commits" setting.
- **Lanes.** The *straight-branch* algorithm (pvigier, "Commit graph drawing algorithms", 2019):
  - A commit inherits the lane of its first-parent child, unless that column is forbidden.
  - The forbidden set is the columns occupied between the commit's earliest merge child and its own row.
  - Freed lanes become empty slots that are reused, so existing lanes never shift sideways.
  - This gives straight, stable lines like GitKraken and Fork rather than the wandering lines of `git log --graph`.
- **Incremental.** Lanes are assigned in a single top-down pass as rows stream in. The layout state is O(active lanes).
- **Rendering.** Each table cell draws only its own row's segments. Edges that cross many rows come from an interval tree keyed by row range. Target under 1 ms per frame for the visible rows.
- **Colors.** Lane colors come from a 12-color palette (§5.1).
  - The main branch is always lane 0, in the accent color.
  - User rules map branch-name patterns to colors (HIST-12).
- **Collapsing.**
  - Collapsing a merge hides the second-parent rows it introduced, and the layout is recomputed for those rows only.
  - First-parent mode uses `--first-parent`.

### 4.6 Refresh model

- **One FSEvents stream per window**, covering every open repo's worktree and git dir. Group dashboards add their members' git dirs only.
- Flags:
  - `FileEvents`, `NoDefer`, `WatchRoot` are always set.
  - On `MustScanSubDirs` or dropped events, do a full rescan.
- **Classification**, with a 150 ms debounce:
  - Events in `.git/HEAD`, `index`, `refs/**`, `packed-refs`, `FETCH_HEAD`, `MERGE_HEAD` or `rebase-*` mean **repo state changed**: reload refs and status.
  - Events in `.git/objects/**` or `.git/logs/**` are ignored.
  - Worktree changes mean **status changed**: re-run status for the paths, or all of status when the burst exceeds 500 paths.
- **Self-suppression.** Events that arrive while Spoon's own mutation is running on that repo are coalesced into one refresh after it finishes. `IgnoreSelf` doesn't help here, because git runs in child processes.
- **Focus.** The app also refreshes when it becomes active (Fork parity).
- **fsmonitor.** Spoon respects `core.fsmonitor` if the user has set it, and **never sets it silently**. For repos above 50k files it offers it once per repo.

### 4.7 Credentials, SSH, signing

**HTTPS**
- The default is the user's own credential helpers (osxkeychain, Git Credential Manager).
- Accounts added in Spoon store their tokens in the macOS Keychain.
- Spoon injects those tokens through a per-invocation `-c credential.helper=` pointing at SpoonAskpass in credential-helper mode, scoped to that host. Spoon never writes tokens to `.git/config` or `~/.gitconfig`.

**SSH**
- Spoon uses the system OpenSSH, so `~/.ssh/config`, `IdentityAgent`, `ProxyJump` and 1Password all work.
- `SSH_AUTH_SOCK` is inherited from launchd. Spoon detects a 1Password `IdentityAgent` and shows "Approve in 1Password" in waiting states.

**Prompts**
- SpoonAskpass sends passphrase, password, OTP and host-key prompts to the app over XPC.
- The app shows a native sheet that says which repo and host is asking. It offers "Remember in Keychain" for HTTPS passwords and SSH passphrases (`ssh-add --apple-use-keychain`).
- Prompts during group runs are queued.

**Key manager**
- Generate an ED25519 key, list existing keys, copy the public key, show the SHA256 fingerprint.
- "Add to GitHub/GitLab" through the account APIs.

**Signing**
- **GPG**: pinentry-mac is detected, and the brew install hint is shown if it is missing.
- **SSH**: `gpg.format=ssh`, with `gpg.ssh.program` auto-detected for 1Password `op-ssh-sign`.
- Spoon configures and verifies `gpg.ssh.allowedSignersFile`.
- Commit rows and details show **Verified / Unverified / Unknown key** badges, from `%G?`, `%GS` and `%GK` (#18, #679, #1512).

### 4.8 Environment resolution (fixes Fork's hook `$PATH` problems)

At launch, and again when the login shell's rc files change, Spoon resolves the user's login environment:
- Command: `$SHELL -ilc 'command env -0'`, with a 3-second timeout and a sentinel to strip any rc-file noise. This is the same approach as VS Code.
- The result is cached.
- Every git child process gets it, so `husky`, `nvm`, `pnpm`, `pre-commit`, `lefthook` and similar tools work.

Settings → Git → Environment shows the resolved `PATH`. The user can:
- add entries before or after it;
- set per-repo overrides;
- run "Test hooks environment", which runs `command -v node npm python3 git-lfs` in the repo's context and shows the results.

### 4.9 Operation log & undo

Every mutating operation writes an **OpLog entry** before and after it runs, stored under `<git-dir>/spoon/oplog.jsonl` (repo-local, so it survives Spoon reinstalls and travels with worktrees).

```json
{"id":"…","ts":"…","op":"rebase","args":["-i","abc123"],"refsBefore":{"refs/heads/feat":"…","HEAD":"…"},
 "refsAfter":{…},"indexTree":"<tree sha>","stash":"<sha of safety stash or null>","undoable":true}
```

**Undo planner** (⌘Z / ⇧⌘Z)
- **Ref-only ops** (commit, amend, reset, rebase, merge, cherry-pick, revert, branch create, delete or rename, tag ops, group pull):
  - Restore the refs to `refsBefore` with `update-ref` (old-value checked).
  - Restore HEAD.
  - If the worktree is clean, check out the restored HEAD.
- **Working-copy ops** (discard, hard reset, stash drop, checkout with discard): restore from the safety snapshot taken before the op.
  - The snapshot is `git stash create` plus a ref under `refs/spoon/snapshots/`. This is cheap, and it does not touch the worktree.
- **Never undoable:** push, remote branch delete, and remote tag delete. Spoon says so in the confirmation dialog.
- **Undo is refused** when the current state no longer matches `refsAfter`, which means something else changed the repo. In that case Spoon offers the **Operation History** panel, so the user can pick the state to restore. It is Time-Machine-style, like GitUp snapshots or the GitButler op log.

Snapshot refs older than 14 days, or beyond 200 entries, are pruned (configurable).

### 4.10 Persistence

| File | Location | Contents |
|---|---|---|
| `library.json` | `~/Library/Application Support/Spoon/` | Repositories, groups, smart groups, per-member overrides |
| `state.json` | same | Windows, tabs, per-repo view state (selected view, filters, collapsed merges, column widths) |
| `settings.json` | same | Preferences (human-readable, so it can be synced with dotfiles), plus `keybindings.json` |
| `custom-commands.json` | same (global), `.git/spoon/` (local), `.spoon/commands.json` in repo (shared, requires trust) | §6.18 |
| Group include files | `~/.config/spoon/gitconfig.d/` | Generated identity config (GRP-10) |
| Secrets | macOS Keychain only | Tokens, passphrases |

### 4.11 Distribution & security

- **Not sandboxed, and not on the Mac App Store.** The sandbox breaks the `/usr/bin/git` trampoline, hooks that need node or nvm, `~/.ssh`, the agent sockets and arbitrary repo paths. No major Mac git GUI ships through the App Store.
- **Signing and notarization**
  - Developer ID signing, Hardened Runtime, notarization with stapling.
  - **Every nested executable is signed**: the bundled git, git-lfs, libexec helpers, SpoonAskpass and spoon CLI.
- **Channels.** GitHub Releases (DMG and zip), with **Stable** and **Beta** Sparkle channels.
- **Homebrew**
  - An own tap at first: `brew install spoon-app/tap/spoon`.
  - Submit an official cask once notability is met: 75 stars, or 225 if self-submitted, and the repo must be at least 30 days old. Casks must pass Gatekeeper, and unsigned casks have been disabled since 2026-09-01.
- **No telemetry.** Crash reports are opt-in (P2) and sent to a self-hosted, open-source collector. Spoon makes no network calls except git operations, configured accounts, Sparkle and avatar fetches (avatars can be turned off, and Gravatar requests go through hashed URLs).
- **Trust prompts.** Shared custom commands, shared bug-tracker rules and repo-provided Spoon config run only after a "Trust this repository" prompt. Trust is recorded per remote URL plus path.
- **Bundled git licensing.** git is GPLv2, so Spoon publishes the matching source tarball with each release.

---

## 5. UI & UX specification

The goal is Fork-level calm: a compact, information-dense layout built from native controls, with very little chrome. Spoon keeps Fork's proven layout so Fork users feel at home. It fixes Fork's known UX complaints and adds multi-repo surfaces. Spoon has its **own** visual identity (name, icon, palette and illustrations) and does not copy Fork's artwork or assets.

### 5.1 Design language

**Typography**
- **UI font.** The system font, SF Pro, everywhere. Sizes:

  | Use | Size |
  |---|---|
  | Body / rows | 13 pt |
  | Secondary | 11 pt |
  | Section headers | 11 pt semibold, uppercase |
  | Dialog titles | 14 pt bold |
  | Detail headings | 15–16 pt |

- **Monospaced digits** in every count, SHA and date column.
- **Code font.** SF Mono 12 pt by default; any installed monospaced font can be chosen.
- **Zoom (S, #1178, #1955).**
  - ⌘= / ⌘− / ⌃⌘0 scale the whole UI, from 85% to 150% in steps.
  - Diff, commit-message and commit-list fonts can be sized independently in Settings → Appearance.

**Density**
- Default row height is 22 pt for the commit list and sidebar.
- Settings → Appearance offers **Compact (20) / Regular (22) / Comfortable (26)**.

**Color tokens**
- All colors are semantic tokens, defined once and given light and dark values.
- They are built on system colors, so the accent color, Increase Contrast and Reduce Transparency are honored automatically.

| Token | Light | Dark | Use |
|---|---|---|---|
| `bg.content` | `textBackgroundColor` | same | Lists, diff |
| `bg.header` | `windowBackgroundColor` | same | Section/diff headers |
| `diff.add.line` | systemGreen @ 14% | systemGreen @ 22% | Added line |
| `diff.add.word` | systemGreen @ 32% | systemGreen @ 42% | Intra-line add |
| `diff.del.line` | systemRed @ 12% | systemRed @ 22% | Removed line |
| `diff.del.word` | systemRed @ 30% | systemRed @ 42% | Intra-line removal |
| `diff.filler` | `quaternaryLabelColor` @ 30% | same | Side-by-side alignment filler |
| `hunk.active.border` | `controlAccentColor` | same | Hovered/selected hunk outline |
| `hunk.active.fill` | accent @ 8% | accent @ 14% | |
| `conflict.ours` | systemTeal @ 14% | systemTeal @ 24% | Merge tool |
| `conflict.theirs` | systemIndigo @ 14% | systemIndigo @ 24% | Merge tool |
| `conflict.unresolved` | systemRed @ 30% | systemRed @ 40% | |
| `search.match` | systemYellow @ 55% | systemYellow @ 45% | Search hits |
| `status.ahead` | accent | accent | ↑ counts, unpushed dot |
| `status.behind` | `secondaryLabelColor` | same | ↓ counts, unpulled dot |

- **Graph lane palette.** 12 colors, in this order: systemBlue, systemOrange, systemGreen, systemPink, systemPurple, systemTeal, systemYellow, systemRed, systemIndigo, systemBrown, systemMint, systemGray.
  - Each has a "fill" variant at 15% for ref-label pills.
  - The palette is user-replaceable through themes (P2).
- **Color-blind safety.** A "Show +/− markers" option, plus a **Deuteranopia-safe diff** alternative that uses blue for added and orange for removed.

**Dark mode**
- Follows the system, or can be forced to Light or Dark.
- All drawn colors come from tokens. There are no bitmap icons; everything is SF Symbols or template vector images.

**Iconography**
- **SF Symbols** for every toolbar and menu icon.
- **File status badges**: rounded-square glyphs with a letter.

  | Badge | Status | Color |
  |---|---|---|
  | `M` | Modified | systemYellow |
  | `A` | Added | systemGreen |
  | `D` | Deleted | systemRed |
  | `R` | Renamed | systemBlue |
  | `C` | Copied | systemTeal |
  | `T` | Type change | systemGray |
  | `U` | Untracked | systemGreen, outlined |
  | `!` | Conflicted | systemOrange |

  Letters are included so the badges are not color-only, which matters for accessibility.
- **Remote service logos** for GitHub, GitLab, Bitbucket, Azure, Gitea/Forgejo and generic. They are drawn as monochrome template images.

**Motion**
- Minimal: 150 ms ease-out for stage/unstage row moves, expand and collapse, and sheet presentation.
- Honors Reduce Motion.
- No spinners for operations under 300 ms. Progress appears only after a 300 ms delay, so fast operations never flash.

**Feel**
- Real menus with key equivalents for everything.
- Sheets for dialogs and popovers for quick confirmations.
- Native window tabs.
- Resizable split views with snap points and remembered sizes.
- Nothing modal blocks other repos or windows.

### 5.2 Window anatomy

```
┌───────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [Quick Launch] [Fetch] [Pull ↓4] [Push ↑1] [Stash▾] ┃ payments-api  ⎇ main ⌄  ↑1 ↓4 ≡ ┃ [Branch+] ⋯ [Open in▾] │  ← unified toolbar
├──────────────┬────────────────────────────────────────────────────────────────────────────────┤
│ ⌂ Home       │ [ payments-api* ] [ ledger ] [ web-checkout ] [ + ]                            │  ← repo tabs (scoped to group)
│ ── GROUPS ── ├────────────────────────────────────────────────────────────────────────────────┤
│ ▾ Work       │ ▣ Local Changes (3)   │ ⌕ Search SHA, author, message, path:…             ⚙ │
│   Payments ●2│ ◉ All Commits         │ ○ ┄ Uncommitted changes (3)                           │
│   Platform   │ [⎇ refs | ⌕ search]   │ ● ─┐ [main ✓][origin/main] Fix rounding in ledger   …│
│ ▸ Personal   │ ⌕ Filter              │ │  ● Add retry to webhook client              Kim  2h │
│ ── REPO ──   │ ▸ WORKTREES           │ ● ─┘ Merge branch 'feat/x'                     Sam  5h │
│ (sidebar is  │ ▾ PINNED              │ ...                                                    │
│  per tab,    │ ▾ BRANCHES            ├────────────────────────────────────────────────────────┤
│  see 5.6)    │   ✓ main        ↑1 ↓4 │ [ Commit | Changes | File Tree ]                       │
│              │     feat/x         ↑2 │  AUTHOR  Kim Lee <kim@…>   COMMITTER  …               │
│              │ ▸ REMOTES             │  SHA 3fa2…  PARENTS 81bc · 77ea   REFS [main ✓]        │
│              │ ▸ TAGS                │  Fix rounding in ledger                                │
│              │ ▸ STASHES (2)         │  ▸ M src/ledger/round.swift   ▸ A tests/RoundTests…   │
│              │ ▸ SUBMODULES          │                                                        │
│              │ ▸ PULL REQUESTS (4)   │                                                        │
└──────────────┴───────────────────────┴────────────────────────────────────────────────────────┘
  status: ● Fetching ledger (group sync 2/12)                                                     ← optional status bar (P1)
```

**Layout regions**
- **Window sidebar** (far left, optional and collapsible with ⌃⌘S):
  - **Home** and the **Groups** tree.
  - Clicking a group scopes the window's tabs to that group.
  - It can be hidden for a Fork-identical single-sidebar look. That answers Fork #934 (hide sidebar).
- **Repository sidebar.** One per tab (§5.6).
- **Main area.** Either:
  - **Horizontal layout** (default; Fork style): the commit list on top and details below; or
  - **Vertical layout** (S, #756): the commit list on the left and details on the right, for wide monitors.

  Switch with View ▸ Layout or ⌥⌘L. The choice is stored per window.
- **Collapse details.** ⇧⌘D hides the details pane entirely.

### 5.3 Toolbar

- **Default items, left to right:**
  - **Quick Launch**
  - **Fetch**, **Pull**, **Push**. Pull and Push carry ahead/behind badges.
  - **Stash ▾**, with a menu: Save Stash…, Quick Stash, Snapshot, Pop Latest.
  - *Flexible space*
  - **Repository Status control**
  - *Flexible space*
  - **New Branch**
  - **Open in ▾**: Finder, Terminal, editor and custom commands.
  - **Group Sync ▾** (S): visible when the window is scoped to a group; offers Fetch Group, Pull Group and Dashboard.
- **Optional items** (Customize Toolbar…): Refresh, Undo / Redo, Branch filter, Terminal, Finder, Search, Activity, Create PR, and **any custom command** (S, #439).
- **Quick variants.** ⌥-click Fetch, Pull or Push runs it immediately with the remembered options, without the dialog (Fork parity). The button tooltip shows exactly what will run, e.g. "git pull --ff-only origin main".
- **Repository Status control.** A rounded box with:
  - **Line 1:** repo name, bold.
  - **Line 2:** `⎇ branch ⌄`, a popup that lists local branches, then remote branches, with type-ahead filtering.
  - **Right:** `↑a ↓b`.
  - **Left:** an Activity button (`≡`) that badges when an operation is running or has failed.
  - **During an operation:** a spinner, then the operation title and step ("Pulling origin/main… receiving 43%"), a ⊗ cancel button, and a 2 pt progress line along the bottom edge in the accent color.
  - **Clicking a label** anywhere in the control works (fixes #1276, where only the icon was clickable).
- **Display modes.** Icon and Text (default), Icon Only and Text Only.

### 5.4 Tab bar

- Native `NSWindow` tabbing, so it uses system behaviors: drag to reorder, drag out into a new window, merge windows, ⇧⌘\ for the tab overview.
- **Tab title.** The repo name.
  - If two open repos share a name, Spoon adds the first differing path segment.
  - Worktree tabs show `repo · worktree`.
- **Badges.**
  - `●` means uncommitted changes.
  - `↓n` means behind (optional).
  - A colored dot shows the group color.
  - A spinner shows while an operation is running.
- **Tab context menu.** Rename Tab, Tab Color, Add to Group ▸, Open in Terminal, Show in Finder, Copy Path, Close Other Tabs.
- **Shortcuts.** ⌘1–⌘9 switch to tab N (S, #671), but only when the option "⌘-number selects tabs" is on. Otherwise ⌘1 and ⌘2 keep Fork's meaning (Local Changes and All Commits; see §9).
- **Restore.** ⇧⌘T reopens the last closed tab.
- **Vertical tabs** (P2) list tabs in the window sidebar under the group.

### 5.5 Home (Repository Manager)

Opened with ⌘T (new tab) or ⇧⌘0. The window sidebar is the Groups tree, shown in the left pane.

| Selection | Main area |
|---|---|
| **Home** (no group) | **All Repositories** table with columns Name, Path, Groups, Branch, Status, Last opened. Filter field. Above the table, buttons for **Open…**, **Clone…**, **New…** and **Scan Folder…**, with drag-and-drop from Finder. Below them, a **Recent** strip with the 8 most recent repos. |
| **A group** | **Group Dashboard** (§3.3) |
| **A repository** | **Repository Summary**: the name (24 pt), a path breadcrumb with reveal, a key/value grid (Changed files, Size, Commits, First commit, Last commit, Current branch), remotes with service icon and links (Repository · Issues · Pull Requests), a rendered **README**, and a **Statistics** tab with commits per month per author, by weekday and by hour, plus a date range (P2). |

- **Group tree interactions**
  - Drag repos onto groups. Drag groups to nest them.
  - Multi-select repos, then right-click ▸ Add to Group / New Group from Selection.
  - Groups with dirty repos show a dot. Groups with failed syncs show a ⚠ badge.
- **Missing repos.** A repo whose path no longer exists gets a ⚠ icon and a "Locate…" action. It is never removed automatically.
- **First run** has three steps:
  1. Identity: name and email, prefilled from git config if it exists.
  2. Choose source folders to scan. The dialog suggests `~/Code`, `~/Developer`, `~/Projects` and `~/src` when they exist.
  3. Review the repos found, with the option **"Create groups from folders"**.

  Every step can be skipped.

### 5.6 Repository sidebar

From top to bottom:

1. **Header.**
   - Repo name, plus a `⋯` menu with Repository Settings…, Copy Path, Select Stale Branches…, Clean…, Maintenance ▸ (gc, commit-graph, prune) and Open Group Dashboard.
2. **Views.**
   - **Local Changes (n)**.
   - **All Commits**.
   - **Reflog** (S, P1). An explicit view that also replaces Fork's hidden "Show lost commits" toggle.
3. **Mode switch.** `⎇ References` or `⌕ Search` (§5.7.3).
4. **Filter field.**
5. **Collapsible sections:**
   - **Worktrees**.
   - **Pinned**.
   - **Branches**: folders built from `/`.
   - **Remotes**: each remote, then its branches in folders.
   - **Tags**: sortable by name, by version (semver-aware, S) or by date.
   - **Stashes**: message and age.
   - **Submodules**: a nested tree with a dirty indicator.
   - **Pull Requests** (S, P1): open PRs for this repo, labeled "Mine" or "Review requested", with a CI status dot.
   - Each section's header has a `+` (New Branch, Add Remote, New Tag and so on), a sort menu, and remembers whether it is collapsed.

**Rows**
- The **current branch** shows ✓ and bold text.
- Ahead/behind counts are right-aligned in gray.
- Upstream state is shown as:
  - local-only: a dimmed icon;
  - gone: a ⚠ icon with the tooltip "Upstream 'origin/x' no longer exists";
  - checked out in another worktree: a worktree icon.
- **Hovering** a row shows pin and filter (funnel) buttons.
- **Hide or filter.** Rows and folders can be hidden (the eye icon), and the hidden state is persisted. Rows can also be *filtered* so that only their history shows in the commit list. Several rows can be filtered at once.
- **Custom colors** (S, #2358). The context menu offers Color ▸, which sets the color of the ref label and graph lane. Pattern rules can be set in Repository Settings.

**Interactions**
- Double-click a local branch to check it out. Double-click a remote branch to check out a local tracking branch, or switch to it if one exists, and offer to fast-forward.
- Drag a branch onto another branch to get a popover: Merge `a` into `b`, Rebase `a` onto `b`, Create PR `a` → `b`.
- ⌘-click two refs to compare them: the main area shows a range view (§5.8.4).
- Multi-select, then Push / Delete / Fast-forward on the selection.
- ⌫ deletes, with confirmation. F2 or Return renames.
- Keyboard: ↑↓ navigation, Tab to focus the commit list, Type-select by typing a name.

### 5.7 Commit list & graph

#### 5.7.1 Rows
- **Columns:** Graph · Refs + Subject · Author (16 pt avatar + name) · SHA (7) · Date.
  - Columns are reorderable and hideable. A header row is optional; it is off by default, as in Fork.
- **Dates.**
  - Relative for recent items ("Today 14:29", "Yesterday 22:05").
  - Absolute otherwise.
  - The format can be set to relative, absolute, ISO 8601 or custom (S, #717).
- **HEAD** is bold. Commits that are not reachable from the current branch can be dimmed (toggle).
- **Sync dots.**
  - A small accent dot before the subject means the commit hasn't been pushed.
  - A hollow gray dot means the commit is in the upstream but hasn't been pulled.
- **Glyphs.**
  - `↩︎` when the commit has a body.
  - Signature badge (✓ verified, ? unknown) when signature display is on.
  - Issue and PR references are linked through bug-tracker rules.
- **Ref label pills.**
  - Rounded, with a 1 px border in the lane color and a 15% fill.
  - Icons: ✓ for the current branch, the service logo for remote branches, a tag glyph for tags, a box for stashes.
  - **Compact labels** merge `main` and `origin/main` into one pill shown as `main ⇄ origin` when they point at the same commit.
  - If there are too many labels, the overflow collapses into `+3` with a popover.
- **Uncommitted row** (S, #308). An optional top row shows **"Uncommitted changes (n)"** on the HEAD lane, drawn as a hollow node. Clicking it shows Local Changes inside the details pane.
- **Hover.** Hovering a node highlights its lane and its parent edges. A tooltip on a merge commit lists the merged branch.
- **Space** opens a Quick Look-style popup with the commit details. Space again closes it.

#### 5.7.2 Graph behavior
- **Stable lanes.** Lanes are straight and stable (§4.5). The main and integration branches keep lane 0.
- **Collapsible merges.**
  - Clicking a merge node's chevron, or pressing ← / →, collapses or expands it.
  - View ▸ "Collapse All Merges (First Parent)" collapses them all.
- **Graph column width.** The graph column can be resized. If lanes exceed the width, they fade at the edge, and hovering scrolls the graph horizontally (S, #516).
- **Branch filter.**
  - "Show: All branches / Current branch (⇧⌘A) / Filtered refs".
  - A filter bar above the list reads `Showing: main, origin/main  ✕ Clear`.
- **View toggles:** Hide tags, Hide stashes, Hide remote branches, **Hide merge commits** (S, #406), Show reflog-only commits.
- **Drag and drop on the list.**
  - Dragging a commit onto another commit of the **active branch** gives a popover: **Squash into**, **Fixup into**, **Move here (reorder)**.
  - Dragging a commit onto a **branch label** gives **Cherry-pick onto `x`**.
  - Each drop previews the result and predicts conflicts before running anything.

#### 5.7.3 Search
- **⌘F (in-list find)** opens a bar over the list.
  - Placeholder: "Search SHA, author, message".
  - It shows a match count, ‹ › buttons, Return / ⇧Return for next / previous, and ⌘G / ⇧⌘G (S; these don't work in Fork's list, #309).
  - Matches are highlighted in rows and inside labels.
- **Search mode** (sidebar ⌕, or ⌥⌘F) is a full query language (S, modeled on Sublime Merge's):

  ```
  author:kim  committer:  message:"rounding"  path:src/ledger/**  contents:"retryCount"
  sha:3fa2  ref:origin/*  after:2026-01-01  before:"2 weeks ago"  merges:no  signed:yes
  -author:bot   (author:kim or author:sam) path:*.swift
  ```

  - Each part maps to git:

    | Query part | git |
    |---|---|
    | `contents:` | `log -S` (pickaxe) |
    | `regex:` | `-G` |
    | `path:` | pathspec, with `:(glob)` |

  - Results stream into a list with a count. Recent queries are remembered.
  - **Delete** removes a result from the list, so the list can be worked through like a to-do list (Fork parity).
- **Commit message hyperlinks.** Clicking a SHA in a message jumps to that commit.

### 5.8 Commit details

**Tabs:** a segmented control with **Commit | Changes | File Tree**, switched with ⌥⌘1/2/3. The selected tab is remembered.

#### 5.8.1 Commit tab
- **Header.**
  - **AUTHOR** and **COMMITTER** columns, each with a 40 pt avatar, name, email and full date. Committer is hidden when it is identical to the author.
  - Rows for **REFS** (pills), **SHA** (full, click to copy), **PARENTS** (links), **SIGNATURE** (badge, key and signer), and **CO-AUTHORS** (S).
  - **Contained in** (S, P1): "on 3 branches, 2 tags, first in tag v2.4.0" (`git branch --contains`, `describe --contains`), computed lazily.
- **Message.**
  - The subject is shown large, with links. The body is rendered as plain text with a monospace option, and `Co-authored-by` and other trailers appear as chips.
- **File list.**
  - Status badge, file icon and path, with `+12 −3` stats per file.
  - **Expand All** shows a **continuous multi-file diff** of every file, one after another (S, #261), with a sticky file header while scrolling. A preference makes it expanded by default (#420).

#### 5.8.2 Changes tab
- **Header:** avatar, author, SHA, date and subject on one line.
- **Left pane: file list.**
  - Modes: Tree, List, Combined list.
  - Filter field (S, #428/#1555).
  - Stats per file.
- **Right pane: the diff** (§5.10).
- **Merge commits.** A popup chooses what to diff against: first parent (default), second parent, or a combined diff (`--cc`).

#### 5.8.3 File Tree tab
- The full tree at the commit, with a **filter / fuzzy search** (S, #428).
- Selecting a file shows its content with syntax highlighting.
- **Context menu:** Open, Save As…, History, Blame, Reset File to This Revision…, Copy Path, Show in Finder (current version).

#### 5.8.4 Comparisons
- Selecting two commits (⌘-click) shows the diff between them. A **swap** button switches the direction.
- Other comparisons:
  - Commit ↔ working copy ("Compare to Local Changes").
  - Branch ↔ branch, via ⌘-click on two refs. This shows the **commits only in A**, the **commits only in B**, and the **combined diff** (three tabs; S).
  - Stash ↔ working copy.
  - **Range-diff** between two versions of a branch (S, P2), useful after a rebase.
- **Open in Separate Window** pops a comparison out.

### 5.9 Local Changes

```
┌──────────────────────────────┬─────────────────────────────────────────────────────────────┐
│ ⌄⌄  👁  ≡     ⌕ Filter files │  src/ledger/round.swift        [⎵][¶][↩][±3▾][↕][◫][‹ ›] │
│ UNSTAGED (2)        [Stage]  │  @@ -41,6 +41,7 @@ func round(…)                            │
│  M src/ledger/round.swift    │   41  41      let scale = pow(10, places)                   │
│  U docs/notes.md             │   42     -    return (x * scale).rounded() / scale     ┌──────────────┐│
│                              │       42 +    return (x * scale).rounded(.toNearestOrEven…│Stage│Discard…││
│ STAGED (1)        [Unstage]  │       43 +    // banker's rounding                     └──────────────┘│
│  A tests/RoundTests.swift    │                                                             │
├──────────────────────────────┤                                                             │
│ ┌──────────────────────────┐ │                                                             │
│ │ Commit subject       42 ≡│ │                                                             │
│ │ Description              │ │                                                             │
│ │                          │ │                                                             │
│ │ 👥 Co-authors  ✎ signed  │ │                                                             │
│ └──────────────────────────┘ │                                                             │
│ ☐ Amend   ✨        [Commit 1 File ▾]│                                                             │
└──────────────────────────────┴─────────────────────────────────────────────────────────────┘
```

**File lists**
- **Unstaged** above **Staged**, with a resizable split that snaps.
- **Header buttons:** collapse all, 👁 (Show Untracked / Show Ignored, ⇧⌘.), and layout (Tree / List).
- **Filter field** for files (S).
- **Stage All / Unstage All.** Shown as header buttons. Holding ⌥ swaps "Stage" for "Stage All".
- **Staging a file:** double-click, Return or ⌘S, or drag between the lists. After staging, the next file is selected.
- **Discard:** ⌫ or ⇧⌘D, with a confirmation that says "Discarded changes can be restored with Undo (⌘Z)". Undo is guaranteed by the discard backup (§4.4.1).
- **Untracked folders** collapse into a single row (`newdir/ (12 files)`), which expands on click.
- **Conflicted files** sit in their own **CONFLICTS** section at the top, with ⚠ icons.

**Hunk and line staging**
- **Hovering a hunk** outlines it with `hunk.active.*` and shows floating buttons at its top right:
  - **Stage** and **Discard…** in the unstaged diff;
  - **Unstage** in the staged diff.
- **Selecting lines** (by drag, by clicking or ⇧-clicking line numbers, or with the keyboard: ↑↓ to move, ⇧ to extend) shows the same buttons beside the selection. Return stages the selection.
- **"Split hunk"** (S): splits a hunk at the cursor.
- The diff header has an **"Edit hunk…"** escape hatch that opens the patch in a text sheet.
- If staging fails because of ignore-whitespace, Spoon offers to turn it off and retry (Fork parity).

**Commit box**
- **Subject field.**
  - A counter appears near the soft limit; it is orange past the soft limit (default 50) and red past the hard limit (72).
  - The `≡` menu holds: Recent messages (last 20), Templates ▸, Insert Co-author…, Insert Trailer ▸ (Signed-off-by, Fixes, Refs), and Conventional Commit type ▸ (S, #714; enabled per repo).
- **Description field.**
  - Auto-growing, with an optional page guide at column 72 and "Wrap paragraph at ruler" (⌃Q).
  - Spell check is on.
  - Optional monospace font.
  - Emoji shortcodes are previewed (`:bug:` shows 🐛) (S, #296).
- **Co-authors row** (S, #890):
  - A token field that autocompletes from `git shortlog -sne` and `.mailmap`.
  - It writes the `Co-authored-by:` trailers.
- **Signing indicator.**
  - Shows what will happen: "Signed with SSH key …a1b2" or "Not signed".
  - Clicking it opens the signing settings.
- **Options.**
  - **☐ Amend**: loads the previous message and shows the HEAD commit's changes, clearly labeled. If HEAD is already pushed, it warns "will require force push".
  - **☐ Sign-off**: per repo.
  - **☐ Skip hooks** (S, #1239): persists for one commit only, then resets.
- **✨ Generate message** (AI, §6.21): streams into the fields. The result is editable and never auto-committed.
- **Commit button** — **"Commit n Files"**, with a split menu ▾:
  - Commit;
  - **Commit and Push**: ⌥ turns the main button into this, or press ⌥⌘Return;
  - Commit and Create PR…;
  - **Fixup into…** (S, #275): pick a commit, and Spoon creates a `fixup!` commit and offers to autosquash.
  - The button is disabled when nothing is staged, the subject is empty, or the repo is mid-conflict. The tooltip says which.
- **Hooks.**
  - Hook output streams live into an inline disclosure under the commit box, with elapsed time.
  - On failure, it offers **Skip hooks and commit** or **Copy output**.
- **Warnings** appear inline above the button: detached HEAD, committing on a protected branch (per-repo list; S), and staged files larger than N MB that are not tracked by LFS.

### 5.10 Diff viewer

**Header**
- The file icon, then the path, with the file name emphasized. Renames show `old → new`, and mode changes show `100644 → 100755`.
- Toggle buttons on the right:

  | Button | Meaning |
  |---|---|
  | ⎵ | Ignore whitespace |
  | ¶ | Show invisibles |
  | ↩ | Wrap, which also works side by side (fixes #1338) |
  | ±n▾ | Context lines: 0, 1, 3, 5, 10, 25, or entire file |
  | ↕ | Entire file |
  | ◫ | Unified / Side-by-side |
  | ‹ › | Previous / next change |
  | ⋯ | More: word diff, moved-line detection, open in external diff, open in editor at line, copy as patch |

**Body**
- Two gutters (old and new line numbers) in unified mode, or one gutter per pane side by side. A side-by-side pane is filled with blank filler where the other side has lines.
- **Syntax highlighting** with tree-sitter. Spoon highlights the full old and new blobs and then maps the tokens onto diff lines, so unclosed strings and comments stay correct.
- **Intra-line highlighting.** Changed characters are highlighted inside changed lines. **Word-diff mode** (S, #100) renders `--word-diff` inline.
- **Moved lines** (S, #1443). `--color-moved` detection is shown with a distinct border color and a "moved from line n" hover.
- **Minimap scrollbar** showing change locations, hidden when the content fits.
- **Expand context.** Clicking the `⋯` row between hunks expands 20 lines, and ⌥-click expands all.
- **Search** with ⌘F (it persists when switching files). ⌘↑ / ⌘↓ jump to the previous / next hunk.
- **Context menu:** Copy, Copy as Patch, History of Selected Lines…, Blame Line…, Open in Editor at Line, Reveal in Finder, Stage / Discard Selection.

**Special content**

| Content | Display |
|---|---|
| **Binary** | Size old → new, and "Open with…" |
| **Large file** (> 2 MB or > 20k lines) | A placeholder with "Load diff anyway". The cap is configurable. |
| **Minified line** (> 2,000 chars) | The line is truncated with "show full line" |
| **Images** (PNG, JPEG, GIF, HEIC, WebP, TIFF, BMP, TGA, SVG, PDF) | Modes **Side by Side / Swipe / Onion Skin / Difference** (pixel highlight); dimensions and size captions; checkerboard background for transparency; zoom ⌘+ / ⌘− and 1:1 |
| **LFS pointer** | "Download and preview" |
| **Submodule** | Commits added and removed in the submodule, with **Update Submodule** and **Open Submodule** |
| **Markdown** (S, #159) | A **Rendered** toggle shows the old and new rendered Markdown side by side |

**Side-by-side quick view.** Space on any file opens a full-window side-by-side overlay. Esc or Space closes it.

### 5.11 Merge conflict resolver

**Entry**
- A conflicted file selected in Local Changes shows a panel with:
  - the explanation text and the two sides labeled with **real names** ("Yours: ⎇ main" / "Theirs: ⎇ origin/feature");
  - **Take Yours**, **Take Theirs**, **Merge in Spoon…**, **Merge in External Tool**.
- **Delete/modify conflicts** offer **Keep File** or **Delete File**.
- **Binary conflicts** offer a choice between the two sides, with previews.

**Merge editor** (sheet, or a separate window with ⌥)

```
┌─ src/ledger/round.swift ───────────────────────────────── Conflict 2 of 5  [‹][›]  [◫ ▤] ─┐
│ ☐ Theirs: ⎇ origin/feature          │ ☐ Base (toggle)     │ ☐ Yours: ⎇ main             │
│   …                                 │   …                 │   …                         │
│ ▌ return x.rounded(.up)        [→]  │ ▌ return x.rounded()│ [←] ▌ return round(x, 2)   │
├─────────────────────────────────────┴─────────────────────┴─────────────────────────────┤
│ Result (editable)                                                                        │
│   ▌ <<< unresolved: choose a side or edit >>>                                            │
├──────────────────────────────────────────────────────────────────────────────────────────┤
│ Resolved 1 of 5     [Take Theirs All] [Take Yours All]    ⌘Z Undo     [Cancel] [Save & Stage] │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

**Panes**
- **Top:** Theirs and Yours, with an optional **Base** pane (S) for a three-way view.
- **Bottom:** the **editable Result**. The layout toggle (◫ ▤) switches to a horizontal arrangement.

**Picking chunks**
- Each conflict chunk has **→ / ←** pick buttons and a checkbox. Ticking *both* checkboxes takes both sides, in a chosen order (Theirs first, or Yours first).
- Unresolved chunks are marked in the result and in the scrollbar.
- **Auto-resolvable chunks** (whitespace-only or identical changes) are resolved automatically. They are listed in the footer, and the user can review them.

**Editing and undo** (S, #2320): full ⌘Z / ⇧⌘Z inside the editor.

**Saving**
- **Save & Stage** is disabled until every chunk is resolved, or ⌥ forces it.
- **Revert file to conflicted state** (S) is available afterwards.

**Repository-level conflict state**
- A **notification bar** across the top of the repo view reads:
  - "Merging `feature` into `main` — 3 conflicted files", with buttons **[Continue]** (enabled when everything is resolved) and **[Abort]**.
  - The same bar handles rebase ("Rebasing 3/7: *subject*" with Continue / Skip / Abort), cherry-pick, revert and bisect.
- **Conflict prediction.** The Merge, Rebase, Cherry-pick, Revert and Pull dialogs run `git merge-tree --write-tree` (git ≥ 2.38) *before* they execute. They show either "✓ No conflicts expected" or "⚠ Conflicts expected in 2 files: …", with the file list.

### 5.12 Interactive rebase

- **Entry points:**
  - the commit context menu ▸ Interactive Rebase ▸ "Rebase `main` from here interactively…";
  - the branch context menu;
  - Quick Launch.
- **Quick actions** run without the dialog: **Reword…, Edit, Squash into Parent, Fixup into Parent, Drop…, Move Up, Move Down, Amend Staged Changes into This Commit** (S, the lazygit Shift+A equivalent), and **Split Commit…** (S, P2; a visual hunk splitter).
- **Dialog (sheet).**
  - **Title:** "Interactive Rebase: ⎇ main onto ◦ 81bc Fix…".
  - **Table columns:** Action · Graph · Avatar · Subject · Author · SHA · Date.
  - **Action** is a popup with a colored dot:

    | Action | Color | Key |
    |---|---|---|
    | Pick | green | P |
    | Reword | orange | R |
    | Edit | blue | E |
    | Squash | gray | S |
    | Fixup | gray | F |
    | Drop | red, with the row struck through | D |
    | Exec (S, P2) | | |

  - The Graph column draws arrows from squash and fixup rows into their target.
  - **Reorder** by dragging, or with ⌘↑ / ⌘↓. Multi-select applies an action to every selected row.
  - **Reword inline.** Opens an expanding editor in the row. It is full width, with a subject and a multi-line body (S, #2480: Fork's reword fields are too small).
  - **Bottom pane:** the selected row's Commit and Changes, read-only.
  - **Footer:**
    - ☑ **Create backup branch** (on by default), which writes `spoon/backup/<branch>-<time>`.
    - ☐ **Update dependent branches** (`--update-refs`).
    - ☐ **Autostash local changes** (S, #1268).
    - ☐ **Rebase merges** (`--rebase-merges`; S, #616).
    - A conflict-prediction line.
    - **[Cancel] [Start Rebase]**.
- **During the rebase.**
  - The notification bar shows progress, Continue / Skip / Abort, and **Edit stops**.
  - At an Edit stop, the Local Changes view is shown with ☑ Amend pre-checked.
- **Execution.** Spoon writes the todo list itself and passes it through `GIT_SEQUENCE_EDITOR`, so the actual rebase is real git and stays transparent.

### 5.13 Dialogs

**Common pattern**
- Dialogs are sheets: a Spoon icon, a bold title, a one-line description, a right-aligned label column, Cancel, and a default button whose verb names the result ("Create Branch", not "OK").
- **Ref chips** show the branch icon and name, or the SHA and subject. Ref fields accept typing with autocomplete.
- **Last-used options** are remembered per repo.
- A **"Show command"** disclosure (S) reveals the exact git commands the dialog will run, e.g.:
  ```
  git fetch origin && git merge --ff-only origin/main
  ```
- A shared **Local changes** radio group: ◉ Keep (fail if there is a conflict) ○ Stash and reapply ○ Discard ⚠.

| Dialog | Fields & options |
|---|---|
| **Clone** ⇧⌘N | URL (paste is detected automatically, and Spoon validates it with **Test Connection** via `ls-remote`), or **pick from an account's repos** with search; Location, defaulting to the last-used parent; Name; HTTPS/SSH switch; ☐ Recurse submodules; Depth (full / shallow N; S, #1400); ☐ Partial clone `--filter=blob:none` (S, #1829); Branch; **Add to group ▾** (S); ☐ Open after cloning |
| **Init** | Location; Initial branch (default from `init.defaultBranch`); .gitignore template; ☐ README; ☐ Initial commit; Add to group |
| **Open** ⌘O | Folder picker. Also accepts a drag onto the Dock icon or window. |
| **Fetch** ⇧⌘F | Remote ▾ / All remotes; ☑ Prune; ☐ Fetch tags; ☐ Fetch submodules |
| **Pull** ⇧⌘L | Remote; Branch; Into (current); **Strategy**: Fast-forward only / Merge / Rebase (default from `pull.rebase` / `pull.ff`); Local changes radios; conflict prediction |
| **Push** ⇧⌘P | Branch(es) table with Local → Remote:Branch (editable target); ☐ Set upstream; ☐ Push tags (all / annotated, following refs); ☐ **Force with lease** (⚠, shows the commits that will be overwritten on the remote); ☐ Skip pre-push hook (S); "Remote is ahead by n: Pull first?" warning |
| **New Branch** ⇧⌘B | Start at; Name (spaces become - or _; folder autocomplete; validation with `check-ref-format`); ☑ Check out; ☐ Track remote; Local changes radios |
| **Checkout** ⌘B | Quick picker (popover) with fuzzy search over local and remote branches, recent branches first; ⌥Return opens the full dialog with Local changes radios |
| **Merge** | Merge ⎇ X into ⎇ current; **Type**: Default (ff if possible) / No fast-forward / Fast-forward only / Squash / No commit; message editor (for `--no-ff`); conflict prediction |
| **Rebase** | Rebase ⎇ current onto ◦ target; commit list that will be replayed; ☐ Update dependent branches; ☐ Autostash; ☐ Interactive (opens §5.12); conflict prediction |
| **Cherry-pick** | Commit(s) listed; Parent (for merges); ☐ Commit (vs leave staged); ☐ Append "(cherry picked from …)" `-x`; conflict prediction |
| **Revert** | Commit(s); Parent (for merges); ☐ Commit; conflict prediction. **Revert selected hunks** is available from the diff context menu (S, #333). |
| **Reset** | Branch: current; To: ◦ commit; **Mode**: Soft (keep all, stage differences) / Mixed (keep all, unstage) / Hard ⚠ (discard; "recoverable with Undo") / Keep (`--keep`; S) |
| **New Tag** ⇧⌘G | At; Name (suggests the next semver, S); ☐ Annotated (default on), with Message; ☐ Sign; ☐ Push to ▾ remote |
| **Stash** ⇧⌘H | Message; ☐ Include untracked; ☐ Keep index (S); ☐ **Only staged changes** (`--staged`; S, #281); Partial stash comes from file and hunk selection |
| **Apply Stash** | Stash; ☐ Delete after applying (pop); ☐ Restore index (S); note "Stash is kept if a conflict occurs" |
| **Delete Branch** | Branches list; ☐ Also delete remote branch; ☐ Also delete worktree; a warning if the branch is not merged into its upstream or main: "n commits will only be reachable via Undo" |
| **Rename Branch** | New name; ☐ Also rename on remote (push new, delete old, set upstream) |
| **Add / Edit Remote** | Name; Fetch URL; Push URL (S); HTTPS/SSH switch; Account; Test Connection; ☐ Fetch now |
| **Create Worktree** | Branch (existing or new) / Commit; Location (default `../<repo>.worktrees/<branch>`); ☐ Open in new tab |
| **Add Submodule** | URL; Path; Branch; ☐ Recursive |
| **Clean** (S) | List of untracked and ignored files with checkboxes (`clean -n` preview); ☐ Include ignored; ☐ Include directories. "Move to Trash" is the default, instead of permanent delete. |
| **Bisect** | Good ◦; Bad ◦; then the bar shows Good / Bad / Skip / Reset, a progress estimate ("~4 steps left"), and an optional **Run script…** (`bisect run`; S) |
| **Apply Patch** | File(s), drag and drop, or ⌘V from the clipboard; ☐ Create commit (`am`) vs apply to the working tree; ☐ 3-way; a preview of the files affected |
| **Archive** (S) | Ref; Format zip / tar.gz; Prefix; Destination (`git archive`) |
| **Error sheet** | Plain-language summary ("Push rejected: remote has commits you don't have"), **Suggested fix** buttons (Pull then Push, Force with lease…, Remove stale `index.lock`, Switch git instance), and a disclosure with the full git output and the command |

### 5.14 Quick Launch (⌘P)

- **The panel.**
  - A floating vibrancy panel near the top of the window, about 640 pt wide.
  - A large search field.
  - Results are grouped as Commands, Repositories, Groups, Branches and Files.
- **Empty query** shows Recent repositories, Recent commands, then the pinned branches of the current repo.
- **Fuzzy matching** highlights the matched characters, and ranking learns from frequency and recency.
- **Every menu command is indexed**, plus custom commands, groups (Switch to group, Fetch group, Pull group), worktrees and stashes.
- **Parameterized commands** become a **token chip** and then list their arguments:
  - `Checkout ▸` lists branches;
  - `File History ▸` lists repository files, with fuzzy path search;
  - `Open ▸` lists repositories;
  - `Pull Group ▸` lists groups;
  - `Blame ▸` lists files;
  - `Compare ▸` takes ref A, then ref B.
- **Prefixes:**

  | Prefix | Searches |
  |---|---|
  | `>` | commands only |
  | `@` | branches |
  | `#` | PRs |
  | `/` | files |
  | `:` | go to commit by SHA |
  | `?` | help |

- **Keys.** Return runs the selection. ⌘Return opens a repository in a new tab or window. Tab completes a token. Esc goes back one level.
- **Each row shows its shortcut** on the right, which helps people learn the shortcuts.
- **IME composition** works (Fork has a known bug here).

### 5.15 Context menus

The context menus below repeat Fork's coverage. Items marked S are new. Each one also appears in the main menu or Quick Launch, so they are discoverable (an HN complaint was that Fork's blame and history are hidden).

**Commit row**
- `ref ▸` for each ref on the commit: Checkout, Merge into current, Rebase current onto, Delete, Create PR, Copy name.
- Checkout Commit… · Create Branch Here… ⇧⌘B · Create Tag Here… ⇧⌘G · **Create Worktree Here…** (S).
- **Merge into current…** · **Rebase current onto here…** · Interactive Rebase ▸ (from here…, Reword, Edit, Squash into Parent, Fixup into Parent, Drop, Move Up / Down, Amend Staged into This, Split…).
- Reset current to here… · Cherry-pick… · Revert….
- Compare with Local Changes · Compare with… · Show in Separate Window.
- Save as Patch… (one commit, or a range when several are selected) · Copy as Patch (S).
- Bisect ▸ (Mark Good, Mark Bad, Skip).
- Open in Browser · **Show PR for this commit** (S).
- Custom commands ▸.
- Copy SHA (⌘C), Copy Short SHA, Copy Subject, Copy Info (⌥⌘C).

**Local branch**
- Checkout · Fast-forward to upstream · Pull into… · Push to…
- Merge into current… · Rebase current onto… · Rebase onto current… · Interactive rebase…
- New Branch from here · New Tag · **Create Worktree** · Create PR…
- Tracking ▸ (set upstream, unset) · Rename… · Delete…
- Pin · Filter · Hide · **Color ▸** (S) · Copy Name · Custom commands ▸

**Remote branch**
- Checkout as local (track) · Merge into current · Rebase current onto · Fast-forward local · Create Worktree · Create PR · Delete from remote… · Copy name · Open in Browser

**Remote**
- Fetch · Prune · Edit… · Rename… · Remove… · ☐ Auto-fetch · Copy URL · Open in Browser

**Tag**
- Checkout · Push to ▸ · Delete (local / remote) · Show Details · Create Release (S, GitHub and GitLab) · Copy

**Stash**
- Apply · Pop · Drop… · Rename · **Create Branch from Stash** (S) · Compare with Local · Save as Patch · Copy

**Submodule**
- Open in New Tab · Update · Update Recursive · Sync URL · Discard Changes… · Remove… · Copy Path

**Worktree**
- Open in Tab · Open in New Window · Show in Finder · Lock / Unlock · **Rename/Move** (S, #2498) · Remove… · Copy Path

**Changed file (Local Changes)**
- Stage / Unstage · Discard…
- Stash This File… (only this file's changes; fixes #1783, #2500)
- Open · Open With ▸ · Open in Editor · Reveal in Finder · Show in File Tree
- History · Blame · External Diff ⌘D
- Ignore ▸ (this file, `*.ext`, folder, custom pattern…, **ignore locally in `.git/info/exclude`** (S, #688)) · Assume Unchanged / Skip Worktree (S)
- LFS ▸ (Track pattern, Lock, Unlock)
- Resolve ▸ (Yours, Theirs, Merge…)
- Save as Patch… · Copy Path ⌘C / Relative Path
- Custom commands ▸

**File in commit / File Tree**
- Open (this revision) · Save As… · Open Current Version · History · Blame
- Reset File to This Revision · Reset File to Before This Commit
- Revert Changes to This File in This Commit (S) · Copy Path

### 5.16 Activity Manager, notifications, status

**Activity Manager** (Fork parity, extended)
- A popover from the toolbar status control. It can be detached into a window (⌥⌘A).
- **Left:** a list of operations for the repo or the group, each with a title ("Pull origin/main"), status icon, start time and duration.
  - Filters: All, Running, Failed, Background (auto-fetch, kept separate as in Fork 2.48), Group runs.
- **Right:** the exact commands, rendered as a terminal log with ANSI stripped and errors highlighted, plus **Copy**, **Copy as shell script** (S) and **Reveal in Console log** (P2).
- Running items have Cancel.
- History is kept for the last 500 items per repo, in memory and in a ring file.

**Status bar** (optional, P1): a thin bar at the bottom showing the current operation, group run progress, and ahead/behind of the current branch.

**System notifications** (UserNotifications)
- Group run summaries.
- A long operation that finishes while Spoon is in the background (more than 10 s).
- New commits on a watched branch after an auto-fetch (P2).
- PR review requested, and checks failed (P2, with an account).

**Menu-bar extra** (P2)
- Group status at a glance: groups with behind counts.
- Run "Pull group" from the menu bar.
- Account notifications.

### 5.17 Blame & File History windows

**Blame** (non-modal window)
- **Header:** the file path, plus a revision popup with ◀ ▶ buttons to step to the previous or next revision of the file.
- **Timeline strip:** each commit that touched the file is shown as a tick, sized by the number of changes. Dragging the strip scrubs through revisions.
- **Gutter:** grouped by commit chunk, showing avatar, short SHA, date (an **age heat** tint, from older to newer) and subject. Hovering shows the full commit popover.
- **Click a chunk** to select the commit in the main window. **"Blame previous revision"** for that line jumps past the commit that last changed it.
- **Options:** ignore whitespace (`-w`), detect moves and copies (`-M -C`), honor `blame.ignoreRevsFile`, and **Go to line** (⌘L).

**File History** (window or sheet)
- **Left list:** each revision with avatar, author, date, SHA, subject and path (renames are followed with `--follow`).
- **Right:** the diff for the selected revision, with a toggle between "changes in this commit" and "compare to working copy".
- **Compare two revisions** by selecting two entries.
- **Actions:** Reset File to…, Save Revision As…, Blame at this revision.
- **Line-range history** (S): starts from a diff or blame selection and uses `log -L`.
- **Folder history:** history scoped to a directory.

### 5.18 Empty, loading & error states

- **No repo open:** the status control reads "Welcome to Spoon — Open or clone a repository", and the main area shows Home.
- **Empty repo (no commits):** "No commits yet. Stage files and create your first commit."
- **Clean working copy:** "Nothing to commit — working tree clean", with buttons for **Pull** if behind and **Push** if ahead.
- **Loading history:** the first rows appear within 150 ms, and a thin progress line shows the rest streaming in. There are never blank screens with spinners for more than 300 ms.
- **Repo locked** (`index.lock`): a banner reads "Another git process is running in this repository", with **Wait**, and **Remove lock…** when no git process is found.
- **Missing git or broken config:** a full-pane error that names the cause and offers **Switch to bundled git**.

### 5.19 Accessibility & localization

- **VoiceOver.**
  - Every control has a label.
  - Commit rows read as "Commit by Kim, 2 hours ago: Fix rounding. Branches main, origin main. Not pushed."
  - Graph lanes have an accessibility description: "on main, merge of 2 parents".
  - Diff lines are announced as "added line 42: …".
- **Keyboard.**
  - The **full keyboard access** path covers every workflow: sidebar, then list, then details, then diff, then the hunk actions.
  - The focus ring is visible.
- **Display settings.** Dynamic Type equivalent via UI zoom (§5.1). Increase Contrast swaps in stronger tokens, and Reduce Transparency removes vibrancy.
- **Localization.**
  - All strings go through String Catalogs.
  - English ships at 1.0, and contributors can add languages through the catalog.
  - Dates and numbers are locale-aware.
  - The layout is prepared for right-to-left.

---

## 6. Feature catalogue

This section lists every feature Fork 2.71 ships, plus Spoon's additions. Columns: **ID · Feature · P · Origin**. UI detail for each feature is in §5. Where the Origin column carries a `#NNN`, that number is the Fork tracker request the feature answers.

### 6.1 Repository management (REPO)

| ID | Feature | P | O |
|---|---|---|---|
| REPO-01 | Open a local repo through a folder picker, by dragging onto the Dock icon or window, or with the `spoon` CLI | P0 | F |
| REPO-02 | Clone: URL validation and Test Connection, pick from an account's repos, HTTPS/SSH switch, choose a location and a name | P0 | F |
| REPO-03 | Clone options: recurse submodules, shallow depth, partial clone (`blob:none`), single branch | P1 | S #1400 #1829 |
| REPO-04 | Init a repo: initial branch, .gitignore template, README | P0 | F |
| REPO-05 | Home lists every repository, with search, recent repos, and invalid/missing markers plus "Locate…" | P0 | F |
| REPO-06 | Scan source folders to find repos; can rescan on demand or on launch | P0 | F |
| REPO-07 | Repository Summary: README, size, commit count, first and last commit, remotes with web links | P1 | F |
| REPO-08 | Repository Statistics: commits per month per author, by weekday, by hour | P2 | F |
| REPO-09 | Multiple windows. Tabs can be dragged out of and into windows. Tabs and windows are restored on relaunch | P0 | F |
| REPO-10 | Repo tab: rename, color, badges for uncommitted changes, behind count and running operation | P1 | F |
| REPO-11 | URL schemes: `spoon://open?path=`, `spoon://clone?url=`, and the `x-github-client://` / `sourcetree://` clone handlers, offered as opt-in default handlers | P1 | F |
| REPO-12 | Repository Settings sheet: identity override, signing, bug-tracker rules, custom commands, tab width, protected branches, branch color rules, hooks env | P1 | F~ |
| REPO-13 | Repository maintenance: `gc`, `maintenance run`, write the commit-graph, prune, verify (`fsck`) | P2 | S |
| REPO-14 | Bare repos: read-only browse of history and refs | P2 | S #247 |
| REPO-15 | Sparse checkout: view and edit cone patterns | P2 | S |
| REPO-16 | Performance benchmark: timings for log, status, diff and refs, plus "Copy report" | P2 | F |

### 6.2 Groups & multi-repo (GRP / SYNC)

The full spec is in §3. This table is a summary.

| ID | Feature | P | O |
|---|---|---|---|
| GRP-01…14 | Group CRUD, nesting, ordering, many-to-many, "from folder", smart groups, open all, scoped windows, group identity, manifest, org mirror, Quick Launch, per-member overrides | P0–P2 | S |
| SYNC-01 | Group **Fetch**: sequential, with a result for each repo | P0 | S #2520 |
| SYNC-02 | Group **Pull**: ff-only by default, with the safety preflight (§3.4) | P0 | S #2520 |
| SYNC-03 | Rebase and merge strategies with automatic abort on conflict | P1 | S |
| SYNC-04 | Group Dashboard: status table, filters, results, retry failed | P0 | S #379 |
| SYNC-05 | Undo a group sync | P1 | S |
| SYNC-06 | Scheduled group fetch (and opt-in scheduled ff-only pull), triggered on wake and when the network returns | P1 | S |
| SYNC-07 | Group Push: repos that are ahead only, after a confirmation list | P2 | S |
| SYNC-08 | Run a custom command across a group, with output grouped by repo | P1 | S |
| SYNC-09 | `spoon group …` CLI, headless | P1 | S |
| SYNC-10 | Fast-forward non-checked-out local branches during a sync | P1 | S |
| SYNC-11 | Group PR inbox: open PRs and review requests across every repo in a group | P2 | S |
| SYNC-12 | Cross-repo branch operation: create or check out the same branch name in the selected repos | P2 | S |

### 6.3 History & graph (HIST)

| ID | Feature | P | O |
|---|---|---|---|
| HIST-01 | Commit list with a graph, streamed, with no hard commit cap | P0 | F |
| HIST-02 | Topological or date order | P0 | F |
| HIST-03 | Ref label pills for local and remote branches, tags and stashes, with icons; HEAD shown bold | P0 | F |
| HIST-04 | Unpushed and unpulled markers; ahead/behind counts | P0 | F |
| HIST-05 | Collapse and expand merges; first-parent mode | P1 | F |
| HIST-06 | Filter: current branch, chosen refs, hide tags/stashes/remotes | P0 | F |
| HIST-07 | Hide merge commits | P1 | S #406 |
| HIST-08 | Reflog / lost commits view | P1 | F |
| HIST-09 | Uncommitted changes shown as a row | P1 | S #308 |
| HIST-10 | Avatars from GitHub and Gravatar, with an initials fallback; can be turned off | P0 | F |
| HIST-11 | `.mailmap` respected | P1 | F |
| HIST-12 | Custom branch colors, by ref or by pattern | P1 | S #2358 |
| HIST-13 | Compact branch labels (merge local and remote pills) | P1 | F |
| HIST-14 | Signature badges | P1 | S #18 #679 |
| HIST-15 | Space for commit quick look; a hover tooltip on merge commits | P1 | F |
| HIST-16 | Drag a commit onto a branch label to cherry-pick, or onto a commit to squash or reorder | P1 | F |
| HIST-17 | Configurable date format | P1 | S #717 |
| HIST-18 | Graph column that scrolls horizontally | P2 | S #516 |

### 6.4 Search (SRCH)

| ID | Feature | P | O |
|---|---|---|---|
| SRCH-01 | ⌘F in-list find (SHA, author, message), with next/prev and highlighted matches | P0 | F |
| SRCH-02 | Search mode: message, author, diff content (pickaxe), file path | P0 | F |
| SRCH-03 | Query language: fields, boolean operators, negation, date ranges | P1 | S |
| SRCH-04 | Recent queries; delete results so the list works as a to-do list | P1 | F |
| SRCH-05 | Filter within the file list, the File Tree and Changes | P0 | S #428 #1555 |
| SRCH-06 | Search inside a diff, kept when switching files | P0 | F |

### 6.5 Commit details & comparison (DET)

| ID | Feature | P | O |
|---|---|---|---|
| DET-01 | Commit tab: author, committer, refs, SHA, parents, message, file list with stats | P0 | F |
| DET-02 | Changes tab: file tree/list plus a diff; combined-list mode | P0 | F |
| DET-03 | File Tree tab: browse the repo at a commit, view a file, save it, reset to it | P1 | F |
| DET-04 | Expand All: a continuous multi-file diff | P1 | S #261 |
| DET-05 | Diff of a merge commit against parent 1, parent 2, or combined | P1 | S |
| DET-06 | Compare two commits, a commit with the working copy, two branches (3-tab), a stash with the working copy | P0 | F~ |
| DET-07 | Range-diff | P2 | S |
| DET-08 | Show "contained in" branches and tags | P1 | S |
| DET-09 | Open a comparison in a separate window | P1 | F |
| DET-10 | Hyperlinks for SHAs and issue/PR references in messages | P0 | F |
| DET-11 | Vertical layout (list and details side by side) | P1 | S #756 |

### 6.6 Local changes & staging (STG)

| ID | Feature | P | O |
|---|---|---|---|
| STG-01 | Unstaged and Staged lists; tree or list layout; untracked and ignored toggles | P0 | F |
| STG-02 | Stage or unstage a file: double-click, Return, ⌘S or drag; Stage All / Unstage All | P0 | F |
| STG-03 | Hunk stage, unstage and discard using the floating buttons | P0 | F |
| STG-04 | Line-level stage, unstage and discard | P0 | F |
| STG-05 | Partial staging of untracked files | P1 | F |
| STG-06 | Split hunk; edit hunk patch | P2 | S |
| STG-07 | Discard can be undone (backup blobs) | P0 | S #981 |
| STG-08 | Add to .gitignore (file, folder, extension, pattern) with a preview; .gitignore template picker | P1 | F |
| STG-09 | Ignore locally (`.git/info/exclude`); assume-unchanged / skip-worktree | P1 | S #688 |
| STG-10 | Large untracked files aren't diffed by default | P0 | F |
| STG-11 | Untracked folders collapsed into one row | P1 | S |
| STG-12 | Clean untracked/ignored files with a preview, moved to the Trash by default | P1 | S |

### 6.7 Committing (CMT)

| ID | Feature | P | O |
|---|---|---|---|
| CMT-01 | Subject and description fields, a counter, soft and hard limits | P0 | F |
| CMT-02 | Page guide; wrap paragraph at the ruler; monospace option; spell check | P1 | F |
| CMT-03 | Recent messages; drafts kept per repo and through rebases | P0 | F |
| CMT-04 | Commit templates (`commit.template` plus per-repo); the `prepare-commit-msg` hook can pre-fill | P1 | F |
| CMT-05 | Amend, with a pushed-commit warning | P0 | F |
| CMT-06 | Commit and Push; push automatically on commit (pref) | P0 | F |
| CMT-07 | Sign-off | P1 | F |
| CMT-08 | GPG signing, with a per-repo or global key | P1 | F~ #271 |
| CMT-09 | SSH signing (incl. 1Password), allowed-signers verification | P1 | S #1512 |
| CMT-10 | Co-authors token field with autocomplete | P1 | S #890 |
| CMT-11 | Trailers menu; Conventional Commits type picker (per repo) | P2 | S #714 |
| CMT-12 | Hook output streamed live; skip hooks on failure; "Skip hooks" checkbox (`--no-verify`) | P0 | F~ #1239 |
| CMT-13 | Warnings for detached HEAD, protected branches and large non-LFS files | P1 | F~ |
| CMT-14 | Fixup into… (create a `fixup!` commit, optional autosquash) | P1 | S #275 |
| CMT-15 | Emoji shortcode preview | P2 | S #296 |
| CMT-16 | Save working changes as a patch; copy as patch | P1 | F |

### 6.8 Diff viewer (DIFF)

| ID | Feature | P | O |
|---|---|---|---|
| DIFF-01 | Unified diff with intra-line highlighting | P0 | F |
| DIFF-02 | Side-by-side diff, everywhere (commits and local changes) | P0 | F |
| DIFF-03 | Syntax highlighting with tree-sitter (top 40 languages bundled) | P1 | F |
| DIFF-04 | Ignore whitespace; show invisibles; wrap (incl. side by side) | P0 | F~ #1338 |
| DIFF-05 | Context lines dropdown; entire file; expand context between hunks | P0 | F~ |
| DIFF-06 | Previous/next change; ⌘↑/⌘↓; minimap scrollbar | P1 | F |
| DIFF-07 | Word-diff mode | P2 | S #100 |
| DIFF-08 | Moved-line detection | P2 | S #1443 |
| DIFF-09 | Rename and mode-change display | P0 | F |
| DIFF-10 | Binary, large-file and minified-line handling | P0 | F |
| DIFF-11 | Image diff: side-by-side, swipe, onion skin, pixel difference; HEIC, WebP, SVG, PDF, TGA | P1 | F |
| DIFF-12 | Submodule diff with commits plus Update/Open | P1 | F |
| DIFF-13 | LFS pointer download and preview | P1 | F |
| DIFF-14 | Markdown rendered diff | P2 | S #159 |
| DIFF-15 | Space for a full-window side-by-side overlay | P1 | F |
| DIFF-16 | +/− markers and a color-blind palette | P1 | F |
| DIFF-17 | Tab width, global and per repo | P1 | F |
| DIFF-18 | External diff tool (⌘D), with presets and a custom tool | P1 | F |
| DIFF-19 | Open in editor at line; reveal line in Xcode, BBEdit, Zed, VS Code and others | P1 | F |
| DIFF-20 | History of selected lines (`log -L`) | P1 | F |

### 6.9 Branches (BR)

| ID | Feature | P | O |
|---|---|---|---|
| BR-01 | Create a branch (start point, check out, local-changes handling, name sanitizing, folder autocomplete) | P0 | F |
| BR-02 | Checkout: quick picker (⌘B), double-click, remote branch → tracking branch with an offer to fast-forward | P0 | F |
| BR-03 | Checkout a commit (detached), with a clear banner | P0 | F |
| BR-04 | Rename, optionally on the remote too | P0 | F |
| BR-05 | Delete one or many, local or remote, optionally with the worktree; warns about unmerged commits | P0 | F |
| BR-06 | Set, change or unset the upstream | P0 | F |
| BR-07 | Fast-forward without checkout; fast-forward many at once | P1 | F |
| BR-08 | Pin, hide and filter refs; folders from `/`; sort options | P0 | F |
| BR-09 | Select stale or merged branches for bulk delete; "gone" upstream markers | P1 | F~ #1141 |
| BR-10 | Branches Review screen: merged, stale (older than N days), gone upstream, with bulk actions | P2 | S |
| BR-11 | Compare branches (⌘-click two) | P0 | F |
| BR-12 | Drag one branch onto another to merge or rebase | P1 | F |
| BR-13 | Copy branch name | P0 | F |
| BR-14 | Protected branch list (warn before commit or force-push) | P2 | S |
| BR-15 | Stacked branches: track the parent in git config (`branch.<name>.spoonParent`), restack the chain, push the stack, create stacked PRs (GitHub stacked PRs / `gh stack` compatible) | P2 | S #1747 #2683 |

### 6.10 Tags (TAG)

| ID | Feature | P | O |
|---|---|---|---|
| TAG-01 | Create a tag (annotated by default, lightweight optional), with message, sign and push | P0 | F~ |
| TAG-02 | Push one, several or all tags | P0 | F |
| TAG-03 | Delete locally and/or on remotes | P0 | F |
| TAG-04 | Tag details (annotation, tagger, signature) | P1 | F |
| TAG-05 | Check out or merge a tag | P1 | F |
| TAG-06 | Semver sort; suggest the next version | P2 | S |
| TAG-07 | Create a GitHub/GitLab release from a tag | P2 | S |

### 6.11 Remotes & network (REM / NET)

| ID | Feature | P | O |
|---|---|---|---|
| REM-01 | Add, edit, rename and remove remotes; separate push URL; HTTPS/SSH switch; account binding; Test Connection | P0 | F~ |
| REM-02 | Remote service icons (GitHub, GitLab, Bitbucket, Azure, Gitea, Forgejo) | P0 | F |
| REM-03 | Per-remote auto-fetch toggle | P1 | F |
| NET-01 | Fetch: one remote or all, prune, tags, submodules; ⌥ for a quick fetch | P0 | F |
| NET-02 | Pull: ff-only, merge or rebase strategy, local-changes handling, conflict prediction; quick pull | P0 | F~ |
| NET-03 | Push: multiple branches, editable target, set upstream, tags, force-with-lease with a preview of what will be overwritten; quick push | P0 | F~ |
| NET-04 | Push to a custom refspec / Gerrit `refs/for/` via custom command presets | P1 | F |
| NET-05 | Warn about unpushed submodule commits before push | P1 | F |
| NET-06 | Auto-fetch on a configurable interval (default 10 min), on open, and on wake | P0 | F~ #1269 #1205 |
| NET-07 | Cancel any network operation; operations never block the UI | P0 | F |
| NET-08 | Skip pre-push hook option | P1 | S #1239 |
| NET-09 | Proxy: honor `http.proxy` and system proxy settings, with a UI to set `http.proxy` | P2 | S #1533 |

### 6.12 Merge, rebase, cherry-pick, revert, reset (MRG / RB / CP / RST)

| ID | Feature | P | O |
|---|---|---|---|
| MRG-01 | Merge with a type (default / no-ff / ff-only / squash / no-commit) and an editable message | P0 | F |
| MRG-02 | Conflict prediction in the Merge, Rebase, Cherry-pick, Revert and Pull dialogs (`merge-tree`) | P0 | F |
| MRG-03 | In-progress notification bar with Continue / Abort (merge, rebase, cherry-pick, revert) | P0 | F |
| RB-01 | Rebase onto a branch or commit; autostash; `--update-refs` | P0 | F |
| RB-02 | Interactive rebase dialog (pick, reword, edit, squash, fixup, drop, reorder, multi-select, keyboard) | P0 | F |
| RB-03 | Quick actions: reword, edit, squash/fixup into parent, drop, move up/down, without the dialog | P0 | F |
| RB-04 | Backup branch before rewriting | P0 | F |
| RB-05 | Amend staged changes into any older commit | P1 | S |
| RB-06 | Rebase merges (`--rebase-merges`) | P2 | S #616 |
| RB-07 | Exec lines; split commit | P2 | S |
| RB-08 | Rebase onto root | P1 | F |
| CP-01 | Cherry-pick one or many commits, with `-x`, a no-commit option, and a mainline parent for merges | P0 | F |
| CP-02 | Revert commits (with a parent for merges, no-commit option) | P0 | F |
| CP-03 | Revert selected hunks or lines of a past commit | P1 | S #333 #1280 |
| RST-01 | Reset the current branch to a commit: soft, mixed, hard or keep | P0 | F~ |
| RST-02 | Reset a file to its state at a commit, or before it | P1 | F |

### 6.13 Merge conflicts (CONF)

| ID | Feature | P | O |
|---|---|---|---|
| CONF-01 | Conflict panel: take ours/theirs, merge in Spoon, external tool; real branch names | P0 | F |
| CONF-02 | Built-in merge editor: two panes plus an editable result, chunk picking, conflict navigation, scrollbar marks | P0 | F |
| CONF-03 | Optional Base pane (3-way view); layout toggle | P1 | F~ |
| CONF-04 | Undo/redo in the merge editor | P0 | S #2320 |
| CONF-05 | Auto-resolve trivial chunks (listed for review) | P1 | S |
| CONF-06 | Binary, image, LFS and submodule conflicts; delete/modify conflicts | P1 | F |
| CONF-07 | Revert a file to its conflicted state | P1 | F (Win) |
| CONF-08 | External merge tools: FileMerge, Kaleidoscope, Beyond Compare, P4Merge, KDiff3, DiffMerge, Araxis, VS Code, UnityYAMLMerge, custom (args with variables) | P1 | F |
| CONF-09 | Respect `rerere`; show "resolved by rerere" | P2 | S |

### 6.14 Stash & snapshots (STASH)

| ID | Feature | P | O |
|---|---|---|---|
| STASH-01 | Save a stash with a message; include untracked; keep index | P0 | F~ |
| STASH-02 | Quick stash (⌥⇧⌘H) | P0 | F |
| STASH-03 | Apply / pop (kept if there is a conflict); restore index | P0 | F |
| STASH-04 | Drop one or many; rename | P0 | F |
| STASH-05 | Stash in the commit list (toggle); stash details with diff, including untracked files | P0 | F~ #898 |
| STASH-06 | Partial stash: selected files only (correct staged-change handling) | P1 | F~ #1783 |
| STASH-07 | Stash selected hunks or lines; stash staged only (`--staged`) | P1 | S #281 |
| STASH-08 | Snapshot: save the state without touching the working copy | P1 | F |
| STASH-09 | Create a branch from a stash; compare a stash with local; save as patch | P1 | F~ |

### 6.15 Submodules, worktrees, LFS, flows (SUB / WT / LFS / FLOW)

| ID | Feature | P | O |
|---|---|---|---|
| SUB-01 | Sidebar tree of submodules with dirty indicators; open in a tab next to the parent; parent link | P0 | F |
| SUB-02 | Add (recursive), update (one, many, recursive), sync URL, remove, discard changes | P1 | F |
| SUB-03 | Auto-update on checkout, cherry-pick and revert (pref) | P1 | F |
| SUB-04 | Commit the parent and its submodules together (one message) | P2 | S #1651 |
| WT-01 | List worktrees (nested); indicate branches that are checked out elsewhere | P0 | F |
| WT-02 | Create a worktree (from a branch, remote branch or commit); check out as worktree | P1 | F |
| WT-03 | Remove (in the background), lock/unlock, move/rename | P1 | F~ #2498 |
| WT-04 | Worktrees open in tabs titled `repo · worktree`; settings shared across worktrees | P1 | F |
| LFS-01 | Bundled git-lfs; init; track patterns with a preview | P1 | F |
| LFS-02 | Fetch, pull and prune; progress | P1 | F |
| LFS-03 | Locks: lock/unlock from the file menu; a locks dialog with filter and multi-unlock | P2 | F |
| LFS-04 | Status dialog; warn about large untracked-by-LFS files | P1 | F |
| FLOW-01 | git-flow: init (prefixes); start/finish feature, release and hotfix with options | P1 | F |
| FLOW-02 | Lean branching: start/finish branch into main, with sync | P2 | F |
| FLOW-03 | Custom workflows: user-defined start/finish steps as composite custom commands | P2 | S |

### 6.16 Bisect, patches, archive, misc (BIS / PATCH / MISC)

| ID | Feature | P | O |
|---|---|---|---|
| BIS-01 | Bisect: start, good/bad/skip from the bar or context menu, colored marks, progress, reset | P1 | F |
| BIS-02 | `bisect run` with a script | P2 | S |
| PATCH-01 | Save a commit or range as a patch; copy as patch; save a stash as a patch | P1 | F |
| PATCH-02 | Apply a patch (file, drag and drop, clipboard ⌘V), with an `am` or apply-only option | P1 | F |
| MISC-01 | `git archive` export | P2 | S |
| MISC-02 | git notes: view and add | P2 | S #780 |
| MISC-03 | Subtree: add, pull and push via custom presets | P2 | S #572 |
| MISC-04 | Remove a stale `index.lock` with a check | P0 | F |

### 6.17 Undo & safety (UNDO)

| ID | Feature | P | O |
|---|---|---|---|
| UNDO-01 | ⌘Z / ⇧⌘Z for ref-changing operations (commit, amend, reset, rebase, merge, cherry-pick, revert, branch and tag ops, group pull) | P1 | S #981 |
| UNDO-02 | Undo discard, hard reset and stash drop (snapshots) | P1 | S |
| UNDO-03 | Operation History panel: browse and restore any earlier state | P1 | S |
| UNDO-04 | Confirmations state clearly when an action **cannot** be undone (push, remote delete) | P0 | S |

### 6.18 Custom commands (CMD)

| ID | Feature | P | O |
|---|---|---|---|
| CMD-01 | Targets: Repository, Commit, Branch (local/remote), Tag, File, Submodule, Stash, **Group** (S) | P1 | F~ |
| CMD-02 | Action types: Shell (zsh/bash), Start Process, Open URL | P1 | F |
| CMD-03 | Optional UI: title, description, up to two buttons; text field, path picker, ref pickers (with filter), checkbox, **dropdown** (S) | P1 | F~ |
| CMD-04 | Variables: `${repo:name}` `${repo:path}` `${ref}` `${ref:short}` `${ref:full}` `${sha}` `${sha:abbr}` `${file}` `${file:name}` `${submodule}` `${git}` `${group}` (S) `${files}` (S, multi-select) | P1 | F~ #702 |
| CMD-05 | Scope: Global, Local (`.git/spoon/`), Shared (`.spoon/commands.json` in the repo, requires trust) | P1 | F |
| CMD-06 | Show output / run in background / refresh after | P1 | F |
| CMD-07 | Assign shortcuts; add to the toolbar | P1 | S #438 #439 |
| CMD-08 | Nesting with `/`; reorder; OS filter | P1 | F |
| CMD-09 | Import Fork's `custom-commands.json` | P2 | S |

### 6.19 Quick Launch (QL)

| ID | Feature | P | O |
|---|---|---|---|
| QL-01 | ⌘P palette: fuzzy search over every command, repo, group, branch, file and custom command | P0 | F |
| QL-02 | Parameterized commands (token chips) | P0 | F |
| QL-03 | Prefix modes (`>`, `@`, `#`, `/`, `:`) | P1 | S |
| QL-04 | Shortcut hints; frequency/recency ranking | P1 | S |

### 6.20 Integrations & accounts (ACC / PR / BT / EXT)

| ID | Feature | P | O |
|---|---|---|---|
| ACC-01 | Accounts: GitHub.com (OAuth device flow or PAT), GitHub Enterprise, GitLab.com and self-hosted, Bitbucket Cloud and Data Center, Gitea, **Forgejo / Codeberg** (S #2124), Azure DevOps (S, full account) | P1 | F~ |
| ACC-02 | Multiple accounts per service; update token; tokens stored in the Keychain | P1 | F |
| ACC-03 | Account repo list in Clone | P1 | F |
| ACC-04 | Add an SSH public key to an account | P2 | S |
| PR-01 | Create a PR/MR: prefilled title, body from template and commits, base branch, draft, reviewers, labels; or open in the browser | P1 | F~ |
| PR-02 | PR list in the sidebar (mine, review requested, all open) with CI status | P1 | S #507 #1156 |
| PR-03 | Check out a PR locally (including from forks) | P1 | S |
| PR-04 | CI / checks status on commits and branches | P2 | S #1267 #241 |
| PR-05 | Notifications (menu bar): review requests, mentions, failing checks | P2 | F~ |
| PR-06 | Open a commit, branch or file in the browser | P0 | F |
| BT-01 | Bug-tracker link rules (regex → URL) with a tester; presets for GitHub, GitLab, Jira, Linear; local, shared or **global** scope | P1 | F~ #828 |
| EXT-01 | Open in Terminal (Terminal, iTerm2, Warp, Ghostty, Kitty, WezTerm, Alacritty, Hyper, custom) | P0 | F~ #1704 |
| EXT-02 | Open in editor (VS Code (+ Insiders), Cursor, Zed, Xcode (project/workspace/package), Nova, Sublime, BBEdit, JetBrains IDEs, Android Studio, Unity, custom) | P0 | F~ #1317 #1463 |
| EXT-03 | Show in Finder; drag files out to other apps | P0 | F |
| EXT-04 | `spoon` CLI (open, status, log, diff, group …) | P1 | F~ #2267 |
| EXT-05 | macOS Services, a Share menu, and a Finder Sync extension with badges (P2, opt-in) | P2 | S |
| EXT-06 | Integrated terminal panel | P2 | S #2618 |

### 6.21 AI assistance (AI), opt-in and off by default

| ID | Feature | P | O |
|---|---|---|---|
| AI-01 | Generate a commit message from staged changes. It streams into the fields and stays editable | P1 | F~ |
| AI-02 | Providers: **local CLI agents** (Claude Code, Codex, Cursor, Gemini), **OpenAI-compatible endpoint** (Ollama, LM Studio, vLLM), **Anthropic API** (default model `claude-sonnet-5-5`). Keys are stored in the Keychain. | P1 | F~ #2519 #2430 |
| AI-03 | Editable prompts with variables (`${diff}`, `${files}`, `${branch}`, `${recentSubjects}`, `${lowLimit}`, `${highLimit}`, `${guideLine}`) | P1 | F |
| AI-04 | Code review of a branch or commit range, rendered as Markdown with jump-to-file links | P2 | F |
| AI-05 | PR title and description draft; branch-name suggestion | P2 | S |
| AI-06 | Explain a conflict / suggest a resolution (applied only after explicit acceptance) | P2 | S |
| AI-07 | Privacy: each repo needs consent before any diff leaves the machine; a "local only" mode; the exact payload can be previewed | P1 | S |

### 6.22 Settings, appearance & app (APP)

| ID | Feature | P | O |
|---|---|---|---|
| APP-01 | Light / Dark / System appearance | P0 | F |
| APP-02 | UI zoom, density, separate font sizes | P1 | S #1178 #1955 |
| APP-03 | Horizontal or vertical layout; collapsible details; hide sidebars | P1 | S #756 #934 |
| APP-04 | Customizable toolbar | P0 | F |
| APP-05 | Fully remappable shortcuts (a keymap editor plus `keybindings.json`); presets "Spoon", "Fork-like" and "Sublime Merge-like" | P1 | S #62 |
| APP-06 | Git instance: bundled / system / Homebrew / custom path | P0 | F |
| APP-07 | Environment: resolved login-shell PATH, overrides, a hook test | P0 | S #1227 |
| APP-08 | Global identity: name, email and avatar (written to `~/.gitconfig` after confirmation) | P0 | F |
| APP-09 | SSH key manager | P1 | F |
| APP-10 | Sparkle updates: Stable / Beta channels, interval | P0 | F |
| APP-11 | Settings stored as human-readable JSON; import/export | P1 | S |
| APP-12 | Themes (diff and graph palettes) as JSON, shareable | P2 | S |
| APP-13 | Import from Fork: repository list, custom commands, bug-tracker rules (read Fork's prefs files when present) | P2 | S |

---

## 7. Top improvements over Fork

These items make Spoon "a better Fork". Each one maps to a demand that has been documented.

1. **Group Sync and the Dashboard** (§3). This is the feature Fork's maintainer declined (#2520).
2. **Open source and free.** It addresses Fork's closed-source complaint and the long run of HN requests for open source. The core stays portable to Linux, which is Fork's #1 request (#153).
3. **Undo everything that is local**: ⌘Z plus an operation history (#981, #2175). This is Tower's main pitch against Fork.
4. **Hooks just work.** Spoon resolves the login-shell environment (#1227, #1889, #311).
5. **Modern identity and signing**: SSH signing, verification badges, per-group identity, co-authors (#1512, #18, #1903, #890).
6. **Layout and comfort**: vertical layout, UI zoom, density, remappable shortcuts, custom branch colors, and an uncommitted row in the graph (#756, #1178, #62, #2358, #308).
7. **Diff upgrades**: continuous multi-file diff, word diff, moved lines, Markdown preview, and wrap in side-by-side (#261, #100, #1443, #159, #1338).
8. **Finer-grained operations**: revert hunks of an old commit, stash hunks or staged changes only, amend into any commit, fixup-into, and rebase-merges (#333, #281, #275, #616).
9. **PRs inside the app**: list, check out, create, and CI status (#507, #1156).
10. **Transparency**: "Show command" in every dialog, copying an activity as a shell script, and no telemetry.
11. **Bring your own AI**: local models and OpenAI-compatible endpoints, alongside CLI agents (#2519, #2430).

---

## 8. Preferences

Settings is a native window with a toolbar of panes. Every setting is also a key in `settings.json`. Per-repository overrides live in Repository Settings (REPO-12).

| Pane | Settings |
|---|---|
| **General** | Open at launch: restore windows / Home · Default source folders (list) and scan depth · Rescan on launch · ⌘-number selects tabs · Show `●` for dirty tabs · Confirm before closing a window with running operations · Default editor · Default terminal · URL scheme handlers (GitHub Desktop / Sourcetree links) |
| **Appearance** | Theme: System / Light / Dark · UI zoom · Density · Commit-list font size · Diff font (family, size) · Commit-message font · Graph palette · Compact branch labels · Avatars: off / GitHub / Gravatar · Date format · Layout: horizontal / vertical · Show status bar |
| **Git** | Git instance: bundled (version shown) / system / Homebrew / custom path · Environment: resolved PATH, prepend/append, "Re-resolve", "Test hooks environment" · Global identity (name, email) · Sort commits: topological / date · Update submodules automatically · Fetch tags always · Default pull strategy (respects `pull.rebase`) · Push automatically after commit · Background status: use `--no-optional-locks` (locked on) · Large-file thresholds (diff cap, LFS warning size) · Offer `commit-graph` / `fsmonitor` for large repos |
| **Fetch & Sync** | Auto-fetch: on / off, interval (5, 10, 15, 30, 60 min), on open, on wake · Skip on Low Power / expensive network / battery · Group defaults: strategy, scope, local-changes policy, concurrency, delay, stall timeout, on-failure behavior · Notifications: always / on change or failure / never · Undo retention (days, entries) |
| **Accounts** | List of accounts: add, remove, update token, test · Per-account: notifications, default clone protocol |
| **SSH & Signing** | SSH keys: list, generate ED25519, copy public key, add to account · Signing: off / GPG / SSH, key, program (auto-detects pinentry-mac, `op-ssh-sign`) · Sign commits by default · Sign tags by default · Allowed signers file · Show signature badges |
| **Commit** | Subject soft and hard limits · Page guide column · Wrap at ruler · Spell check · Monospace message font · Sign-off by default · Remember drafts · Conventional Commits helper (global default) · Emoji shortcode preview · Trailers list |
| **Diff & Merge** | Default view: unified / side-by-side · Context lines · Ignore whitespace by default · Show invisibles · Wrap · Tab width · Syntax highlighting on/off · Word diff by default · Moved-line detection · +/− markers · Color-blind palette · Expand All by default · External diff tool · External merge tool (presets plus custom args) |
| **Integrations** | Bug-tracker rules (global) · Editors and terminals (detected, plus custom) · Install `spoon` CLI · Finder extension (P2) · Menu-bar extra (P2) |
| **AI** | Off by default · Provider: CLI agent (path auto-detected) / OpenAI-compatible (base URL, model, key) / Anthropic API (model, key) · Prompts (commit, review, PR) with variables · Ask before sending diffs: per repo / always · Max diff size sent |
| **Custom Commands** | Global list editor (§6.18) · Import from Fork |
| **Keyboard** | Searchable keymap · Presets: Spoon, Fork-like, Sublime Merge-like · Conflict detection · Reset |
| **Updates** | Check automatically · Download automatically · Channel: Stable / Beta · Check now |
| **Advanced** | Verbose git logging · Activity history size · Open the logs folder · Reset all settings · Export / import settings |

---

## 9. Keyboard shortcuts

The defaults are **Fork-compatible**, so Fork users' muscle memory carries over. Every shortcut can be remapped (APP-05). A context marked *(list)*, *(changes)* and so on means the binding applies only when that area has focus.

### App & window

| Shortcut | Action |
|---|---|
| ⌘, | Settings |
| ⌘N | New window |
| ⌘T | New tab (Home) |
| ⇧⌘T | Reopen closed tab |
| ⌘W | Close tab / window |
| ⌘O | Open repository… |
| ⇧⌘N | Clone… |
| ⌃⇧⌘N | Init new repository… |
| ⌘P (alias ⇧⌘O) | Quick Launch |
| ⌃Tab / ⌃⇧Tab, ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌃⌘S | Toggle window sidebar (Groups) |
| ⌥⌘S | Toggle repository sidebar |
| ⌥⌘T | Show / hide toolbar |
| ⌃⌘F | Full screen |
| ⌘= / ⌘− / ⌃⌘0 | Zoom in / out / actual size |
| ⇧⌘0 | Home |

### View

| Shortcut | Action |
|---|---|
| ⌘1 | Local Changes (press again to focus the subject) |
| ⌘2 | All Commits (press again to jump to HEAD) |
| ⌘3 | Reflog |
| ⌘0 | Reveal HEAD |
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | Details: Commit / Changes / File Tree |
| ⇧⌘D *(list)* | Hide / show commit details |
| ⌥⌘L | Toggle horizontal / vertical layout |
| ⇧⌘A | Show current branch only |
| ⇧⌘. | Show lost commits *(list)* / ignored files *(changes)* |
| ⌘R | Refresh |
| ⌥⌘A | Activity Manager window |
| Tab / ⇧Tab | Move focus: sidebar → list → details → diff |

### Repository

| Shortcut | Action |
|---|---|
| ⇧⌘F / ⌥⇧⌘F | Fetch… / quick fetch |
| ⇧⌘L / ⌥⇧⌘L | Pull… / quick pull |
| ⇧⌘P / ⌥⇧⌘P | Push… / quick push |
| ⇧⌘H / ⌥⇧⌘H | Stash… / quick stash |
| ⌘B | Checkout branch (picker) |
| ⇧⌘B | New branch… |
| ⇧⌘G | New tag… |
| ⇧⌘C | Commit (focus message) |
| ⇧⌘M | Merge… |
| ⇧⌘E | Rebase… |
| ⌘Z / ⇧⌘Z | Undo / redo last operation |
| ⌥⌘Z | Operation History |
| ⌃⌘O | Show in Finder |
| ⌃⌘T | Open in Terminal |
| ⌃⌘E | Open in Editor |
| ⌘V *(list / changes)* | Apply patch from clipboard |

### Groups

| Shortcut | Action |
|---|---|
| ⌃⇧⌘F | Fetch current group |
| ⌃⇧⌘L | Pull current group |
| ⌃⇧⌘D | Open group dashboard |
| ⌘. *(dashboard)* | Stop the group run |
| Space *(dashboard)* | Toggle include |

### Commit list

| Shortcut | Action |
|---|---|
| ⌘F | Find in list |
| Return / ⇧Return, ⌘G / ⇧⌘G | Next / previous match |
| ⌥⌘F | Search mode (query language) |
| ⌘C / ⌥⌘C | Copy SHA / copy commit info |
| Space | Commit quick look |
| ← / → | Collapse / expand merge |
| ⌫ | Delete selected branch / stash / search result |
| P · R · E · S · F · D *(list, with ⌥)* | Quick interactive-rebase action on the selected commit |

### Local Changes & diff

| Shortcut | Action |
|---|---|
| ⌘Return | Commit |
| ⌥⌘Return | Commit and push |
| Return or ⌘S | Stage / unstage selected files or lines |
| ⌥⇧⌘S | Stage all / unstage all |
| ⌫ or ⇧⌘D *(changes)* | Discard selected… |
| ⌘D | External diff |
| ⌥⇧⌘O | Open file in default editor |
| ⌘C *(file list)* | Copy path |
| ⌘↑ / ⌘↓ | Previous / next hunk |
| ⌘F | Find in diff |
| ⌃Q *(message)* | Wrap paragraph at ruler |
| Hold ⌥ | Reveal Stage All / Unstage All; Commit becomes Commit and Push |

### Interactive rebase dialog

| Shortcut | Action |
|---|---|
| P / R / E / S / F / D | Pick / Reword / Edit / Squash / Fixup / Drop |
| ⌘↑ / ⌘↓ | Move up / down |
| ⌘Return | Start rebase |

### Merge editor

| Shortcut | Action |
|---|---|
| ⌥⌘← / ⌥⌘→ | Take theirs / yours for the current conflict |
| ⌘↑ / ⌘↓ | Previous / next conflict |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘S | Save and stage |

### Blame / history windows

| Shortcut | Action |
|---|---|
| ⌘L | Go to line |
| ⌘[ / ⌘] | Previous / next revision |

---

## 10. Non-functional requirements

### 10.1 Performance budgets

These are measured on an M1 MacBook Air with 8 GB of RAM, and run as CI benchmarks on every PR (§10.5).

| Scenario | Budget |
|---|---|
| Cold launch to an interactive window (restoring 5 tabs) | ≤ 1.0 s |
| Opening a repo: first 100 commit rows visible (linux.git, ~1.3M commits) | ≤ 300 ms |
| Full history streamed and graph laid out (linux.git) | ≤ 8 s, in the background with the UI responsive |
| Scrolling the commit list | 120 fps on ProMotion, with no dropped frames during streaming |
| Selecting a commit: details and first diff shown (typical commit) | ≤ 100 ms |
| Status refresh after a file save (repo with 100k files, fsmonitor on) | ≤ 250 ms |
| Stage a hunk: UI updated | ≤ 150 ms |
| Diff of a 50k-line file: first screen | ≤ 200 ms; highlighting completes asynchronously |
| Quick Launch: open to results | ≤ 50 ms |
| Group Dashboard for 200 repos: local status shown | ≤ 2 s; rows appear progressively |
| Group fetch overhead per repo, excluding the network | ≤ 50 ms |
| Memory: 5 tabs open on typical repos | ≤ 400 MB |
| Memory: linux.git open | ≤ 1.2 GB |
| Idle CPU with 10 tabs open | ~0% (no polling loops; FSEvents and timers only) |

### 10.2 Reliability & data safety

- **No data loss.**
  - Destructive operations write a recoverable snapshot first (§4.9).
  - A crash during any operation leaves the repo in the state git itself would leave it.
  - Spoon never writes `.git` internals except through git commands. The one exception is its own `spoon/` folder and `refs/spoon/*`.
- **Concurrent edits.** Spoon tolerates other git processes running concurrently (terminal, IDE), using lock awareness and `--no-optional-locks` reads.
- **Crash-free sessions.** At least 99.9% from 1.0 onwards.
- **Library safety.** `library.json` is written atomically and has backups. A corrupt file is quarantined and restored from the last good copy.

### 10.3 Security & privacy

- Secrets are stored only in the Keychain. Command lines in logs have secrets redacted (URLs with credentials, `Authorization` headers).
- No telemetry. Every network destination is documented (§4.11).
- Repo-supplied configuration (shared commands, rules) requires an explicit trust prompt.
- The bundled git and git-lfs are updated within 7 days of any upstream security release, followed by a Spoon point release.
- Hardened Runtime is enabled. The app carries no unsigned code.

### 10.4 Compatibility

- macOS 15 or later, universal binary.
- git 2.39 or later for an external git. The bundled git is always the current stable release.
- Repository formats: SHA-1 and SHA-256 object formats, the reftable backend, sparse index, partial clones, and worktrees. Spoon must display these correctly, even where it doesn't add UI for managing them.
- Locale and filenames: full Unicode paths and NFC/NFD normalization (APFS). Non-UTF-8 commit encodings are converted via `i18n.logOutputEncoding`.

### 10.5 Quality & testing

| Layer | Approach |
|---|---|
| Parsers | Unit tests against **golden outputs** captured from real git, covering several git versions |
| Git operations | Integration tests that create throwaway repos in temp dirs and local bare "remotes", and run real git through SpoonKit. These include every Group Sync acceptance scenario (§3.8) |
| Staging engine | Property tests: random diffs × random line selections, stage then unstage, and assert the index round-trips |
| Graph layout | Snapshot tests of lane assignments on fixture repos (octopus merges, criss-cross merges, orphan branches) |
| UI | XCUITest smoke flows: clone, commit, push, interactive rebase, resolve a conflict, group pull |
| Performance | Benchmarks on fixture repos (linux.git mirror, a synthetic 100k-file repo) in CI. A regression above 10% fails the build |
| Accessibility | Automated accessibility audit (XCUITest `performAccessibilityAudit`) on the main screens |

---

## 11. Roadmap

Milestones are sized for a small team of 1–3 contributors. Each one is shippable.

| Milestone | Scope | Exit criteria |
|---|---|---|
| **M0: Foundations** | SPM workspace; GitRunner; parsers (refs, status v2, log, diff); FSEvents watcher; environment resolution; CI; signed and notarized empty app with Sparkle | `spoon status` (CLI) prints parsed status for any repo; signed build installs on a clean Mac |
| **M1: Read-only browser** | Window, tabs, toolbar shell; repo sidebar; commit list plus graph (streaming, lanes); commit details (3 tabs); diff viewer (unified and side by side, highlighting); Home with repo list; Quick Launch v1 | Browsing linux.git meets the §10.1 budgets |
| **M2: Daily driver** | Local Changes with file, hunk and line staging; commit (amend, sign-off, hooks, templates); branches (create, checkout, rename, delete, track); fetch, pull and push dialogs and quick variants; stash basics; remotes; askpass and credentials; Activity Manager; error sheets | The team uses Spoon for all of its own development |
| **M3: Groups (public beta 0.5)** | Groups and nesting; scan folder; Group Dashboard; Group Fetch and Pull (ff-only, preflight, results, retry); auto-fetch; notifications | §3.8 scenarios 1–8 pass; announced publicly; Homebrew tap |
| **M4: History rewriting & conflicts** | Merge, rebase, interactive rebase plus quick actions; cherry-pick, revert, reset; conflict prediction; merge editor; in-progress bars; tags; submodules; worktrees | Fork-equivalent rewrite workflows |
| **M5: 1.0 (parity + headline)** | Undo/OpLog; SSH/GPG signing and badges; co-authors; LFS; git-flow; custom commands; accounts and PR list, checkout and create; blame and file history windows; search query language; vertical layout; zoom; keymap editor; manifest import/export; group identity; scheduling; `spoon group` CLI; accessibility pass | Every P0 and P1 item is done; the §10 budgets are met; official Homebrew cask |
| **Post-1.0** | P2 items: org mirroring, group PR inbox, stacked branches, word and moved diff, Markdown diff, AI review, menu-bar extra, Finder extension, statistics, bare repos, integrated terminal, gix fast reader, themes, importers (meta, mr, gita, repo), Linux front end exploration, jj research | — |

---

## 12. Open decisions

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | License | **GPL-3.0** (prevents closed rebrands; can use GPL components such as STTextView or GitUpKit) vs **Apache-2.0** (widest contributor and embedding pool; patent grant) vs MPL-2.0 | GPL-3.0 for the app. Consider Apache-2.0 for SpoonKit if third-party reuse matters. Use DCO sign-offs, not a CLA. |
| D2 | Minimum macOS | 14 Sonoma (wider reach) vs **15 Sequoia** (newer SwiftUI and Observation APIs, fewer workarounds) | 15. Revisit if beta users ask for 14. |
| D3 | Diff text engine | Custom Core Text line view vs CodeEditTextView (MIT) vs STTextView (GPL or commercial) | Custom view for read-only and stageable diffs; CodeEditTextView for editable panes |
| D4 | When to add a native reader | Never / at M1 / when profiling shows a need | When profiling shows a need, as a gix C-ABI module limited to reads |
| D5 | Bundled git build | Build from source in CI (reproducible, signed) vs repackage an upstream build | Build from source in CI, including git-lfs; publish the sources alongside |
| D6 | Name and trademark | Check "Spoon" against existing developer tools and the App Store (e.g. spoon.net container tooling, Hammerspoon "Spoons") | Run a trademark and domain search before the public beta; keep the name if it is clear |
| D7 | Group membership model | Many-to-many (proposed) vs a strict tree like folders | Many-to-many, with smart groups; Home also shows a "by folder" view |
| D8 | Undo storage location | `<git-dir>/spoon/` (travels with the repo; visible to other tools) vs Application Support | `<git-dir>/spoon/`, plus `refs/spoon/*` so snapshots survive gc |
| D9 | AI in core vs plugin | Built in (opt-in) vs external custom commands only | Built in, off by default, with local-first providers |
| D10 | Funding | None, GitHub Sponsors, Open Collective, or paid signed builds | GitHub Sponsors plus Open Collective; builds stay free |

---

## 13. Appendix: research sources

Research was done on 2026-11-06.

- **Fork (reference product)**
  - Mac release notes, read in full: https://fork.dev/releasenotes (169 versions, GitClient 1.0.0 in Apr 2016 to Fork 2.71 on 23 Oct 2026)
  - Windows release notes: https://fork.dev/releasenoteswin
  - Site, pricing, license and blog: https://fork.dev, https://fork.dev/buy, https://fork.dev/blog
  - Official docs: https://github.com/fork-dev/Docs (keyboard-shortcuts-mac.md, faq.md)
  - Issue tracker: https://github.com/fork-dev/Tracker. Issues cited by number throughout. Vote counts were taken on 2026-11-06.
  - App bundle **Fork-2.66.7.dmg**, inspected offline and never executed. The menu structure, dialog strings and preference names were taken from its interface files.
- **Competitors**
  - Tower: https://www.git-tower.com/features and the release notes
  - GitKraken workspaces: https://help.gitkraken.com/gitkraken-desktop/workspaces/
  - GitKraken's move to the git executable: https://gitkraken.com/blog/gitkraken-client-migrating-from-libgit2-to-git-executable
  - Sublime Merge: https://www.sublimetext.com/blog/articles/sublime-merge
  - GitUp: https://github.com/git-up/GitUp
  - lazygit: https://github.com/jesseduffield/lazygit
  - GitButler: https://github.com/gitbutlerapp/gitbutler
  - SourceGit: https://github.com/sourcegit-scm/sourcegit
  - GitHub Desktop: https://github.com/desktop/desktop
- **Multi-repo tools**
  - gita: https://github.com/nosarthur/gita
  - myrepos: https://myrepos.branchable.com
  - meta: https://github.com/mateodelnorte/meta
  - Android repo: https://source.android.com/docs/setup/reference/repo
  - mani: https://github.com/alajmo/mani
- **Technical references**
  - Graph drawing (pvigier, 2019): https://pvigier.github.io/2019/05/06/commit-graph-drawing-algorithms.html
  - SwiftUI at scale:
    - https://developer.apple.com/videos/play/wwdc2025/256/
    - https://troz.net/post/2025/swiftui-mac-2025/
    - https://mjtsai.com/blog/2024/04/15/nstableview-with-swiftui/
  - Text engines:
    - https://github.com/CodeEditApp/CodeEditTextView
    - https://github.com/krzyzanowskim/STTextView
  - Git libraries:
    - libgit2: https://github.com/libgit2/libgit2/releases
    - gitoxide: https://github.com/GitoxideLabs/gitoxide/blob/main/crate-status.md
  - Highlighting:
    - https://github.com/tree-sitter/swift-tree-sitter
    - https://github.com/ChimeHQ/Neon
  - git fsmonitor:
    - https://git-scm.com/docs/git-fsmonitor--daemon
    - https://github.blog/engineering/infrastructure/improve-git-monorepo-performance-with-a-file-system-monitor/
  - 1Password SSH agent compatibility: https://www.1password.dev/ssh/agent/compatibility/
  - Sparkle: https://sparkle-project.org/documentation/
  - Homebrew cask rules:
    - https://docs.brew.sh/Acceptable-Casks
    - https://docs.brew.sh/Package-Acceptance-Policy
  - Sandboxing limits for git clients:
    - https://developer.apple.com/forums/thread/66995
    - https://developer.apple.com/forums/thread/807142
- **User sentiment**
  - Hacker News threads:
    - https://news.ycombinator.com/item?id=17448551
    - https://news.ycombinator.com/item?id=20511555
    - https://news.ycombinator.com/item?id=31567702
    - https://news.ycombinator.com/item?id=45878578
  - Fork Tracker: most-upvoted and most-commented issues.

*Fork is a trademark of its respective owners. Spoon is an independent project, and this spec describes Fork's publicly observable functionality only for feature-parity reference. Spoon does not use Fork's code, assets, artwork or branding.*
