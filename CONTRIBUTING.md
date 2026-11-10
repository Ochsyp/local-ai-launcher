# Contributing

Every change reaches `main` through a pull request, so that it is reviewed before it is merged.
This holds for the maintainer too.

## Workflow

1. Start from an up-to-date `main` and create a branch for the change:
   - `phase/<n>-<slug>` for a phase of a planned redesign, for example `phase/8-env-allow-list`;
   - `fix/<slug>`, `feat/<slug>`, `docs/<slug>` or `chore/<slug>` for anything else.
2. Commit on that branch. Commit messages follow
   [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/), for example
   `fix: give Open WebUI an environment allow-list`.
3. Add an entry for the change under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md), on the
   same branch. A release and the fix of a draft release are the two exceptions; see
   [Releases](#releases).
4. Run the checks described in the README's Development section.
5. Push the branch and open a pull request against `main`. CI and the secret scan run on it.
6. Start the next phase only after the pull request is reviewed and merged. Its branch starts from
   the updated `main`.

One pull request holds one phase or one change.

## Guard rails

`main` is never committed to or pushed to directly. GitHub does not enforce this for this
repository, so two git hooks in `.githooks` enforce it on each clone:

- `pre-commit` refuses a commit while `main` or `master` is checked out;
- `pre-push` refuses a push to `main` or `master`.

Turn them on once after cloning:

```text
git config core.hooksPath .githooks
```

Do not bypass them with `--no-verify`. After a pull request is merged, bring the local `main` up
to date with `git switch main` and `git pull --ff-only`.

## Releases

A release is a pull request like any other. Claude prepares it; the maintainer reviews and merges
it, and publishes the release that GitHub Actions then drafts. Claude never creates a tag and
never publishes, edits or deletes a release.

1. Branch `chore/release-X.Y.Z` from an up-to-date `main`.
2. Write `X.Y.Z` and a line feed to `VERSION`. Raise MAJOR, MINOR or PATCH as
   [Semantic Versioning](https://semver.org/spec/v2.0.0.html) asks for the changes since the last
   release.
3. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`, with the planned
   merge date, and add an empty `## [Unreleased]` above it. Point the `[Unreleased]:` link at
   `compare/vX.Y.Z...HEAD`, and add a `[X.Y.Z]:` link to `releases/tag/vX.Y.Z`, or after the first
   release to `compare/vPREVIOUS...vX.Y.Z`. The move is the release's entry; it adds no other.
   The first release also drops the sentences in `CHANGELOG.md` and the README that say there
   is no release yet.
4. In the README's *Install from a release*, point the `install.ps1` one-liner and its script
   block form at `releases/download/vX.Y.Z/install.ps1`. Each pins the tag of a release, so it
   always gets the same file.
5. Commit as `chore(release): X.Y.Z` and open the pull request with that title. Its body is the
   new CHANGELOG section. CI checks that `VERSION`, the heading and the links agree, that tag
   `vX.Y.Z` does not exist yet and that X.Y.Z is greater than the `VERSION` of `main`, when it
   has one. The release workflow builds the zip as a dry run.
6. The maintainer merges it. The merge changes `VERSION` on `main`, so
   `.github/workflows/release.yml` builds the zip, `install.ps1`, `SHA256SUMS` and the
   attestation from the merge commit, and creates the draft release `vX.Y.Z` for that commit.
   The build refuses an X.Y.Z that is not greater than every released version, and a
   `## [Unreleased]` section that lists anything, because the release would ship those changes
   without naming them.
7. The maintainer checks the draft's notes, its three assets and its target commit, then
   publishes it. Publishing creates the tag `vX.Y.Z` and makes the release immutable. The
   workflow then checks the published assets and attestations.

Until the draft is published, merge nothing into `main` but fixes of the release: a new build
ships the tip of `main`. To fix the draft, merge the fix through a pull request that lists its
change in the `## [X.Y.Z]` section, not under `## [Unreleased]`, since the fix ships in X.Y.Z.
Then run `release.yml` on `main` with *Run workflow*. It builds the tip of `main` and replaces
the draft. Do not re-run an older run instead: the draft job refuses a commit that is no longer
the tip of `main`. A published release never changes, so a fix after that is the next version.
Publish on the date the heading names, or fix the date through a pull request and run the
workflow again before you publish.

### Release contract

Whatever installs or updates the launcher from a release relies on these rules, so a change to
one of them is a MAJOR change. An added asset is a MINOR change, since `update` and
`install.ps1` look only for the assets they know.

- `VERSION` at the repository root holds one line `X.Y.Z` and a line feed. It is the only
  launcher version; `VERSION` in `src\image_gate.py` is the image gate's own protocol version.
  Without `VERSION`, as in a git checkout before the first release, no release is prepared: CI
  passes with a notice, and `status -Json` reports `launcher.version` as null. A missing
  `VERSION` while `CHANGELOG.md` has a version heading is an error.
- The tag and the release title are `vX.Y.Z`. The release notes are the CHANGELOG section from
  `## [X.Y.Z] - YYYY-MM-DD` up to the next `## [` heading, without the link reference lines.
- The asset `local-ai-launcher-X.Y.Z.zip` is
  `git archive --format=zip --prefix=local-ai-launcher-X.Y.Z/` of the built commit, made with
  `TZ=UTC`. The export-ignore lines in `.gitattributes` keep out `.github`, `.githooks`, `tests`,
  `.editorconfig`, `.gitattributes`, `.gitignore`, `PSScriptAnalyzerSettings.psd1` and this
  file. The eol attributes apply: `*.cmd`, `*.ps1`, `*.psm1` and `*.psd1` have CRLF line ends,
  every other file LF.
- A second `git archive` pass adds `local-ai-launcher-X.Y.Z/local-ai-release.json` with
  `--add-file`, which gives it the commit time as every other entry has. This manifest lists
  every other file of the folder by its path there, with forward slashes, in ordinal order, and
  the SHA-256 of its bytes in lowercase hex. It is ASCII with LF line ends, indented by two
  spaces:

  ```text
  {
    "schema": 1,
    "name": "local-ai-launcher",
    "version": "X.Y.Z",
    "tag": "vX.Y.Z",
    "commit": "<the commit's 40 hex digits>",
    "files": {
      "CHANGELOG.md": "<SHA-256 in lowercase hex>",
      ...
    }
  }
  ```

- The asset `install.ps1` is the zip's `local-ai-launcher-X.Y.Z/src/install.ps1`, byte for
  byte, with CRLF line ends. It runs as a file and through `irm <address> | iex`, so it never
  calls `exit` and never reads its own path. It holds a copy of the lines from
  `# BEGIN LAUNCHER RELEASE FUNCTIONS` to `# END LAUNCHER RELEASE FUNCTIONS` of
  `src\LocalAI.psm1`, which `tests\LocalAI.Tests.ps1` compares, so it checks and stages a
  release as `update` does.
- The asset `SHA256SUMS` holds one line per other asset: the SHA-256 in lowercase hex, two
  spaces and the file name, then a line feed, in ASCII.
- A build provenance attestation covers the zip. `release.yml` signs it on `refs/heads/main`.
- A release install lives in `%LOCALAPPDATA%\Programs\local-ai-launcher`: the shim
  `local-ai.cmd`, which nothing rewrites once it exists and which runs only from that folder,
  the file `current`, which holds the active tag `vX.Y.Z` and CRLF, and one folder
  `versions\vX.Y.Z` per release, which never changes once it is in place.
- Every release keeps `local-ai.cmd` at the top of its folder, as the shim of every release
  install runs `versions\vX.Y.Z\local-ai.cmd` with all of its arguments. Every release's
  `src\LocalAI.psm1` exports `Install-LocalAILauncher -Root <install folder> -Tag vX.Y.Z`, which
  checks that version's folder against its manifest, writes the shim when it is missing and
  points `current` at that version: every older `install.ps1` imports it from the release it
  installs and calls it.
- Every release keeps the verb `shortcuts`, which `install.ps1 -Shortcuts` runs through the shim
  on the release it has just installed, and which ends with 0 when done, 2 with warnings and any
  other code on a failure. It also keeps the verb `install`, which `install.ps1` names as the
  next step.
- Every installed version and every `install.ps1` refuse a release whose zip is above 64 MB,
  holds more than 10000 entries or more than 256 MB once extracted, or holds an entry with more
  bytes than the zip states for it. They also refuse two entries whose names differ only in
  case, a file where another entry needs a folder, and a path segment that is a device name such
  as `AUX` or `NUL`, that ends in a dot or a space, or that holds `"`, `*`, `:`, `<`, `>`, `?`,
  `|` or a control character. A release stays within these limits, which `Assert-ReleaseZip`
  checks in the build.
- `state.json` in `%LOCALAPPDATA%\local-ai` holds
  `Launcher = @{ Version; Previous; LastCheck = @{ CheckedAt; Latest; Digest; Error } }`: the
  tags `vX.Y.Z`, `CheckedAt` as a number of UTC ticks, the digest `sha256:<hex>` and the error
  text. One version writes it and another reads it across the handover and `update -Rollback`,
  so later versions keep these keys and their types.
- `update` hands over to the version it staged by running that version's `src\local-ai.ps1` as
  `update [-Tools] -ActivateLauncher vX.Y.Z`, and `update -Rollback` hands over to the version
  before in the same way. Every later version must accept that call: it checks its settings,
  shows the plan with the line `Launcher: vOLD -> vNEW` when `current` names another version,
  asks once, and on yes points `current` at vX.Y.Z before it changes any part; when parts
  change, it first stops what runs. `-ActivateLauncher` is hidden from help and is not for
  people.
- The same commit gives the same zip bytes with the same git version. `tests\Release.Tests.ps1`
  and the dry run on pull requests check that.
