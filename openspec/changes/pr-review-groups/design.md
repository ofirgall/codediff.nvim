# Design

## Context

See proposal.md for the motivation. Current state that shapes the approach:

- `ui/explorer/tree.lua` `create_tree_data()` builds the root nodes synchronously. In revision and directory mode it returns one `Changes (N)` group (`data = { type = "group", name = "unstaged" }`), and every file node carries `data.group = "unstaged"`.
- `data.group` is an identity key. `actions.navigate_next/prev` and `find_node_line` match files by `(path, group)`, `on_file_select` reads it, and staging dispatches on it. It cannot be repurposed for review groups.
- `refresh.lua` rebuilds the tree via the same `create_tree_data()`, then re-expands everything and restores the user's collapsed state by node key.
- `refresh.get_all_files()` only walks expanded nodes, so `]f`/`[f` currently skip files in collapsed groups.
- Line stats arrive asynchronously after the first render (`render.lua` numstat block, `refresh.merge_numstat`) and are patched into existing nodes.
- `git.lua` exposes async `run_git_async`, `get_file_content(rev, root, path)`, `get_diff_revision(s)`.
- The source of truth for grouping semantics is github-fast-pr (`src/core/grouping.ts`, `config.ts`, `gitattributes.ts`). Matching that behavior keeps one `.github/pr-groups.json` correct for both tools.

## Goals / Non-Goals

**Goals:**
- Group computation is a pure Lua module, unit-testable without a buffer or git.
- Everything git-related (config, attributes, blob ids) is loaded asynchronously once per explorer open or refresh, before the tree is built. `create_tree_data` stays synchronous.
- Zero behavior change in status mode and directory mode.

**Non-Goals:**
- GitHub sync of Viewed state, PR numbers, or `gh` integration.
- Per-hunk viewed tracking.
- Reading the config from `main`/`master` independently of the comparison (fast-pr does this; codediff uses the base revision instead).
- Review groups in the history panel.

## Decisions

### 1. New modules under `lua/codediff/review/`

```
review/
  config.lua    parse + validate pr-groups JSONC, compile patterns  (pure)
  regex.lua     JS-regex subset -> vim very-magic translation      (pure)
  grouping.lua  assign + order files into groups                   (pure)
  viewed.lua    persistent store keyed by (path, old blob, new blob)
  context.lua   async loader: config, generated attrs, blob ids, store
```

`context.load(explorer_params, cb)` produces a `review_ctx` that is attached to the explorer and passed into `create_tree_data`. In status and directory mode no context is built, and `create_tree_data` keeps today's code path. *Alternative:* grow `tree.lua` itself. Rejected because the pure parts deserve isolated specs and `tree.lua` should stay a layout function.

### 2. Node data: `review_group` is a separate field, `group` is unchanged

File nodes keep `group = "unstaged"`, so navigation, selection highlight and `on_file_select` work untouched. They gain `review_group = "<name>"` and `viewed = bool`. Group nodes keep `type = "group"`, `name = "unstaged"` for the plain case. Review group nodes use `type = "group"`, `name = "review:<name>"`, `review = { name, auto_viewed, total, viewed, ins, del }`. The `review:` prefix keeps collapsed-state keys distinct from status groups. `toggle_group` (`gu`/`gs`) ignores `review:` groups.

*Alternative:* store the review group in `data.group`. Rejected: it breaks `(path, group)` matching and the staging guards.

### 3. Regex: native JavaScript through node, Vim translator as fallback

`explorer.pr_review.regex_engine` picks how `paths` patterns are matched:
- `"auto"` (default): if `node` is on `$PATH`, `review/match.mjs` runs once per context load (about 20 ms). It gets every group's patterns and every changed path on stdin, and returns `path -> [group indices]` and JS's own regex errors. Matching is then identical to github-fast-pr by construction. If node is missing or fails, it falls back to the translator below.
- `"node"`: node only. Without node, the config is ignored with an error.
- `"vim"`: translator only.

