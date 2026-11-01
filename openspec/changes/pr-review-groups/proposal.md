# Proposal

## Why

Reviewing a large branch with `:CodeDiff main...HEAD` shows every changed file in a single `Changes (N)` list sorted by path. The code that matters sits next to lockfiles and generated code, and there is no way to track which files are already reviewed. The github-fast-pr browser extension fixes this on github.com with repo-defined file groups, a Viewed state, and auto-viewed noise. This change brings the same review workflow into codediff, locally and git-only, so the same `.github/pr-groups.json` drives both.

## What Changes

- In revision mode (`:CodeDiff <rev>`, `:CodeDiff <rev1> <rev2>`, `:CodeDiff <base>...<target>`), the explorer replaces the single `Changes` group with review groups read from `.github/pr-groups.json` (or `.jsonc`) at the base revision. Assignment and ordering follow `matchPriority`/`viewPriority` the same way github-fast-pr does. Files that match no group go to `Ungrouped`.
- Files marked `linguist-generated` in `.gitattributes` go to an auto-viewed `Generated` group, even when the repo has no `pr-groups.json`.
- A local, persistent **Viewed** state per file. It is tied to the file's content on both sides of the diff, so a file stops being viewed when its diff changes. Files show a viewed marker in the explorer.
- Keymaps toggle Viewed for a file, a directory, or a whole group.
- `]f`/`[f` skip viewed files (configurable).
- Auto-viewed groups (`autoViewed: true`, Generated) start viewed and collapsed. A file the user un-views stays un-viewed for that diff.
- Group headers show viewed progress and the unviewed line counts (`+ins -del`).
- A setup option (`pr_review.groups`) overrides the repo config for every repo, like the extension's Local config.
- Status mode (working tree / staged / unstaged) is unchanged. A repo with no config and no `linguist-generated` files gets the current single `Changes` group, plus the Viewed state.
- No GitHub integration: nothing reads or writes GitHub's Viewed state.

## Capabilities

### New Capabilities
- `review-groups`: Grouping and ordering of changed files in revision-mode explorer by a repo config and `.gitattributes`, including config sourcing, validation, and group header display.
- `review-viewed-state`: Local, persistent per-file Viewed state for revision-mode reviews, including auto-viewed groups, batch toggling, viewed-aware navigation, and unviewed line counts.

### Modified Capabilities
<!-- None: no existing specs in openspec/specs/. -->

## Impact

- `lua/codediff/ui/explorer/tree.lua` (revision-mode tree construction), `nodes.lua` (group header and viewed marker rendering), `render.lua` / `refresh.lua` (loading review context, numstat patching, collapse defaults), `actions.lua` / `keymaps.lua` (toggle viewed, viewed-aware next/prev), `ui/view/keymaps.lua` (view-side toggle keymap).
- `lua/codediff/core/git.lua`: reading a file at a revision for config, `git check-attr`, blob ids for viewed keys.
- `lua/codediff/config.lua`: new `explorer.pr_review` options and new keymaps.
- New state file under `stdpath("state")` for Viewed records.
- Docs: README and `doc/` help for the config file format, options, and keymaps.
- No new external dependencies.
