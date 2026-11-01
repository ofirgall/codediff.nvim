# Tasks

## 1. Pure review core (config, regex, grouping)

- [x] 1.1 Add `lua/codediff/review/regex.lua`: translate the JS regex subset to `\v\C` Vim regex (escape `< > = @ % ~ &`, reject `(?:`, lookarounds, `\b`, backrefs). Verify with `tests/review/regex_spec.lua` covering `^server/`, `\.go$`, `\.(lock|sum)$`, `package-lock\.json$`, literal `<`/`@`/`=`, and rejected constructs
- [x] 1.2 Add JSONC stripping (comments outside strings, trailing commas) in `review/config.lua`. Verify with spec cases: `//` and `/* */` comments, `//` inside a string kept, trailing commas in arrays and objects
- [x] 1.3 Implement config parse and validation in `review/config.lua` (groups, `name`/`paths`/`autoViewed`/priorities, top-level `generated`/`ungrouped`) returning `{ ok, config }` or `{ ok = false, error }`. Verify with a spec asserting each error message from the "Invalid config is ignored" requirement
- [x] 1.4 Implement `compile` with default priorities (match 1/0, view -2/0, ungrouped -1) and the Generated group, plus `review/grouping.lua` `assign`/`order`. Verify with `tests/review/grouping_spec.lua` porting the scenarios from the review-groups spec (auto-viewed wins, explicit matchPriority, default order, promoted Ungrouped, stable order within group, Generated after config groups on ties)

## 2. Git plumbing

- [x] 2.1 Add `git.get_file_at_revision`-style read for `.github/pr-groups.json` then `.jsonc` at a revision (reuse `get_file_content`), treating "path does not exist" as no config. Verify in `tests/core/git_integration_spec.lua` with a temp repo: config on base only, config on target only, jsonc fallback
- [x] 2.2 Add `git.check_attr_generated(git_root, paths, source_rev, cb)` using `check-attr --stdin -z` with `--source` when git >= 2.40, else working tree. Verify with a temp repo: `*.pb.go linguist-generated`, then `-linguist-generated` override for one file
- [x] 2.3 Add `git.get_diff_blobs(git_root, base, target, cb)` from `diff --raw -z --abbrev=40`, plus `hash-object --stdin-paths` for a WORKING target. Verify with a temp repo: committed target, working-tree target with an edited file, deleted file returns the zero id

## 3. Viewed store

- [x] 3.1 Add `review/viewed.lua`: per-repo JSON store at `stdpath("state")/codediff/viewed/<sha256(root)>.json`, keyed `path\0old\0new` with `{ v, t }`, debounced atomic write, re-read-and-merge on write, 90-day prune. Verify with `tests/review/viewed_spec.lua` using a temp state dir: round trip, explicit `v=false`, prune, merge with a concurrent writer
- [x] 3.2 Handle unreadable or corrupt store: empty in-memory store, one warning, writes disabled for the session. Verify with a spec that writes garbage to the file and asserts a single `vim.notify` and an unchanged file

## 4. Review context and explorer grouping

- [x] 4.1 Add `explorer.pr_review` options and keymaps `explorer.toggle_viewed = "v"`, `view.toggle_viewed = "<leader>v"` to `config.lua`. Verify `tests/api_spec.lua` (or config spec) sees the defaults
- [x] 4.2 Add `review/context.lua` `load()`: in parallel, config (cached per base rev, or the setup `groups` override), generated attrs, diff blobs, and store. Report config errors once per explorer. Verify with a spec on a temp repo that the context has the expected groups, generated set, and blob keys, and that status/dir mode yields no context
- [x] 4.3 Wire context loading into explorer open (`render.lua` create path from `commands.handle_explorer`) and refresh (`refresh.lua`), running alongside the existing status fetch. Verify that existing `tests/ui/explorer/*_spec.lua` still pass unchanged in status mode
- [x] 4.4 Extend `tree.create_tree_data` to build review group nodes (`name = "review:<name>"`, `review` aggregate) with file nodes carrying `review_group` and `viewed` while keeping `group = "unstaged"`, in both list and tree view. Hide empty groups and fall back to `Changes` when there are no rules. Verify with `tests/ui/explorer/review_groups_spec.lua`: grouped list, grouped tree, plain repo shows one Changes group, `pr_review.enabled = false` gives today's exact output
- [x] 4.5 Make `toggle_group` (`gu`/`gs`) ignore `review:` groups, and apply initial collapse (auto-viewed, or all when `collapse_groups`) while keeping user collapse state across refresh. Verify in the review_groups spec that a collapsed group stays collapsed after `refresh`
- [x] 4.6 Document `.github/pr-groups.json` (format, regex subset, priorities, Generated, base-revision sourcing, setup override) in README and `doc/codediff.txt`. Verify the README example config parses with `review/config.lua` in a spec