Only matching moves to node. Priorities, ordering and viewed state stay in Lua. Pattern validation moves out of `config.parse` (`check_patterns = false`) into the engine step, so errors come from the engine actually used. *Alternative:* bundle github-fast-pr's grouping code into the node script. Rejected because it would tie codediff to a built copy of the extension's source for little gain.

**Fallback translator:**

The spec promises JavaScript semantics for the common subset. `vim.regex("\\v" .. p)` already agrees on `^ $ . [] () | * + ? {n,m} \d \w \s \.`. In very-magic mode, `< > = @ % ~ &` are special while in JS they are literals. `regex.lua` walks the pattern once, escapes those when unescaped, and maps group constructs onto Vim equivalents: every group becomes `%(...)` (so `(?:...)` and `(?<name>...)` too, since captures are unused), lookahead `(?=X)`/`(?!X)` becomes `%(X)@=`/`%(X)@!`, and lookbehind `(?<=X)`/`(?<!X)` becomes `%(X)@<=`/`%(X)@<!`. Real configs use these (e.g. `^scripts/(?!pre-pr/)`). Constructs with no mapping (inline flags like `(?i)`, `\b`, backreferences) are rejected with a clear error. Rejection makes the config invalid, which matches the "invalid config is ignored with one error" rule. Matching uses `vim.regex:match_str(path)` with `\C` to force case-sensitivity regardless of `'ignorecase'`.

*Alternatives:* Lua patterns (no alternation, different escapes, so every existing config breaks); a full regex library dependency (heavy for this).

### 4. JSONC: strip comments and trailing commas, then `vim.json.decode`

A small string-aware scanner, a port of fast-pr's `jsonc.ts`, removes `//` and `/* */` outside strings and drops commas before `}`/`]`. Then `vim.json.decode(text, { luanil = { object = true, array = true } })`.

### 5. Config source: base revision via `git show`

`git show <base>:.github/pr-groups.json`, then `.jsonc`. For `main...HEAD`, base is the merge-base hash codediff already computes, so the config is the one the branch was cut from. That is the closest local equivalent of fast-pr's "read from main". Setup option `explorer.pr_review.groups` (a Lua table with the same shape) replaces the repo config entirely. The table is validated the same way.

### 6. Generated: ask git, don't reimplement attribute matching

`git check-attr --stdin -z linguist-generated` at the target side. Changed paths go in on stdin, and `set`/`true` count as generated. To read the attributes as of the base revision (consistent with the config), pass `--source=<base>`, which needs git >= 2.40. On older git, fall back to the working tree's `.gitattributes`. This gets git's full matching rules (last line wins, `-attr`, `!attr`, directory patterns) for free, which fast-pr had to port.

### 7. Viewed identity = (path, old blob, new blob)

`git diff --raw -z --abbrev=40 <base> [<target>]` lists `old_sha new_sha status path` for every changed file in one call. For a working-tree target, git reports `new_sha` as zeros; those paths are hashed with `git hash-object --stdin-paths`, and deleted files use the zero id. A file is viewed if the store has `path\0old\0new -> viewed`.

- A new commit that touches the file changes `new_sha`, so the file is unviewed (spec: "Viewed is tied to the file's diff").
- A rebase that leaves the file untouched keeps both shas, so it stays viewed.
- Revision naming is irrelevant (spec: "Same diff, different revision names").

*Alternative:* key by `(repo, base ref, target ref)` session plus head commit, like fast-pr. Rejected: it resets everything on every push and breaks when the same branch is opened with different rev spellings.

### 8. Store format and location

One JSON file per repo: `stdpath("state")/codediff/viewed/<sha256(git_root)>.json`, containing `{ version = 1, entries = { [key] = { v = true|false, t = epoch } } }`. `v = false` records an explicit un-view, which is how an un-viewed auto-viewed file stays unviewed. Writes are debounced (about 200 ms) and atomic (write temp file, then `os.rename`). Entries older than 90 days are pruned on write. A read or parse failure gives an empty in-memory store and one `vim.notify` warning. Later writes for that session are skipped, so a corrupt file is never overwritten silently.

Effective viewed = `entry.v` if present, else `(group.auto_viewed and auto_mark_viewed)`.

