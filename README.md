# nix-gradle-wrapper

A reusable Nix function that makes a Gradle-wrapper-based project's dev shell
(devenv.sh, plain `nix develop`, or anything else that can splice a
`shellHook` string and a `packages` list) work offline and deterministically:

- **Vendors the exact Gradle distribution** the project's own
  `gradle/wrapper/gradle-wrapper.properties` pins, straight into the Nix
  store, and pre-seeds `./gradlew`'s on-disk wrapper cache with it -- so a
  fresh shell never needs network access just to run `./gradlew`.
- **Isolates Gradle toolchain resolution** to whatever JDK(s) the calling
  shell provides, by pointing `GRADLE_USER_HOME` at a project-local,
  symlink-backed directory whose own `gradle.properties` disables Gradle's
  own host-JDK auto-detection/auto-download. Nothing else under the real
  `~/.gradle` is duplicated or re-downloaded -- only the settings file
  differs, and only for the duration of the shell.
- **Sets a memory-aware `org.gradle.workers.max`**, computed from total
  system memory at shell entry (Linux `/proc/meminfo`, macOS `sysctl
  hw.memsize`) rather than Gradle's own CPU-core-based default, which can
  OOM a machine with many cores but modest memory
  (see [gradle/gradle#14431](https://github.com/gradle/gradle/issues/14431)).
- **Suppresses Gradle's one-time "Welcome to Gradle" banner**
  (`org.gradle.welcome=never`) -- since `GRADLE_USER_HOME` is isolated
  per-project rather than a real, persistent `~/.gradle`, that banner would
  otherwise reappear on every fresh isolated home instead of showing only
  once per machine.

Extracted from a project-specific `nix/gradle-wrapper.nix` and generalized
(parameterized what was previously hardcoded to one project's own naming
and memory assumptions) so any Gradle-wrapper project can use it.

## What this is *not*

- Not a Gradle toolchain provisioner. It doesn't pick or install JDKs for
  you -- it only isolates *which* already-on-PATH JDK(s) Gradle is allowed
  to see. Pair it with your own `languages.java`/JDK package declaration.
- Not devenv-specific. `gradle-wrapper.nix` is a plain
  `{ pkgs, wrapperPropertiesFile, name, ... }: { ... }` function; the
  `warmupHook`/`isolatedHomeHook` strings it returns are just bash to splice
  into whatever `shellHook`/`enterShell` mechanism your dev-shell tooling
  uses.

## Usage

### From a devenv.yaml-based project (devenv.sh)

Add it as a non-flake input (`flake: false` -- this repo has no `flake.nix`,
just the plain function file above):

```yaml
# devenv.yaml
inputs:
  nix-gradle-wrapper:
    url: github:devinrsmith/nix-gradle-wrapper
    flake: false
```

Then, in `devenv.nix`:

```nix
{ pkgs, inputs, ... }:
let
  gradleWrapper = import "${inputs.nix-gradle-wrapper}/gradle-wrapper.nix" {
    inherit pkgs;
    wrapperPropertiesFile = ./gradle/wrapper/gradle-wrapper.properties;
    name = "my-project"; # namespaces the isolated GRADLE_USER_HOME
    # perWorkerMemBytes = 6 * 1024 * 1024 * 1024; # optional, see below
  };
in
{
  languages.java.enable = true; # pick your own JDK package here

  packages = gradleWrapper.extraBuildInputs;

  enterShell = gradleWrapper.isolatedHomeHook + gradleWrapper.warmupHook + ''
    echo "my-project dev shell ready"
  '';
}
```

### From a plain flake (`nix develop`)

```nix
{
  inputs.nix-gradle-wrapper = {
    url = "github:devinrsmith/nix-gradle-wrapper";
    flake = false;
  };

  outputs = { self, nixpkgs, nix-gradle-wrapper }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      gradleWrapper = import "${nix-gradle-wrapper}/gradle-wrapper.nix" {
        inherit pkgs;
        wrapperPropertiesFile = ./gradle/wrapper/gradle-wrapper.properties;
        name = "my-project";
      };
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        buildInputs = gradleWrapper.extraBuildInputs;
        shellHook = gradleWrapper.isolatedHomeHook + gradleWrapper.warmupHook;
      };
    };
}
```

## Parameters

| Parameter | Required | Default | Meaning |
|---|---|---|---|
| `pkgs` | yes | -- | A nixpkgs instance (needs `unzip`, `bc`, `fetchurl`, `runCommand`). |
| `wrapperPropertiesFile` | yes | -- | Path to the consuming project's `gradle/wrapper/gradle-wrapper.properties`. Read as the single source of truth for which Gradle distribution to vendor. |
| `name` | yes | -- | Short, filesystem-safe project identifier. Namespaces the isolated `GRADLE_USER_HOME` (`$XDG_CACHE_HOME/<name>-nix-gradle-home`) so multiple projects' shells on one machine don't collide, and appears in the generated `gradle.properties` banner comment. |
| `perWorkerMemBytes` | no | 4 GiB | Assumed worst-case heap for a single Gradle worker -- should match the consuming project's largest `-Xmx`-style setting for accurate `org.gradle.workers.max` sizing. |
| `daemonMemBytes` | no | 1 GiB | Memory reserved for the Gradle daemon itself when computing `workers.max`. |
| `otherMemBytes` | no | 2 GiB | Memory reserved for everything else running on the machine when computing `workers.max`. |

## Outputs

| Output | Type | Meaning |
|---|---|---|
| `distExtracted` | derivation | The unpacked Gradle distribution. Rarely needed directly -- `warmupHook` already wires it up. |
| `warmupHook` | string (bash) | Pre-seeds `./gradlew`'s on-disk wrapper cache with `distExtracted`, so it's found instead of downloaded. |
| `isolatedHomeHook` | string (bash) | Redirects `GRADLE_USER_HOME` to an isolated, symlink-backed directory and writes its `gradle.properties` (toolchain isolation + `workers.max`). Run this *before* `warmupHook` -- the warmup writes into whatever `GRADLE_USER_HOME` is current at that point. |
| `extraBuildInputs` | list of derivations | Packages the hooks above need on `PATH` (currently just `bc`, for the warmup hook's base36 conversion). |
| `distUrl` | string | The resolved (unescaped) `distributionUrl`. Mainly for introspection/debugging and unit tests. |
| `distSha256` | string | The `distributionSha256Sum` as read from `wrapperPropertiesFile`. |
| `zipBase`, `dirName` | strings | The wrapper cache path components derived from `distUrl` (see `distExtracted`'s caveat above). Mainly for unit tests. |

## Testing

This repo carries its own dev-only `flake.nix` purely to run its tests via
`nix flake check` -- it doesn't change how consumers use
`gradle-wrapper.nix` (see "Usage" above: they pull this repo in with
`flake = false`, which never evaluates `flake.nix` or its inputs at all).

```bash
nix flake check           # runs both layers below
```

- **`tests/unit.nix`** -- pure eval-level tests of the
  `gradle-wrapper.properties` parsing/URL-unescaping/path-derivation logic
  against fixture properties text. No build, no network, no fixture files:
  `pkgs.fetchurl` only touches the network when its derivation is actually
  realized, not when it's merely constructed during eval, so these just
  inspect the resulting `distUrl`/`zipBase`/`dirName`/`distExtracted.name`
  attrs.
- **`tests/integration.nix`** -- builds `distExtracted` for real against a
  tiny committed fixture zip (`tests/fixtures/fake-gradle-9.9.9-bin.zip`,
  not an actual multi-hundred-MB Gradle distribution) served via a `file://`
  URL, then actually *runs* `isolatedHomeHook` + `warmupHook` in a
  sandboxed fake `$HOME`/`$XDG_CACHE_HOME` and asserts the resulting
  `GRADLE_USER_HOME`, `gradle.properties`, and wrapper-cache directory
  layout are exactly what a real `./gradlew` would look for.

**Not covered**: an actual `./gradlew` invocation proving it finds the
vendored distribution and skips its own download. That needs a real
JDK + Gradle wrapper script + project, which is out of scope for a fast
`nix flake check` -- treat it as a manual/downstream smoke test against a
real consuming project's checkout instead.

## Caveats (inherited from the original, unchanged by generalizing it)

- Gradle's wrapper on-disk layout
  (`$GRADLE_USER_HOME/wrapper/dists/<zipBase>/<hash>/<dirName>`, where
  `<hash>` is `base36(md5(distributionUrl))`) is an internal, undocumented
  detail of `org.gradle.wrapper.PathAssembler`. If a future Gradle wrapper
  version changes that scheme, this degrades gracefully: the pre-seeded
  cache dir just won't be found, and `./gradlew` falls back to its normal
  download -- it doesn't break the build.
- Toolchain isolation (`auto-detect=false`/`auto-download=false`) means a
  build step that deliberately wants a *different* JDK than what the shell
  provides (e.g. a project's own multi-JDK CI matrix) will fail with "no
  matching toolchain found" inside this shell. Pass
  `-Porg.gradle.java.installations.auto-download=true` on the command line
  to override that locally when you need to reproduce such a step.
- These settings are written to a Gradle *project property* file
  (`gradle.properties`), not a JVM system property -- confirmed empirically
  that neither `GRADLE_OPTS=-D...` nor `ORG_GRADLE_PROJECT_<key>` env vars
  are honored for them.
