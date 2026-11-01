# Spec Delta

## Purpose

Tracks which changed files a reviewer has already looked at in a revision-mode review, keeps that across sessions, and uses it to skip reviewed files and report what is left.

## ADDED Requirements

### Requirement: Viewed state applies only in revision mode
The Viewed state SHALL exist only when the explorer compares revisions. Status mode and directory comparison SHALL show no viewed markers and SHALL not offer viewed actions.

#### Scenario: Status mode
- **WHEN** the user presses the toggle-viewed key in a `:CodeDiff` status-mode explorer
- **THEN** nothing is marked and no error is raised

### Requirement: Toggle viewed for a file
The user SHALL be able to toggle a file's Viewed state from the explorer (file under cursor) and from the diff panes (current file). The explorer SHALL show a viewed marker on viewed files.

#### Scenario: Mark from explorer
- **WHEN** the cursor is on an unviewed file and the user presses the toggle-viewed key
- **THEN** the file shows the viewed marker

#### Scenario: Mark from diff pane
- **WHEN** the user presses the view-side toggle-viewed key while reviewing a file
- **THEN** that file shows the viewed marker in the explorer

### Requirement: Batch toggle for a directory or group
Toggling Viewed on a directory or group node SHALL mark all its files viewed when any of them is unviewed, and otherwise mark them all unviewed.

#### Scenario: Partly viewed group
- **WHEN** a group has 3 files, 1 viewed, and the user toggles viewed on the group
- **THEN** all 3 files are viewed

#### Scenario: Fully viewed directory
- **WHEN** every file under a directory is viewed and the user toggles viewed on it
- **THEN** all of them are unviewed

### Requirement: Viewed is tied to the file's diff
A file SHALL count as viewed only while both sides of its diff are the same content as when it was marked. When either side changes, the file SHALL become unviewed.

#### Scenario: New commit changes the file
- **WHEN** a file is viewed and a new commit on the target changes that file
- **THEN** the file is unviewed in the next review of that branch

#### Scenario: New commit leaves the file alone
- **WHEN** a file is viewed and a new commit changes only other files
- **THEN** the file is still viewed

#### Scenario: Working tree edit
- **WHEN** the target is the working tree and the user edits a viewed file
- **THEN** the file becomes unviewed after the explorer refreshes

### Requirement: Viewed state persists
The Viewed state SHALL persist across Neovim sessions per repository, and SHALL be shared by every review whose file diff matches, regardless of how the revisions were named.

#### Scenario: Reopen after restart
- **WHEN** the user marks files viewed, quits Neovim, and runs the same `:CodeDiff main...HEAD` again
- **THEN** those files are still viewed

#### Scenario: Same diff, different revision names
- **WHEN** a file was marked viewed in `:CodeDiff main...feature` and the user opens `:CodeDiff <merge-base-sha> <feature-sha>` with the same file contents
- **THEN** the file is viewed

### Requirement: Viewed state storage failures do not break the review
If the stored state cannot be read or written, the review SHALL continue with in-memory state and the user SHALL see one warning.

#### Scenario: Corrupt state file
- **WHEN** the stored state is not valid
- **THEN** the review opens with no files viewed and one warning is shown

### Requirement: Auto-viewed groups
Files in an auto-viewed group (`autoViewed: true`, or Generated) SHALL be viewed by default. When the user un-views such a file, it SHALL stay unviewed for that file diff. A setup option SHALL turn off auto-viewing, leaving those groups grouped and ordered but unviewed.

#### Scenario: Lockfile starts viewed
- **WHEN** a review has `package-lock.json` in an auto-viewed `Lockfiles` group
- **THEN** it shows the viewed marker without user action

#### Scenario: User un-views an auto-viewed file
- **WHEN** the user un-views that lockfile and reopens the review
- **THEN** the lockfile is still unviewed

#### Scenario: Auto-viewing off
- **WHEN** auto-viewing is disabled in setup
- **THEN** the lockfile is in `Lockfiles` but not viewed

### Requirement: Collapsed by default
Fully viewed groups and directories, which by default include auto-viewed groups, SHALL start collapsed. A setup option SHALL make every review group start collapsed. Other groups SHALL start expanded.

#### Scenario: Default collapse
- **WHEN** a grouped review opens with default options
- **THEN** `Lockfiles` and `Generated` are collapsed and `Backend` is expanded

### Requirement: Fully viewed directories and groups collapse
A directory or group whose files are all viewed SHALL be dimmed with the viewed marker and SHALL collapse when it becomes fully viewed, including when the explorer opens. It SHALL expand again, with its ancestors, as soon as one of its files is unviewed, whether by the user or because the file's diff changed. One opened or closed by hand SHALL keep that state until its viewed state changes again.

#### Scenario: Last file of a directory viewed
- **WHEN** the last unviewed file of `server/` in `Backend` is marked viewed
- **THEN** `server/` and `Backend` collapse, are dimmed, and the cursor moves to the `Backend` header

#### Scenario: File in a collapsed viewed group unviewed
- **WHEN** a file in the collapsed, fully viewed `Lockfiles` group is unviewed (or its diff changes on refresh)
- **THEN** `Lockfiles` expands

### Requirement: Directory line stats
With line stats on, directory rows SHALL show the summed `+ins -del` of their unviewed files, and the full totals dimmed once fully viewed.

#### Scenario: Partly viewed directory
- **WHEN** `server/a.go` (+30 -5) is viewed and `server/c.go` (+70 -1) is not
- **THEN** the `server` row shows `+70 -1`

### Requirement: Auto-viewed groups are highlighted
Auto-viewed group names SHALL use a distinct highlight, yellow by default.

#### Scenario: Lockfiles header
- **WHEN** the explorer shows the auto-viewed `Lockfiles` group
- **THEN** its name uses `CodeDiffExplorerGroupAutoViewed`

### Requirement: Navigation skips viewed files
`]f`/`[f` SHALL move to the next or previous unviewed file in explorer order, including files in collapsed groups. A setup option SHALL turn the skipping off. When every file is viewed, navigation SHALL report that and stay on the current file.

#### Scenario: Skip
- **WHEN** files A, B, C are in order, B is viewed, and the user is on A
- **THEN** `]f` opens C

#### Scenario: All viewed
- **WHEN** every file is viewed and the user presses `]f`
- **THEN** a message says all files are viewed and the current file stays open

### Requirement: Group header shows progress and remaining lines
Each review group header SHALL show the group name, viewed count out of total files, and the summed insertions and deletions of its unviewed files when line stats are enabled. Headers SHALL update when Viewed state or line stats change.

#### Scenario: Header after marking
- **WHEN** `Backend` has 4 files totaling +100 -20 and the user marks a +30 -5 file viewed
- **THEN** the header shows `Backend 1/4` and `+70 -15`

### Requirement: Viewed state on the single Changes group
When a revision-mode review has no review groups, the Viewed state, markers, batch toggle, navigation skipping and header progress SHALL still work on the `Changes` group.

#### Scenario: Plain repo
- **WHEN** a repo has no config and the user marks one of 5 files viewed
- **THEN** the header shows `Changes 1/5`