### 9. Loading order and refresh

```
handle_explorer / refresh
   |
   +-- status/diff (existing) --+
   +-- review_ctx.load ---------+--> create_tree_data(status, ..., review_ctx) --> render
          |  git show config        (sync: grouping.assign/order, viewed lookup)
          |  git check-attr
          |  git diff --raw (+ hash-object for WORKING)
          |  viewed store (cached per git_root for the session)
```

The loads run in parallel with the existing status fetch, so they add no extra round trip on the critical path. On refresh, the config result is cached per base revision, and attrs and blob ids are re-fetched because files and working-tree content change. Initial collapse: review groups with `auto_viewed`, or all of them when `collapse_groups = true`, start collapsed. `refresh.lua` already restores user collapse state by key after re-expanding.

### 10. Navigation over collapsed groups

Viewed-aware `]f`/`[f` needs files in collapsed groups (spec). Add `refresh.get_all_files(tree, { include_collapsed = true })`, used only when a review context exists. When the target file is inside a collapsed node, navigation expands its ancestors before moving the cursor. Skipping filters on `data.viewed` when `skip_viewed` is on.

### 11. Header rendering

`nodes.prepare_node` renders review group headers as `name  viewed/total  +ins -del`, with the counts right-aligned like file line stats. Ins/del sum only unviewed files. The count is dimmed (new `CodeDiffExplorerGroupProgress`, linked to `Comment`) and the name keeps `CodeDiffExplorerTreeGroup`. Viewed files get a marker before the icon (`explorer.pr_review.viewed_icon`, default a check glyph) and are dimmed with `CodeDiffExplorerViewed` (linked to `Comment`). Header aggregates are recomputed from children whenever viewed state or numstat changes, and the numstat patch path then re-renders.

### 12. Config and keymaps

```lua
explorer = {
  pr_review = {
    enabled = true,           -- revision mode only
    groups = nil,             -- table overriding repo .github/pr-groups.json
    auto_mark_viewed = true,  -- auto-viewed groups start viewed
    collapse_groups = false,  -- true: every review group starts collapsed
    skip_viewed = true,       -- ]f/[f skip viewed files
    viewed_icon = "\u{f00c}",
    debug = false,            -- [codediff:review] log printed to :messages of each loading step
  },
},
keymaps = {
  explorer = { toggle_viewed = "v" },          -- file, directory or group under cursor
  view     = { toggle_viewed = "<leader>v" },  -- current file
}
```

`v` is unmapped in the explorer today, and visual mode there has no use. `debug = true` logs every loading step (skip reason, each `git show <base>:<path>` attempt with git's error, parse result, groups built), because a missing or unreadable config otherwise degrades silently to "no config". `enabled = true` by default because a repo without config or generated files only gains the viewed markers. Toggling viewed also emits a `User CodeDiffViewedChange` autocmd `{ tabpage, paths, viewed }` so users can hook it up (for example, to `gh`) without codediff knowing about GitHub.

## Risks / Trade-offs

- [Regex dialect drift: a config valid in fast-pr is rejected here (e.g. `(?i)`, `\b`)] → Clear error naming the pattern. The translator is covered by tests built from fast-pr's README examples and checked against fast-pr's TypeScript grouping on a real config (229 files, identical assignment).
- [`git check-attr --source` needs git >= 2.40] → Fall back to working-tree attributes, which are the same in the common case.
- [Hashing many working-tree files on each refresh] → Only for a `WORKING` target, only changed paths, one `hash-object --stdin-paths` call.
- [Changing the revision-mode header from `Changes (N)` to `Changes 0/N`] → Tests that match the header text need updating. Users see a richer header, with nothing removed.
- [Multiple Neovim instances writing the same store] → Last writer wins per file. Acceptable for a per-user review aid. Each write re-reads and merges entries before saving to limit loss.
- [Collapsed groups now count for `]f`] → Only when a review context exists. Status-mode navigation is unchanged.

## Migration Plan

Additive. There is no data migration: the store is created on first toggle. Rollback is `explorer.pr_review.enabled = false`, which restores the exact current revision-mode explorer.
