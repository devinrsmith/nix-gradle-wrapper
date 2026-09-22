# Vendors the Gradle distribution a project's own gradle-wrapper.properties
# pins, and isolates Gradle's toolchain resolution to whatever the calling
# Nix shell provides. Framework-agnostic (a plain `{ pkgs, ... }` function,
# no devenv-specific coupling) -- works from a devenv.nix shellHook, a plain
# `nix develop` shell, or anywhere else that can splice a shellHook string
# and a `packages` list.
#
# Usage (devenv.nix or a flake's `mkShell`):
#   gradleWrapper = import ./path/to/gradle-wrapper.nix {
#     inherit pkgs;
#     wrapperPropertiesFile = ./gradle/wrapper/gradle-wrapper.properties;
#   };
#   # ... then splice gradleWrapper.isolatedHomeHook + gradleWrapper.warmupHook
#   # into enterShell/shellHook, and gradleWrapper.extraBuildInputs into
#   # packages/nativeBuildInputs.
#
# Returns:
#   distExtracted     -- derivation: the unpacked Gradle distribution
#   warmupHook        -- shellHook fragment: pre-seeds ./gradlew's cache
#   isolatedHomeHook  -- shellHook fragment: isolates GRADLE_USER_HOME,
#                        disables toolchain auto-detect/auto-download, and
#                        sets a memory-aware org.gradle.workers.max
#   extraBuildInputs  -- packages the two hooks above need on PATH (bc)
#   distUrl           -- string: the resolved (unescaped) distributionUrl,
#                        for introspection/debugging and unit tests
#   distSha256        -- string: the distributionSha256Sum as read
#   zipBase, dirName  -- strings: the wrapper cache path components derived
#                        from distUrl (see distExtracted below); exposed
#                        mainly for unit tests
{ pkgs
, wrapperPropertiesFile
# A short, filesystem-safe identifier for the consuming project (used to
# namespace the isolated GRADLE_USER_HOME directory so multiple projects'
# shells on the same machine don't collide, and in the generated
# gradle.properties banner comment). Required -- there's no sane shared
# default across consumers.
, name
# Per-worker heap Gradle's org.gradle.workers.max sizing assumes (bytes).
# Should match whatever the consuming project's largest single-worker
# heap setting actually is (e.g. a build.gradle -Xmx) -- this file has no
# way to discover that on its own. Defaults to 4 GiB, a middle-of-the-road
# guess; override per-project for accuracy.
, perWorkerMemBytes ? 4 * 1024 * 1024 * 1024
# Memory reserved for the Gradle daemon itself and for other
# system/process headroom, before dividing the remainder by
# perWorkerMemBytes. Defaults match Gradle's own daemon default heap (1
# GiB) and a conservative 2 GiB for everything else running on the
# machine.
, daemonMemBytes ? 1 * 1024 * 1024 * 1024
, otherMemBytes ? 2 * 1024 * 1024 * 1024
}:
let
  # ---- Vendor the Gradle wrapper's distribution ------------------------
  #
  # `./gradlew` downloads its own Gradle distribution on first run --
  # normally a good thing (Gradle's own toolchain auto-provisioning,
  # org.gradle.toolchains.foojay-resolver-convention, already handles
  # per-subproject JDKs the same way, so there's no need to duplicate that
  # in Nix) -- but it means a fresh shell still needs network access for
  # that one download. Since the exact version and checksum are already
  # pinned in gradle-wrapper.properties, we can fetch and unpack that same
  # file as a Nix derivation (reusing its checksum, not a new trust
  # decision) and pre-seed the wrapper's on-disk cache, so `./gradlew`
  # finds it already there and skips the download.
  # gradle-wrapper.properties stays the single source of truth -- read
  # here, never duplicated -- so a version bump there just changes what
  # gets fetched, with nothing to keep in sync by hand.
  wrapperProps = pkgs.lib.splitString "\n" (builtins.readFile wrapperPropertiesFile);
  wrapperProp = key:
    let
      prefix = key + "=";
      matches = builtins.filter (pkgs.lib.hasPrefix prefix) wrapperProps;
    in
    pkgs.lib.removePrefix prefix (builtins.head matches);

  # Java .properties escapes ":" as "\:" -- unescape it back to a URL.
  distUrl = builtins.replaceStrings [ "\\:" ] [ ":" ] (wrapperProp "distributionUrl");
  distSha256 = wrapperProp "distributionSha256Sum";

  # ".../gradle-9.7.1-all.zip" -> zipBase "gradle-9.7.1-all", dirName "gradle-9.7.1"
  zipBase = pkgs.lib.removeSuffix ".zip" (pkgs.lib.last (pkgs.lib.splitString "/" distUrl));
  dirName = pkgs.lib.removeSuffix "-bin" (pkgs.lib.removeSuffix "-all" zipBase);

  distZip = pkgs.fetchurl {
    url = distUrl;
    sha256 = distSha256;
  };

  # The wrapper's on-disk layout is $GRADLE_USER_HOME/wrapper/dists/
  # <zipBase>/<hash>/<dirName>, where <hash> is base36(md5(distributionUrl))
  # -- an internal, undocumented detail of Gradle's wrapper
  # (org.gradle.wrapper.PathAssembler), confirmed empirically against a
  # real `./gradlew` run rather than assumed. If a future Gradle wrapper
  # version changes that scheme, this degrades gracefully: the pre-seeded
  # cache dir just won't be found, and `./gradlew` falls back to its
  # normal download.
  distExtracted = pkgs.runCommand "gradle-dist-${dirName}"
    { nativeBuildInputs = [ pkgs.unzip ]; }
    ''
      unzip -q ${distZip} -d "$TMPDIR/unpacked"
      mv "$TMPDIR/unpacked/${dirName}" "$out"
    '';

  # Only the base36-of-MD5 conversion happens at shell-hook runtime (via bc
  # -- Nix's own integers are too narrow for a 128-bit hash); the MD5
  # itself is computed at eval time with Nix's builtin hasher.
  distMd5Hex = builtins.hashString "md5" distUrl;

  warmupHook = ''
    _gradle_home="''${GRADLE_USER_HOME:-$HOME/.gradle}"
    _gradle_hash_hex=$(printf '%s' "${distMd5Hex}" | tr 'a-f' 'A-F')
    _gradle_hash_digits=$(BC_LINE_LENGTH=0 bc <<< "obase=36; ibase=16; $_gradle_hash_hex")
    _gradle_hash_dir=""
    _gradle_b36chars='0123456789abcdefghijklmnopqrstuvwxyz'
    for _d in $_gradle_hash_digits; do
      _gradle_hash_dir="''${_gradle_hash_dir}''${_gradle_b36chars:$((10#$_d)):1}"
    done
    _gradle_dist_dir="$_gradle_home/wrapper/dists/${zipBase}/$_gradle_hash_dir"
    if [[ ! -e "$_gradle_dist_dir/${zipBase}.zip.ok" ]]; then
      mkdir -p "$_gradle_dist_dir"
      ln -sfn "${distExtracted}" "$_gradle_dist_dir/${dirName}"
      touch "$_gradle_dist_dir/${zipBase}.zip.ok"
    fi
    unset _gradle_home _gradle_hash_hex _gradle_hash_digits _gradle_hash_dir _gradle_b36chars _gradle_dist_dir _d
  '';

  # ---- Isolate toolchain resolution from host-installed JDKs ------------
  #
  # Gradle's toolchain auto-detection scans common host locations
  # (/usr/lib/jvm, etc.) in addition to whatever's actually running the
  # build, so `./gradlew javaToolchains` sees both the Nix-provided JDK(s)
  # *and* any host-installed ones. `org.gradle.java.installations.auto-detect=false`
  # turns off that scanning, and `...auto-download=false` also stops
  # Gradle from downloading a toolchain it can't find -- so whatever JDK(s)
  # this shell put on PATH are the *only* ones available. Anything that
  # requests another version than what's on PATH will fail with "no
  # matching toolchain found" here rather than silently downloading one;
  # re-run with -Porg.gradle.java.installations.auto-download=true if you
  # need to reproduce that locally.
  #
  # Confirmed empirically (against a real project's `javaToolchains` task)
  # that these must be set as a Gradle *project property* (gradle.properties
  # / -P), not a JVM system property: neither `GRADLE_OPTS=-D...` nor the
  # `ORG_GRADLE_PROJECT_<dotted.key>` env var convention are honored for
  # these keys, only an actual gradle.properties file or `-P`/`-D` passed
  # directly on the command line.
  #
  # The consuming project's own (committed, shared) ./gradle.properties
  # isn't the place for this -- it'd apply to every contributor and CI,
  # not just Nix shell users. Gradle's *per-user*
  # $GRADLE_USER_HOME/gradle.properties would work and stay out of the
  # repo, but since GRADLE_USER_HOME defaults to the same ~/.gradle
  # whether or not you're in this shell, writing there would silently
  # change toolchain behavior for this user's *other* Gradle projects too,
  # and outside this shell. Instead, GRADLE_USER_HOME is pointed at a
  # Nix-shell-only directory holding just our own gradle.properties, with
  # everything else (caches, the vendored wrapper distribution above,
  # daemon, etc.) symlinked back to the real one -- so nothing is
  # duplicated or re-downloaded, only the settings file differs, and only
  # for the duration of this shell.
  #
  # Namespaced by `name` so two different projects' shells on the same
  # machine each get their own isolated GRADLE_USER_HOME rather than
  # silently sharing (and overwriting) one another's gradle.properties.
  isolatedHomeHook = ''
    _gradle_isolated_home="''${XDG_CACHE_HOME:-$HOME/.cache}/${name}-nix-gradle-home"
    _gradle_real_home="''${GRADLE_USER_HOME:-$HOME/.gradle}"
    # If GRADLE_USER_HOME is already our own isolated home -- e.g. a nested
    # shell, or this hook re-running in a shell that inherited an earlier
    # invocation's environment -- treat it as unset rather than using it as
    # the "real" home to mirror. Otherwise _gradle_real_home and
    # _gradle_isolated_home are the same directory, and the `ln -sfn` below
    # creates a symlink pointing at itself (confirmed empirically: "Too
    # many levels of symbolic links" on every subsequent mkdir/ln through
    # it).
    if [[ "$_gradle_real_home" == "$_gradle_isolated_home" ]]; then
      _gradle_real_home="$HOME/.gradle"
    fi
    mkdir -p "$_gradle_real_home" "$_gradle_isolated_home"
    shopt -s nullglob
    # Always share these two -- the large, expensive-to-rebuild ones --
    # even on a from-scratch $_gradle_real_home that doesn't have them yet.
    # The mkdir here matters: on a genuinely fresh $_gradle_real_home (no
    # prior Gradle run ever), $_gradle_real_home/$_d doesn't exist yet, and
    # symlinking to it anyway would leave a *dangling* symlink -- `mkdir -p`
    # refuses to create anything through a dangling symlink component
    # (confirmed empirically), which broke warmupHook's later
    # `mkdir -p .../wrapper/dists/...` with a confusing "No such file or
    # directory" from the `ln -sfn` after it. Creating the real target
    # directory first guarantees the symlink is always valid.
    for _d in caches wrapper; do
      mkdir -p "$_gradle_real_home/$_d"
      ln -sfn "$_gradle_real_home/$_d" "$_gradle_isolated_home/$_d"
    done
    # Mirror whatever else already exists (daemon, jdks, ...), except
    # gradle.properties itself -- that's the one file we deliberately
    # don't want to inherit.
    for _entry in "$_gradle_real_home"/*; do
      _name="$(basename "$_entry")"
      if [[ "$_name" != "gradle.properties" && ! -e "$_gradle_isolated_home/$_name" ]]; then
        ln -sfn "$_entry" "$_gradle_isolated_home/$_name"
      fi
    done
    shopt -u nullglob

    # Memory-aware org.gradle.workers.max: Gradle's own default worker
    # count is CPU-core-based and ignores how much RAM workers actually
    # need, which can OOM a machine with many cores but modest memory (see
    # https://github.com/gradle/gradle/issues/14431). Reserve daemon
    # overhead and other system/process headroom, then divide what's left
    # by the assumed worst-case per-worker heap. Best-effort and
    # platform-portable (Linux via /proc/meminfo, macOS via `sysctl
    # hw.memsize`): if total memory can't be determined, skip setting
    # workers.max entirely and let Gradle's own default apply, rather than
    # fail shell entry over it.
    _gradle_daemon_bytes=${toString daemonMemBytes}
    _gradle_other_bytes=${toString otherMemBytes}
    _gradle_per_worker_bytes=${toString perWorkerMemBytes}
    _gradle_total_bytes=""
    if [[ "$(uname -s)" == "Darwin" ]]; then
      _gradle_total_bytes="$(sysctl -n hw.memsize 2>/dev/null || true)"
    elif [[ -r /proc/meminfo ]]; then
      while read -r _meminfo_key _meminfo_value _meminfo_unit; do
        if [[ "$_meminfo_key" == "MemTotal:" ]]; then
          _gradle_total_bytes=$(( _meminfo_value * 1024 ))
          break
        fi
      done < /proc/meminfo
    fi
    _gradle_workers_max=""
    if [[ "$_gradle_total_bytes" =~ ^[0-9]+$ ]]; then
      _gradle_workers_max=$(( (_gradle_total_bytes - _gradle_daemon_bytes - _gradle_other_bytes) / _gradle_per_worker_bytes ))
      if (( _gradle_workers_max < 1 )); then
        _gradle_workers_max=1
      fi
    fi

    {
      echo "# Auto-generated by ${name}'s Nix shell (nix-gradle-wrapper's"
      echo "# isolatedHomeHook) on every shell entry -- do not edit by hand,"
      echo "# changes are overwritten the next time the shell starts."
      # GRADLE_USER_HOME is isolated per-project (see above) rather than
      # the real, persistent ~/.gradle, so without this Gradle's one-time
      # "Welcome to Gradle N" banner would reappear on every fresh isolated
      # home -- e.g. the first shell entry for a new project using this
      # module, or after clearing $XDG_CACHE_HOME -- instead of showing
      # only once per machine the way it would against a real, persistent
      # GRADLE_USER_HOME.
      echo "org.gradle.welcome=never"
      echo "org.gradle.java.installations.auto-detect=false"
      # Only whatever JDK(s) this shell provides are available as a
      # toolchain -- anything requesting another version will fail with
      # "no matching toolchain found" here rather than downloading one.
      echo "org.gradle.java.installations.auto-download=false"
      if [[ -n "$_gradle_workers_max" ]]; then
        echo "# workers.max = (total_mem_bytes - daemon_bytes - other_bytes) / per_worker_bytes"
        echo "#             = ($_gradle_total_bytes - $_gradle_daemon_bytes - $_gradle_other_bytes) / $_gradle_per_worker_bytes"
        echo "#             = $_gradle_workers_max"
        echo "org.gradle.workers.max=$_gradle_workers_max"
      fi
    } > "$_gradle_isolated_home/gradle.properties"
    export GRADLE_USER_HOME="$_gradle_isolated_home"
    unset _gradle_real_home _gradle_isolated_home _entry _name _d
    unset _gradle_daemon_bytes _gradle_other_bytes _gradle_per_worker_bytes
    unset _gradle_total_bytes _gradle_workers_max
    unset _meminfo_key _meminfo_value _meminfo_unit
  '';
in
{
  inherit distExtracted warmupHook isolatedHomeHook;
  inherit distUrl distSha256 zipBase dirName;
  extraBuildInputs = [ pkgs.bc ];
}
