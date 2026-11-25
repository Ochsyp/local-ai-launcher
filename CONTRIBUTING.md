# Contributing

local-ai-launcher has one maintainer. This file says how a change reaches `main`, how to check
it, and how a release is made.

<!-- standard:begin workflow -->
## Workflow

Every change reaches `main` through a pull request that the maintainer reviews and merges. This
holds for the maintainer too.

1. Branch from an up-to-date `main`: `phase/<n>-<slug>` for a phase of the plan, or `fix/`,
   `feat/`, `docs/` or `chore/` plus a short slug.
2. Write commit messages and the pull request title as Conventional Commits (`feat:`, `fix:`,
   `docs:`, `chore:`, `ci:`, `test:`, `refactor:`).
3. Add a line under `## [Unreleased]` in `CHANGELOG.md`. Three kinds of pull request add none
   there: a release pull request (`chore/release-X.Y.Z`), which moves the lines into the new
   version; the fix of a draft release (`fix/release-X.Y.Z-<slug>`), whose line goes into that
   version's section; and a Dependabot pull request, whose updates the next release pull request
   sums up.
4. Run the checks in Checks below, and fix what they find.
5. Push the branch and open a pull request against `main`. Before every `gh pr create` and
   `gh pr edit`, run `.github/standard/bin/pr-text` on the title and the body: it refuses
   denylist terms and rule pack hits, and never prints them.
6. Start the next phase only after the pull request is merged.

One pull request holds one phase or one change.

Repository work happens only on a machine with the maintainer's git configuration, which turns
the hooks on and loads the denylists for every clone of this repository, never in a cloud
session. That configuration matches this repository's GitHub URL: a clone made from a local path
gets no hooks, so run `git config core.hooksPath .githooks` in it right after cloning.

An outside contributor's pull request is reviewed in the browser and through CI. Hooks run from
the checked-out tree with the maintainer's credentials, even during a fetch, so:
- never check out a fork's pull request branch in a clone with the hooks on;
- clone a fork only with `git clone <fork URL>` or `gh repo clone <fork> <folder> --no-upstream`,
  into a scratch folder, and never add a remote for this repository there.
<!-- standard:end workflow -->

<!-- standard:begin guard-rails -->
## Guard rails

GitHub's ruleset on `main` blocks force pushes and its deletion. Once the maintainer has updated
it after this repository's adoption of the standard, it also blocks direct pushes, and the merge
of a pull request whose `all-passed` or `scan` check failed.

The hooks in `.githooks/` guard every commit and push:
- `pre-commit` refuses a commit while `main` or `master` is checked out, a changed copy of the
  standard, a staged file above `MAX_BLOB_KB`, and staged content, path names, author or
  committer that hold a denylist term or a rule pack hit. `pre-merge-commit` does the same for a
  merge.
- `commit-msg` refuses such a term or hit in the message.
- `pre-push` refuses a push to `main` or `master`, every tag push except a `v*` tag under
  `RELEASE_KIND=legacy` (otherwise release tags come from publishing a release), a branch or tag
  name with a term or hit, and what the pushed commits bring in, which covers rebase, cherry-pick
  and `am` too.

The denylists hold names that must never be committed and never leave the maintainer's machine.
The rule packs in `.githooks/rules/` hold the patterns: private addresses, local host names, MAC
addresses, home paths, e-mail addresses, and disk and VM identifiers where the config enables
them. A refusal names the file and line and the kind of finding, never the value.

The maintainer's git configuration turns the hooks on for every clone of this repository's GitHub
URL. In a clone made from a local path, or anywhere else, turn them on once after cloning:
`git config core.hooksPath .githooks`. Never use `--no-verify`.
<!-- standard:end guard-rails -->

<!-- standard:begin standard -->
## The repository standard

Files listed in `.github/standard/MANIFEST` are copies of the repository standard. Never edit
them here: change repo-standard, release it, and sync with a `chore/standard-X.Y.Z` pull request.
CI fails when a copy differs or changes on another branch. Sync summaries and pull request texts
here name no other repository. An exemption, an accepted finding or a dropped check comes in a
`chore/privacy-*` pull request of its own.

A repository goes public in this order. A pull request sets `VISIBILITY=public` and brings the
public block texts. The maintainer switches the repository to public on GitHub and turns on the
security settings those texts promise. A new commit on that branch reruns its checks; a rerun
from the Actions page keeps the old private flag. Then that pull request merges before anything
else, since until then `main` says private while GitHub says public.
<!-- standard:end standard -->

## Checks

Run these from the repository root before you push.

