# Spec Delta

## Purpose

Groups and orders the changed files of a revision-mode review by rules the repository commits, so reviewers see the important code first and noise last.

## ADDED Requirements

### Requirement: Review groups apply only in revision mode
The explorer SHALL apply review groups only when it compares revisions (a base revision is set). Status mode and directory comparison SHALL keep their current groups.

#### Scenario: Revision mode with a config
- **WHEN** the user runs `:CodeDiff main...HEAD` in a repo whose base revision has `.github/pr-groups.json`
- **THEN** the explorer shows one top-level node per non-empty review group instead of `Changes (N)`

#### Scenario: Status mode is unchanged
- **WHEN** the user runs `:CodeDiff` with no revision in the same repo
- **THEN** the explorer shows the Merge Changes / Changes / Staged Changes groups as before

#### Scenario: Directory comparison is unchanged
- **WHEN** the user compares two directories
- **THEN** the explorer shows a single `Changes (N)` group as before

### Requirement: Config is read from the base revision
The config SHALL be read from `.github/pr-groups.json` at the comparison's base revision, falling back to `.github/pr-groups.jsonc` when the first is absent. Files on the target side SHALL NOT be used.

#### Scenario: Config only on the reviewed branch
- **WHEN** the target revision adds `.github/pr-groups.json` but the base revision has none
- **THEN** no config is used for that review

#### Scenario: JSONC fallback
- **WHEN** the base revision has only `.github/pr-groups.jsonc`
- **THEN** that file is used as the config

### Requirement: Config format
The config SHALL be a JSON object with `groups`: an array of `{ name, paths, autoViewed?, matchPriority?, viewPriority? }`, plus optional `generated: { matchPriority?, viewPriority? }` and `ungrouped: { viewPriority? }`. `//` and `/* */` comments and trailing commas SHALL be accepted.

#### Scenario: Comments and trailing commas
- **WHEN** the config contains `// note` lines and a trailing comma after the last group
- **THEN** the config parses and its groups apply

### Requirement: Invalid config is ignored with one error
A config with bad JSON, a missing or empty `name` or `paths`, a non-string path, an invalid pattern, a non-boolean `autoViewed`, or a non-number priority SHALL be ignored, and the user SHALL see one error that names the problem. The review SHALL continue as if no config existed.

#### Scenario: Bad pattern
- **WHEN** a group has the path pattern `"(unclosed"`
- **THEN** an error naming that group and pattern is shown once, and files are shown without config groups

### Requirement: Path patterns
Each entry in `paths` SHALL be a regular expression matched unanchored and case-sensitively against the repo-relative path. Anchors (`^`, `$`), `.`, escapes like `\.`, character classes, groups, alternation (`|`) and the quantifiers `* + ? {n,m}` SHALL behave as in JavaScript regexes.

#### Scenario: Anchored prefix
- **WHEN** a group has the path `"^server/"`
- **THEN** `server/a.go` matches and `web/server/a.go` does not

#### Scenario: Alternation and escaped dot
- **WHEN** a group has the path `"\\.(lock|sum)$"`
- **THEN** `go.sum` and `yarn.lock` match and `lockfile.txt` does not

### Requirement: Group assignment by match priority
Each file SHALL belong to exactly one group: the matching group with the highest `matchPriority`, with ties going to the earliest group in config order. A file matching no group SHALL be `Ungrouped`. Default `matchPriority` SHALL be 1 for auto-viewed groups and 0 otherwise.

#### Scenario: Auto-viewed group wins by default
- **WHEN** `web/package-lock.json` matches both `Frontend` (`^web/`) and `Lockfiles` (`autoViewed: true`)
- **THEN** the file is in `Lockfiles`

#### Scenario: Explicit priority overrides
- **WHEN** `a_test.go` matches `Backend` and `Tests` with `matchPriority: 2`
- **THEN** the file is in `Tests`

### Requirement: Group order by view priority
Groups SHALL be ordered by `viewPriority`, highest first. Ties SHALL keep config order, with Generated after configured groups and Ungrouped after all groups at equal priority. Defaults SHALL be 0 for normal groups, -1 for Ungrouped, and -2 for auto-viewed groups. Files SHALL keep their original order within a group, and empty groups SHALL be hidden.

#### Scenario: Default order
- **WHEN** a review has files in `Backend`, `Lockfiles` (auto-viewed) and unmatched files
- **THEN** groups appear as `Backend`, `Ungrouped`, `Lockfiles`

#### Scenario: Ungrouped promoted
- **WHEN** the config sets `"ungrouped": { "viewPriority": 5 }`
- **THEN** `Ungrouped` appears first

### Requirement: Generated group from gitattributes
Files that git reports as `linguist-generated` (set, not unset) SHALL form an auto-viewed group named `Generated`, whether or not a config exists. The top-level `generated` config entry SHALL set its priorities.

#### Scenario: No config, generated files
- **WHEN** the repo has no `pr-groups.json` and `.gitattributes` marks `*.pb.go linguist-generated`
- **THEN** the explorer shows `Generated` for `.pb.go` files and `Ungrouped` for the rest

#### Scenario: Last matching attribute line wins
- **WHEN** `.gitattributes` marks `gen/** linguist-generated` and then `gen/keep.go -linguist-generated`
- **THEN** `gen/keep.go` is not in `Generated`

### Requirement: No grouping without rules
When there is no valid config and no generated file in the review, the explorer SHALL show the single `Changes (N)` group as before.

#### Scenario: Plain repo
- **WHEN** a repo has no config and no `linguist-generated` attributes
- **THEN** the explorer shows `Changes (N)`

### Requirement: Setup config overrides the repo config
When the user sets a review groups config in plugin setup, it SHALL be used for every repo instead of the repo's file, using the same format and validation. The repo's Generated group SHALL still apply.

#### Scenario: Override
- **WHEN** setup provides groups and the repo has its own `pr-groups.json`
- **THEN** the setup groups are used and the repo file is ignored

### Requirement: Groups work in list and tree view
Group nodes SHALL contain files in list view and a directory tree in tree view, and toggling the view mode SHALL keep the groups.

#### Scenario: Tree view
- **WHEN** the user toggles to tree view during a grouped review
- **THEN** each group shows its own directory tree of only its files

### Requirement: Groups survive refresh
When the explorer refreshes (manual or automatic), files SHALL be regrouped with the same rules, and the user's collapsed or expanded state of groups SHALL be kept.

#### Scenario: Collapse kept across refresh
- **WHEN** the user collapses `Backend` and the explorer refreshes
- **THEN** `Backend` is still collapsed
