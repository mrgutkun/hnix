{
# For current default and explicitly supported GHCs https://search.nixos.org/packages?query=ghc&from=0&size=500&channel=unstable, Nixpkgs implicitly supports older minor versions also, until the configuration departs from compatibility with them.
# Compiler in a form ghc8101 <- GHC 8.10.1, just remove spaces and dots
  compiler    ? "ghc8104"

# Deafult.nix is a unit package abstraciton that allows to abstract over packages even in monorepos:
# Example: pass --arg cabalName --arg packageRoot "./subprojectDir", or map default.nix over a list of tiples for subprojects.
# cabalName is package resulting name: by default and on error resolves in haskellPackages.developPackage to project root directory name by default, but outside the haskellPackages.developPackage as you see below packageRoot can be different
, cabalName ? "hnix"
, packageRoot ? pkgs.nix-gitignore.gitignoreSource [ ] ./.

# This settings expose most of the Nixpkgs Haskell.lib API: https://github.com/NixOS/nixpkgs/blob/master/pkgs/development/haskell-modules/lib.nix

# Some of these options implicitly enable other options they require, and some counterpoint options clash, obviously

# Don't fail at configure time if there are multiple versions of the same package in the (recursive) dependencies of the package being built. Will delay failures, if any, to compile time.
, allowInconsistentDependencies ? false
# Escape the version bounds from the cabal file. You may want to avoid this function.
, doJailbreak ? false
# Nix dependency checking, compilation and execution of test suites listed in the package description file.
, doCheck     ? true

# Just produce a SDist src tarball
, sdistTarball ? false
# The strict packaging process as used on Hackage. Tests consistency of the Cabal file.
, buildFromSdist ? true
# Allow a shell environment to be requested
, returnShellEnv ? false

# Turn all warn into err with {-Wall,-Werror}
, failOnAllWarnings ? false
# `failOnAllWarnings` + `buildFromSdist`
, buildStrictly ? false

#  2020-06-02: NOTE: enableDeadCodeElimination = true: On GHC =< 8.8.3 macOS build falls due to https://gitlab.haskell.org/ghc/ghc/issues/17283
, enableDeadCodeElimination ? false
# Disabled GHC code optimizations make build/tolling/dev loops faster.
# Works also for Haskel IDE Engine and GHCID.
# Enable optimizations for production use, and to pass benchmarks.
, disableOptimization ? true
# Use faster `gold` ELF linker from GNU binutils instead of older&slower but more versatile GNU linker. Is not available by default since macOS does not have it.
, linkWithGold ? false

# Provide an inventory of performance events and timings for the execution. Provides informaiton in an absolute sense. Nothing is timestamped.
, enableLibraryProfiling ? false
, enableExecutableProfiling ? false
# Include tracing information & abilities. Tracing records the chronology, often with timestamps and is extensive in time
, doTracing   ? false
# Include DWARF debugging information & abilities
, enableDWARFDebugging ? true
# Strip results from all debugging symbols
, doStrip ? false

# Nixpkgs expects shared libraries
, enableSharedLibraries ? true
# Ability to make static libraries
, enableStaticLibraries ? false
# Make hybrid executable that is also a shared library
, enableSharedExecutables ? false
# link executables statically against haskell libs to reduce closure size
, justStaticExecutables ? false
, enableSeparateBinOutput ? false

# checkUnusedPackages: is `failOnAllWarnings` + `cabal sdist` + post-build dep check.
# Currently uses `packunused` or GHC 8.8 internals, later switches into GHC internal feature.
# Adds a post-build check to verify that dependencies declared in the cabal file are actually used.
, checkUnusedPackages ? false
# Generation and installation of haddock API documentation
, doHaddock   ? false
#	Generate hyperlinked source code for documentation using HsColour, and have Haddock documentation link to it.
, doHyperlinkSource ? false
# Generation and installation of a coverage report. See https://wiki.haskell.org/Haskell_program_coverage
, doCoverage  ? false
# doBenchmark: Dependency checking + compilation and execution for benchmarks listed in the package description file.
, doBenchmark ? false
# For binaries named in `executableNamesToShellComplete` list, generate and bundle-into package an automatically loaded shell complettions
, generateOptparseApplicativeCompletions ? false
, executableNamesToShellComplete ? [ "hnix" ]


# Include Hoogle executable and DB into derivation
, withHoogle  ? false


# Nix by default updates and uses locally configured nixpkgs-unstable channel
# Nixpkgs revision options:
#   `rev` vals in order of freshness -> cache & stability:
#   { master
#   , <commitHash>
#   , haskell-updates  # Haskell development branch in Nixpkgs, can be inconsistent. Weekly merged into the upstream
#   , nixpkgs-unstable  # Default branch on Nix installation, default for non NixOS
#   , nixos-unstable  # nixpkgs-unstable that passes a bunch of base tests
#   , nixos-20.03  # Last stable release, gets almost no updates to recipes, gets only required backports
#   ...
#   }
, rev ? "9df2cb074d72ea80ac9fd225b29060c8cf13dd39"

, pkgs ?
    if builtins.compareVersions builtins.nixVersion "2.0" > 0
      then
        if ((rev == "") || (rev == "default") || (rev == "local"))
          then import <nixpkgs> {}
          # Do not guard with hash, so the project is able to use current channels (rolling `rev`) of Nixpkgs
          else import (builtins.fetchTarball "https://github.com/NixOS/nixpkgs/archive/${rev}.tar.gz") {}
        // {
          # Try to build dependencies even if they are marked broken.
          config.allowBroken = true;
        }
      else abort "Requires Nix >= 2.0"

