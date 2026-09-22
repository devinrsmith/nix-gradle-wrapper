# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single reusable Nix function, `gradle-wrapper.nix`, that makes a Gradle-wrapper-based project's
dev shell (devenv.sh, plain `nix develop`, or anything else that can splice a `shellHook` string
and a `packages` list) work offline and deterministically:

- Vendors the exact Gradle distribution a project's own `gradle/wrapper/gradle-wrapper.properties`
  pins into the Nix store, and pre-seeds `./gradlew`'s on-disk wrapper cache with it, so a fresh
  shell never needs network access just to run `./gradlew`.
- Isolates Gradle toolchain resolution to whatever JDK(s) the calling shell provides, via a
  project-local, symlink-backed `GRADLE_USER_HOME` whose own `gradle.properties` disables Gradle's
  host-JDK auto-detection/auto-download.
- Sets a memory-aware `org.gradle.workers.max`, computed from total system memory at shell entry.

It was extracted from a project-specific `nix/gradle-wrapper.nix` and generalized (parameterized
`name`/memory assumptions instead of hardcoding them to that one project) so other Gradle-wrapper
projects can reuse it.

**This repo is deliberately not a "real" flake from a consumer's perspective.** `gradle-wrapper.nix`
takes `pkgs` as an argument rather than pinning its own nixpkgs, specifically so a consumer's own
nixpkgs is used and no second nixpkgs pin gets forced into their lock file. Consumers pull this
repo in as a **non-flake** input (`flake: false` in devenv.yaml, or `flake = false` on a raw flake
input) and `import "${input}/gradle-wrapper.nix" { ... }` directly — see README.md's "Usage"
section for both the devenv.yaml and plain-flake worked examples. `flake.nix`/`flake.lock` at the
repo root exist *only* for this repo's own tests below; they are never evaluated by a consumer that
follows the documented `flake: false` pattern.

## Commands

```bash
nix flake check                    # run both test layers (unit + integration)
nix-build --expr 'import ./tests/unit.nix { pkgs = import <nixpkgs> {}; }'
nix-build --expr 'import ./tests/integration.nix { pkgs = import <nixpkgs> {}; self = ./.; }'

nix-instantiate --parse gradle-wrapper.nix   # quick syntax check
```

There is no build/lint step beyond the tests themselves — this is a single `.nix` file, not a
package with its own compile step.

## Architecture