- In Windows PowerShell 5.1, with PSScriptAnalyzer 1.25.0 and Pester 6.2.0 installed: the
  analyzer over `src`, `config`, `tests`, `ci` and `.github`, then every Pester test. The
  script points `LOCALAPPDATA` at a temporary folder, so the tests leave a real install alone.

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-checks.ps1
  ```

- The image gate tests, with a Python 3.12 or newer that has the packages in
  `tests\requirements.txt`:

  ```text
  <python> -I -B -m unittest discover -s tests -p "test_*.py"
  ```

- In Git Bash: the copies of the standard and the hooks on this clone, then the privacy rules
  over the tree. Both print counts and paths, never a value.

  ```sh
  sh .github/standard/bin/standard-check --local
  sh .githooks/privacy-scan --tracked
  ```

- When a change touches the standard's files: its bats suites, one file at a time in Git Bash,
  for example `bats .github/standard/tests/hooks.bats`. `.github/standard/bin/install-tools bats`
  installs the pinned bats and prints its folder.

CI adds the rest. The `ci` workflow runs the job `standard` (the standard's copies, the config,
actionlint, the standard's suites, the privacy rules over the tree, `VERSION` against
`CHANGELOG.md`, and the pull request's title and changelog entry), the stages `lint` and `test`
(`ci/lint.ps1` and `ci/test.ps1` on Windows), `hooks-windows`, and the gate `all-passed`. The
`secret-scan` workflow runs the job `scan`. `release.yml` builds the release twice and compares the
builds for a pull request that changes `VERSION`, `.gitattributes`, the config, the release
workflows or tools, or `ci/release-build.ps1`; a change to `.github/scripts/` alone gets no dry run,
and `tests/Release.Tests.ps1` checks it. CI fails on any skipped bats
test. A Pester test skips only where the runner lacks what it needs, such as 8.3 short names;
the Pester summary line shows how many skipped.

On a CI runner, `ci/test.ps1` ends with `ci/files-server-live.ps1`, which installs the pinned mcpo
and files server and fails unless they offer exactly `Files.AllowedTools` and one folder. It then
changes `Files.Root` and fails unless `start`'s own code restarts mcpo, which must then serve only
the new folder. Last it starts mcpo with no hidden tools and fails unless the server's
`--read-only` alone leaves exactly the ten read tools that `Get-LiveReadOnlyTool` in that script
lists; a server upgrade that adds a read tool updates that list too. Its last line says whether to
re-run the job (a failed install step) or look at the change (a real difference).

## Test data

The tests use made-up values only: the Windows homes of users `User` and `Test`, addresses from
`192.0.2.0/24` and the link-local test address of `Test-LocalHostName`, and placeholder names
and tokens. The privacy rules run with the pack `base`. `.github/standard.conf` exempts these
made-up values and two findings of the rules that are no private data: the folder suffixes
`.local-ai-clone`, `.local-ai-old-venv` and `.local-ai-removing`, and GitHub's support address
in the sign-off of Dependabot's commits. A comment above each exemption says what it covers.

<!-- standard:begin releasing -->
## Releasing

GitHub Actions builds each release, and the maintainer publishes it in the browser.

1. A session opens the release pull request `chore/release-X.Y.Z`, written with
   `.github/standard/bin/release-prepare`: `VERSION`, the `VERSION_COPY` files, and the
   `CHANGELOG.md` section with its links. Its body names the dependency updates since the last
   release. CI checks the version, the date and the links, and the `release` workflow builds the
   release twice to compare.
2. The maintainer reviews and squash-merges it. The push to `main` that changes `VERSION` runs
   the `release` workflow: the checks of `ci` on that commit, the build, an attestation in the
   public repositories, and a draft release `vX.Y.Z` of that commit.
3. The maintainer checks the draft (notes, assets, target commit, image digest) and clicks
   **Publish release**. GitHub creates the tag and the immutable release. The `verify` job then
   checks the published release: look for it to pass.
4. To fix a draft, merge a pull request from `fix/release-X.Y.Z-<slug>`, whose `CHANGELOG.md`
   line goes into `## [X.Y.Z]`, then run the `release` workflow on `main` (Actions, release, Run
   workflow). Merge nothing else until the draft is published: CI says so on every pull request
   while a release waits.
5. Never delete a published release. Tick **Set as a pre-release** on a bad one, which clients
   and updaters then ignore, and ship X.Y.Z+1. For a container image, that edit also moves
   `latest` back.

Sessions prepare release pull requests. They never create a tag, and never publish, edit or
delete a release.
<!-- standard:end releasing -->

In this repository, the session also points the README's *Install from a release* at the new
release in each release pull request: the `install.ps1` one-liner and its script block form name
`releases/download/vX.Y.Z/install.ps1`, so each always gets the same file. `release-prepare`
leaves these two lines to the session. The build runs `ci/release-build.ps1` on Windows, which
builds the zip, `install.ps1` and `SHA256SUMS` with `.github/scripts/LocalAIRelease.psm1`.
Leave v1.0.0 and v1.0.1 as they are: the `verify` job also runs when a release is edited, and
those two releases attest only their zip, so marking one as a pre-release would fail that run.

## Release contract

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
  `TZ=UTC`. The export-ignore lines in `.gitattributes` keep out `.github`, `.githooks`, `ci`,
  `tests`, `.editorconfig`, `.gitattributes`, `.gitignore`, `.gitleaksignore`, `.shellcheckrc`,
  `PSScriptAnalyzerSettings.psd1` and this file. The eol attributes apply: `*.cmd`, `*.ps1`, `*.psm1` and `*.psd1` have CRLF line ends,
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
- A build provenance attestation covers each asset: the zip, `install.ps1` and `SHA256SUMS`.
  `release.yml` of this repository signs them on `refs/heads/main`.
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