, mkDerivation   ? null
}:

let

  hlib = pkgs.haskell.lib;
  lib = pkgs.lib;

  getDefaultGHC = "ghc${
      (
        # Remove '.' from the string 8.8.4 -> 884
        lib.stringAsChars (c: if c == "." then "" else c)
          # Get default GHC version,
          (lib.getVersion pkgs.haskellPackages.ghc)
      )
    }";

  compilerPackage =
    if ((compiler == "") || (compiler == "default"))
      then getDefaultGHC
      else compiler;

  # Overlay source
  # hnix-store-src = pkgs.fetchFromGitHub {
  #   owner = "haskell-nix";
  #   repo = "hnix-store";
  #   rev = "fd09d29b8bef4904058f033d693e7d928a4a92dc";
  #   sha256 = "0fxig1ckzknm5g19jzg7rrcpz7ssn4iiv9bs9hff9gfy3ciq4zrs";
  # };

  overlay = lib.foldr lib.composeExtensions (_: _: {}) [
    # (import "${hnix-store-src}/overlay.nix" pkgs hlib)
    (self: super:
      lib.optionalAttrs withHoogle {
      ghc = super.ghc // { withPackages = super.ghc.withHoogle; };
      ghcWithPackages = self.ghc.withPackages;
    })
  ];

  overrideHaskellPackages = orig: {
    buildHaskellPackages =
      orig.buildHaskellPackages.override overrideHaskellPackages;
    overrides = if orig ? overrides
      then lib.composeExtensions orig.overrides overlay
      else overlay;
  };

  haskellPackages = pkgs.haskell.packages.${compilerPackage}.override
    overrideHaskellPackages;

  # Application of functions from this list to the package in code here happens in the reverse order (from the tail). Some options depend on & override others, so if enabling options caused Nix error or not expected result - change the order, and please do not change this order without proper testing.
  listSwitchFunc =
    [
      { switch = sdistTarball;                           function = hlib.sdistTarball; }
      { switch = buildFromSdist;                         function = hlib.buildFromSdist; }
      { switch = buildStrictly;                          function = hlib.buildStrictly; }
      { switch = disableOptimization;                    function = hlib.disableOptimization; }
      { switch = doJailbreak;                            function = hlib.doJailBreak; }
      { switch = doStrip;                                function = hlib.doStrip; }
      { switch = enableDWARFDebugging;                   function = hlib.enableDWARFDebugging; }
      { switch = linkWithGold;                           function = hlib.linkWithGold; }
      { switch = failOnAllWarnings;                      function = hlib.failOnAllWarnings; }
      { switch = justStaticExecutables;                  function = hlib.justStaticExecutables; }
      { switch = checkUnusedPackages;                    function = hlib.checkUnusedPackages {}; }
      { switch = generateOptparseApplicativeCompletions; function = hlib.generateOptparseApplicativeCompletions executableNamesToShellComplete; }
      { switch = doHyperlinkSource;                      function = hlib.doHyperlinkSource; }
    ];

  # Function that applies enabled option to the package, used in the fold.
  onSwitchApplyFunc = set: object:
    if set.switch
      then set.function object
      else object;

  # General description of package
  package = haskellPackages.developPackage {
    name = cabalName;
    # Do not include into closure the files listed in .gitignore
    root = packageRoot;

    overrides = self: super: {

      semialign = super.semialign_1_2;
      relude = super.relude_1_0_0_1;

    };

    modifier = drv: hlib.overrideCabal drv (attrs: {
      buildTools = (attrs.buildTools or []) ++ [
        haskellPackages.cabal-install
      ];

      testHaskellDepends = attrs.testHaskellDepends ++ [
        pkgs.nix
        haskellPackages.criterion
      ];

      # Declare that the header set arguments as according Haskell.lib switches
      inherit allowInconsistentDependencies;
      inherit doCheck;
      inherit enableDeadCodeElimination;
      inherit enableLibraryProfiling;
      inherit enableExecutableProfiling;
      inherit enableSharedLibraries;
      inherit enableStaticLibraries;
      inherit enableSharedExecutables;
      inherit enableSeparateBinOutput;
      inherit doBenchmark;
      inherit doCoverage;
      inherit doHaddock;

      configureFlags = lib.optional doTracing  "--flags=tracing";

      passthru = {
        nixpkgs = pkgs;
        inherit haskellPackages;
      };
    });

    inherit returnShellEnv;
  };

  # One part of Haskell.lib options are argument switches, those are in `inherit`ed list.
  # Other part - are function wrappers over pkg. Fold allows to compose those.
  # composePackage = foldr (if switch then function) (package) ([{switch,function}]) == (functionN .. (function1 package))
  composedPackage = lib.foldr (onSwitchApplyFunc) package listSwitchFunc;

in composedPackage