- **`gradle-wrapper.nix`** — the entire implementation, a single `{ pkgs, wrapperPropertiesFile,
  name, perWorkerMemBytes ?, daemonMemBytes ?, otherMemBytes ?, extraJdkHomes ? }: { ... }`
  function. Internally it does two independent things that are both worth understanding before
  editing either:
  1. **Distribution vendoring** (`distExtracted`, `warmupHook`): reads `distributionUrl`/
     `distributionSha256Sum` out of the consumer's `gradle-wrapper.properties` (the single source
     of truth — never duplicated), fetches+unpacks that exact zip via `pkgs.fetchurl` +
     `pkgs.runCommand`, and at shell-entry time symlinks the unpacked result into
     `$GRADLE_USER_HOME/wrapper/dists/<zipBase>/<hash>/<dirName>` — the same on-disk layout
     `./gradlew` itself expects (`org.gradle.wrapper.PathAssembler`'s undocumented scheme; `<hash>`
     is `base36(md5(distributionUrl))`, computed with Nix's builtin MD5 hasher at eval time and
     converted to base36 via `bc` at shell-hook runtime, since Nix's own integers are too narrow
     for a 128-bit hash). If a future Gradle wrapper version changes that layout, this degrades
     gracefully — `./gradlew` just falls back to its normal download.
  2. **Toolchain isolation** (`isolatedHomeHook`): redirects `GRADLE_USER_HOME` to an isolated,
     namespaced (`$XDG_CACHE_HOME/<name>-nix-gradle-home`), symlink-backed directory that mirrors
     everything from the real `~/.gradle` *except* `gradle.properties` — so caches/daemon/etc.
     aren't duplicated, but the toolchain settings are shell-local. It writes that isolated
     `gradle.properties` with `org.gradle.welcome=never` (suppresses Gradle's one-time "Welcome to
     Gradle" banner, which would otherwise reappear on every fresh isolated home rather than
     showing once per machine, since `GRADLE_USER_HOME` here is per-project, not the real
     persistent `~/.gradle`), `org.gradle.java.installations.auto-detect=false`, and
     `...auto-download=false` (confirmed empirically: these only take effect as a Gradle project
     property / `gradle.properties` file, not `GRADLE_OPTS`/`ORG_GRADLE_PROJECT_*` env vars). When
     `extraJdkHomes` is non-empty, also writes `org.gradle.java.installations.paths` as those paths
     comma-joined — honored even with auto-detect/auto-download disabled (unlike the two settings
     above, this one is resolved entirely at Nix eval time, not shell-hook runtime, since the list
     is already known then; no bash-side list handling needed). Resolving a JDK *package* to the
     path this option needs (Darwin's nixpkgs `temurin-bin` etc. need `${pkg.bundle}/Contents/Home`,
     not the top-level symlink-farm `.home`) is deliberately left to the caller — see README.md's
     "Multiple JDKs" section — rather than duplicated here as nixpkgs-Darwin-layout-specific logic.
     Plus a computed `org.gradle.workers.max` (total memory, minus `daemonMemBytes` and
     `otherMemBytes`, divided by `perWorkerMemBytes`; best-effort across Linux `/proc/meminfo` and macOS `sysctl
     hw.memsize`, silently skipped if memory can't be determined).
  - `distUrl`/`distSha256`/`zipBase`/`dirName` are also exposed from the function, mainly so
    `tests/unit.nix` has something to assert on without ever building `distExtracted`.
- **`tests/unit.nix`** — pure eval-level tests over the parsing/unescaping/path-derivation logic
  (colon-unescaping, `-all`/`-bin` suffix stripping, mirror URLs with ports, nested paths) and over
  `extraJdkHomes`' string-level effect on `isolatedHomeHook` (omitted when empty, comma-joined when
  not). Runs with fake, never-fetched URLs and a placeholder sha256, since `pkgs.fetchurl` only
  touches the network/verifies the hash when its derivation is actually *built*, not when merely
  constructed during eval — so no fixture files or builds are needed here at all. A `throw` with a
  diff-style report fails the check if any case doesn't match; otherwise returns a trivial
  `runCommand` derivation so `nix flake check` has something to build.
- **`tests/integration.nix`** — the one layer that does a real build: fetches
  `tests/fixtures/fake-gradle-9.9.9-bin.zip` (a tiny, committed stand-in "Gradle distribution", not
  a real one) via a `file://` URL, then actually *runs* `isolatedHomeHook` + `warmupHook` inside a
  sandboxed `runCommand` with a fake `$HOME`/`$XDG_CACHE_HOME`, and asserts the resulting
  `GRADLE_USER_HOME`, `gradle.properties` contents (including `installations.paths` against two
  real throwaway fixture directories passed as `extraJdkHomes`), and wrapper-cache directory layout
  are exactly what a real `./gradlew` would look for. Notably references the fixture zip via
  `"${self}/..."` (the whole flake source, already one store copy) rather than a fresh
  `${./relative/path}` interpolation — the latter would re-add the file to the store as
  `<hash>-<basename>`, corrupting `zipBase`/`dirName`'s parsing of the URL's last path segment.
  - **Not covered by either test layer**: an actual `./gradlew` invocation proving it finds the
    vendored distribution and skips its own download. That needs a real JDK + Gradle wrapper
    script + project and is treated as a manual/downstream smoke test instead (see README.md's
    Testing section).
- **`flake.nix`/`flake.lock`** — dev-only, wires both test files into `checks.<system>.{unit,integration}`
  for `nix flake check`. Not part of the public interface — see the "What this is" section above.