## 5. Viewed UX

- [x] 5.1 Render the viewed marker and `CodeDiffExplorerViewed` dimming on file nodes, and group headers as `name viewed/total +ins -del` (unviewed only) with `CodeDiffExplorerGroupProgress`. Register highlights in `highlights.lua`. Verify in the review_groups spec by reading buffer lines and extmarks for a header after numstat arrives
- [x] 5.2 Implement the explorer `toggle_viewed` on file, directory and group nodes (any unviewed: mark all, else unmark all), persisting via the store, recomputing aggregates, re-rendering, and emitting `User CodeDiffViewedChange`. Verify with a spec covering file, partly-viewed group, and fully-viewed directory
- [x] 5.3 Implement view-side `toggle_viewed` for the current file in revision mode, as a no-op in status/dir mode. Verify with a spec that triggers it from the modified pane and checks the explorer node
- [x] 5.4 Apply auto-viewed defaults (`auto_mark_viewed`) with explicit `v=false` overriding. Verify scenarios: lockfile starts viewed, un-view persists across reopen, `auto_mark_viewed = false` leaves it unviewed
- [x] 5.5 Add `get_all_files(tree, { include_collapsed = true })` and viewed-skipping in `navigate_next/prev` (expand ancestors of a target in a collapsed group, "all files viewed" message). Verify with a spec of A/B(viewed)/C navigation, a target inside a collapsed group, and the all-viewed case, plus existing navigation specs passing
- [x] 5.6 Verify the viewed-identity rules end to end on a temp repo: a new commit touching a viewed file unviews it, a commit touching other files keeps it, a working-tree edit unviews it after refresh, and `main...feature` vs explicit SHAs share state
- [x] 5.7 Document viewed state, keymaps, options and the `CodeDiffViewedChange` autocmd in README and `doc/codediff.txt`. Verify that `:help` tags regenerate without errors

## 6. Integration

- [x] 6.1 Run the full suite (`tests/run_plenary_tests.sh`) and fix any header-text expectations changed by `Changes 0/N`. Verify the suite is green
- [x] 6.2 Manual check following the `nvim-e2e-workflow` skill on a repo with a fast-pr style config: grouped explorer, auto-viewed lockfiles collapsed, `]f` skipping, headers updating. Verify that the same `.github/pr-groups.json` used by github-fast-pr produces the same group assignment for a sample branch
- [x] 6.3 Add `explorer.pr_review.debug` logging of each review-context loading step. Verify with `tests/review/context_spec.lua` debug-logging cases (silent when off, found/parsed/built, git error per missing path, status-mode skip)
- [x] 6.4 Translate `(?:...)`, named groups and lookarounds to Vim `%(...)`/`@=`/`@!`/`@<=`/`@<!`, and report config errors with `nvim_echo` so they stay in `:messages`. Verify with `tests/review/regex_spec.lua` lookaround cases and a TS-vs-Lua parity run on a real config using `^scripts/(?!pre-pr/)`
- [x] 6.5 Add `explorer.pr_review.regex_engine` (`auto`/`node`/`vim`): match patterns with native JS regexes via `node` (`review/match.mjs`, `review/js_match.lua`), falling back to the Vim translator. Verify with `tests/review/regex_engine_spec.lua` (node matching and errors, `\b` only under node, fallback when node is missing or fails, node-only error) and a real-config run where all 229 files are grouped like github-fast-pr
- [x] 6.6 Directory rows show remaining +ins -del; fully viewed directories/groups are dimmed and auto-collapse when they become fully viewed (and on open); auto-viewed group names use `CodeDiffExplorerGroupAutoViewed`. Verify with `tests/ui/explorer/review_viewed_spec.lua` (directory stats, fade + collapse + cursor, reopen sticks, auto-viewed highlight, collapsed on open)
- [x] 6.7 Expand a group/directory (and its ancestors) when it stops being fully viewed: un-view by toggle or a diff change on refresh; auto-viewed groups with unviewed files start open. Verify with `tests/ui/explorer/review_viewed_spec.lua` (un-view expands, refresh after a change expands, auto_mark_viewed=false opens Lockfiles)
