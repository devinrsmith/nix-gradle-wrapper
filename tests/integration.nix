# Builds distExtracted for real (from a tiny committed fixture zip, not an
# actual multi-hundred-MB Gradle distribution) and actually runs
# isolatedHookHook + warmupHook in a sandboxed fake $HOME/$XDG_CACHE_HOME,
# then asserts the on-disk layout is what a real ./gradlew would look for.
# Run via `nix flake check` (wired up as the `integration` check in
# ../flake.nix) or directly:
#   nix-build --expr 'import ./tests/integration.nix { pkgs = import <nixpkgs> {}; self = ./..; }'
{ pkgs, self }:
let
  # fixtureDirName must match what gradle-wrapper.nix's own zipBase/dirName
  # computation derives from fixtureZipUrl below (strip ".zip", strip
  # "-bin"/"-all") -- see fixtures/fake-gradle-9.9.9-bin.zip's own internal
  # top-level directory, which was built to match.
  fixtureDirName = "fake-gradle-9.9.9";
  fixtureZipRelPath = "tests/fixtures/${fixtureDirName}-bin.zip";

  # Referencing the fixture through `self` (the whole flake source, already
  # one store copy) rather than a fresh `${./relative/path}` interpolation
  # keeps the file's own basename intact -- an individually-interpolated
  # path gets re-added to the store as "<hash>-<basename>", which would
  # corrupt zipBase/dirName's parsing of the URL's last path segment.
  fixtureZipUrl = "${self}/${fixtureZipRelPath}";

  # Computed directly from the committed file's bytes -- pure, no network,
  # no build -- so this never drifts from the actual fixture on disk.
  fixtureSha256 = builtins.hashFile "sha256" (self + "/${fixtureZipRelPath}");

  wrapperPropertiesFile = pkgs.writeText "gradle-wrapper.properties" ''
    distributionUrl=file\://${fixtureZipUrl}
    distributionSha256Sum=${fixtureSha256}
  '';

  testName = "nix-gradle-wrapper-integration-test";

  # Real (empty, fixture-only) directories, standing in for two additional
  # JDK homes a consumer might pass via extraJdkHomes -- exercised for
  # real here (unlike tests/unit.nix's string-level checks) to confirm the
  # written property survives all the way from the Nix-level list into the
  # actual gradle.properties file on disk.
  fixtureJdkA = pkgs.runCommand "fake-jdk-a" { } "mkdir -p $out/bin";
  fixtureJdkB = pkgs.runCommand "fake-jdk-b" { } "mkdir -p $out/bin";

  gradleWrapper = import ../gradle-wrapper.nix {
    inherit pkgs wrapperPropertiesFile;
    name = testName;
    extraJdkHomes = [ "${fixtureJdkA}" "${fixtureJdkB}" ];
  };
in
pkgs.runCommand testName
  {
    nativeBuildInputs = gradleWrapper.extraBuildInputs;
  }
  ''
    set -euo pipefail

    export HOME="$TMPDIR/home"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$HOME" "$XDG_CACHE_HOME"

    ${gradleWrapper.isolatedHomeHook}
    ${gradleWrapper.warmupHook}

    expected_gradle_user_home="$XDG_CACHE_HOME/${testName}-nix-gradle-home"
    if [[ "$GRADLE_USER_HOME" != "$expected_gradle_user_home" ]]; then
      echo "FAIL: GRADLE_USER_HOME=$GRADLE_USER_HOME, expected $expected_gradle_user_home"
      exit 1
    fi

    if [[ ! -f "$GRADLE_USER_HOME/gradle.properties" ]]; then
      echo "FAIL: $GRADLE_USER_HOME/gradle.properties was not written"
      exit 1
    fi
    grep -q '^org.gradle.welcome=never$' "$GRADLE_USER_HOME/gradle.properties" \
      || { echo "FAIL: welcome=never missing from gradle.properties"; exit 1; }
    grep -q '^org.gradle.java.installations.auto-detect=false$' "$GRADLE_USER_HOME/gradle.properties" \
      || { echo "FAIL: auto-detect=false missing from gradle.properties"; exit 1; }
    grep -q '^org.gradle.java.installations.auto-download=false$' "$GRADLE_USER_HOME/gradle.properties" \
      || { echo "FAIL: auto-download=false missing from gradle.properties"; exit 1; }
    grep -q '^org.gradle.java.installations.paths=${fixtureJdkA},${fixtureJdkB}$' "$GRADLE_USER_HOME/gradle.properties" \
      || { echo "FAIL: installations.paths missing/wrong in gradle.properties"; cat "$GRADLE_USER_HOME/gradle.properties"; exit 1; }

    # warmupHook should have pre-seeded the wrapper's on-disk cache in
    # exactly the layout ./gradlew's own PathAssembler looks for:
    # $GRADLE_USER_HOME/wrapper/dists/<zipBase>/<hash>/<dirName>, pointing
    # at the vendored, already-unpacked distribution.
    found=0
    shopt -s nullglob
    for d in "$GRADLE_USER_HOME"/wrapper/dists/${fixtureDirName}-bin/*/${fixtureDirName}; do
      if [[ -d "$d" && -x "$d/bin/gradle" ]]; then
        found=1
      fi
    done
    shopt -u nullglob
    if [[ "$found" != "1" ]]; then
      echo "FAIL: vendored Gradle distribution not found in the wrapper cache"
      echo "contents of \$GRADLE_USER_HOME/wrapper/dists:"
      find "$GRADLE_USER_HOME/wrapper/dists" 2>&1 || true
      exit 1
    fi

    # The "ok" marker file must exist too -- warmupHook checks for it to
    # decide whether to re-seed on a later shell entry.
    marker_found=0
    for m in "$GRADLE_USER_HOME"/wrapper/dists/${fixtureDirName}-bin/*/"${fixtureDirName}-bin.zip.ok"; do
      [[ -f "$m" ]] && marker_found=1
    done
    if [[ "$marker_found" != "1" ]]; then
      echo "FAIL: warmupHook's .ok marker file was not created"
      exit 1
    fi

    echo "nix-gradle-wrapper integration test passed" > $out
  ''
