# Pure eval-level tests of gradle-wrapper.nix's URL/properties parsing --
# no build, no network, no fixture files needed, since pkgs.fetchurl only
# touches the network when its derivation is actually *realized*, not when
# it's merely constructed during eval. Run via `nix flake check` (wired up
# as the `unit` check in ../flake.nix) or directly:
#   nix-build --expr 'import ./tests/unit.nix { pkgs = import <nixpkgs> {}; }'
{ pkgs }:
let
  lib = pkgs.lib;
  mkGradleWrapper = import ../gradle-wrapper.nix;

  # A syntactically-plausible-but-fake sha256 -- never actually verified,
  # since these tests never build distExtracted, only inspect the eval-time
  # attrs derived from wrapperPropertiesFile.
  fakeSha256 = "0000000000000000000000000000000000000000000000000000000000000000";

  fixture = distributionUrl: pkgs.writeText "gradle-wrapper.properties" ''
    distributionBase=GRADLE_USER_HOME
    distributionPath=wrapper/dists
    distributionUrl=${distributionUrl}
    distributionSha256Sum=${fakeSha256}
    zipStoreBase=GRADLE_USER_HOME
    zipStorePath=wrapper/dists
  '';

  gw = distributionUrl: mkGradleWrapper {
    inherit pkgs;
    wrapperPropertiesFile = fixture distributionUrl;
    name = "unit-test";
  };

  cases = {
    "unescapes the colon in a standard services.gradle.org URL" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-9.7.1-all.zip").distUrl;
      expected = "https://services.gradle.org/distributions/gradle-9.7.1-all.zip";
    };

    "unescapes the colon in a custom mirror URL with a port" = {
      expr = (gw "https\\://mirror.example.com\\:8443/gradle/gradle-8.5-bin.zip").distUrl;
      expected = "https://mirror.example.com:8443/gradle/gradle-8.5-bin.zip";
    };

    "strips -all.zip to get zipBase" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-9.7.1-all.zip").zipBase;
      expected = "gradle-9.7.1-all";
    };

    "strips -bin.zip to get zipBase" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-8.5-bin.zip").zipBase;
      expected = "gradle-8.5-bin";
    };

    "strips the -all suffix to get dirName" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-9.7.1-all.zip").dirName;
      expected = "gradle-9.7.1";
    };

    "strips the -bin suffix to get dirName" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-8.5-bin.zip").dirName;
      expected = "gradle-8.5";
    };

    "derives distExtracted's name from dirName" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-9.7.1-all.zip").distExtracted.name;
      expected = "gradle-dist-gradle-9.7.1";
    };

    "only the last path segment matters, not the full URL" = {
      expr = (gw "https\\://internal-mirror.example.com/nested/path/with/many/segments/gradle-7.6.4-bin.zip").dirName;
      expected = "gradle-7.6.4";
    };

    "distSha256 is read through unmodified" = {
      expr = (gw "https\\://services.gradle.org/distributions/gradle-9.7.1-all.zip").distSha256;
      expected = fakeSha256;
    };
  };

  results = lib.mapAttrsToList
    (name: c: {
      inherit name;
      ok = c.expr == c.expected;
      got = c.expr;
      expected = c.expected;
    })
    cases;
  failures = builtins.filter (r: !r.ok) results;

  report = lib.concatMapStringsSep "\n"
    (f: "  FAIL: ${f.name}\n    got:      ${builtins.toJSON f.got}\n    expected: ${builtins.toJSON f.expected}")
    failures;
in
if failures != [ ]
then throw "nix-gradle-wrapper unit tests: ${toString (builtins.length failures)}/${toString (builtins.length results)} failed:\n${report}"
else pkgs.runCommand "nix-gradle-wrapper-unit-tests" { } ''
  echo "nix-gradle-wrapper unit tests: all ${toString (builtins.length results)} passed"
  touch $out
''
