# Tests for the nix-cache NixOS module and its inclusion in the WSL host configuration.
#
# Scope: Covers the changes introduced in this PR:
#   - modules/nixosModules/config/nix-cache.nix  (the module itself)
#   - modules/hosts/wsl/configuration.nix         (added self.nixosModules.nix-cache)
#
# Strategy: eval-time assertions wrapped in pkgs.runCommand derivations.
# Each check fails the build (via `throw`) if an expectation is not met, so
# `nix flake check` will surface failures without needing a running VM.
{ inputs, self, lib, ... }:
let
  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  # Evaluate a minimal NixOS system that only applies the nix-cache module.
  # stateVersion is required by the NixOS module system.
  mkNixCacheOnlyConfig =
    system:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs self; };
      modules = [
        self.nixosModules.nix-cache
        { system.stateVersion = "25.05"; }
      ];
    };

  # Evaluate the full WSL configuration as declared in
  # modules/hosts/wsl/configuration.nix.  We reference the already-built
  # nixosConfiguration so we do not duplicate the module list here.
  wslConfig = self.nixosConfigurations.wsl;

  expectedSubstituter = "https://cache.itzemoji.com/nix";
  expectedPublicKey = "nix:U22mA6l/Br6W9STnaHWO2LPvUCNVuh1yTEIlTCtjtkg=";

  # ---------------------------------------------------------------------------
  # Assertion helpers (evaluated at Nix eval time; throw = build failure)
  # ---------------------------------------------------------------------------

  # Assert that `list` contains `item`, or throw `msg`.
  assertContains =
    list: item: msg:
    if builtins.elem item list then true else throw msg;

  # Build a trivial derivation whose name encodes the test result.
  # `assertions` is a list whose elements evaluate to `true` or `throw`.
  # builtins.deepSeq forces the entire list strictly before returning the
  # derivation, so a failing assertion aborts the Nix evaluation immediately.
  makeCheck =
    pkgs: name: assertions:
    builtins.deepSeq assertions (
      pkgs.runCommand name { } ''
        echo "All assertions in ${name} passed." > $out
      ''
    );
in
{
  perSystem =
    { pkgs, system, ... }:
    let
      # Eval the isolated nix-cache config for this system.
      nixCacheConfig = mkNixCacheOnlyConfig system;
      isolatedSubstituters = nixCacheConfig.config.nix.settings.substituters;
      isolatedTrustedKeys = nixCacheConfig.config.nix.settings.trusted-public-keys;

      # Obtain settings from the full WSL configuration.
      wslSubstituters = wslConfig.config.nix.settings.substituters;
      wslTrustedKeys = wslConfig.config.nix.settings.trusted-public-keys;
    in
    {
      checks = {

        # ------------------------------------------------------------------
        # Test 1: nix-cache module declares the custom substituter
        # ------------------------------------------------------------------
        nix-cache-module-sets-substituter = makeCheck pkgs "nix-cache-module-sets-substituter" [
          (assertContains isolatedSubstituters expectedSubstituter
            "nix-cache module must set substituters to include '${expectedSubstituter}', got: ${builtins.toJSON isolatedSubstituters}")
        ];

        # ------------------------------------------------------------------
        # Test 2: nix-cache module declares the correct trusted public key
        # ------------------------------------------------------------------
        nix-cache-module-sets-trusted-key = makeCheck pkgs "nix-cache-module-sets-trusted-key" [
          (assertContains isolatedTrustedKeys expectedPublicKey
            "nix-cache module must set trusted-public-keys to include '${expectedPublicKey}', got: ${builtins.toJSON isolatedTrustedKeys}")
        ];

        # ------------------------------------------------------------------
        # Test 3: nix-cache module does not add unexpected substituters
        # ------------------------------------------------------------------
        nix-cache-module-no-unexpected-substituters = makeCheck pkgs "nix-cache-module-no-unexpected-substituters" [
          (
            let
              unexpected = builtins.filter (s: s != expectedSubstituter) isolatedSubstituters;
            in
            if unexpected == [ ] then
              true
            else
              throw "nix-cache module added unexpected substituters: ${builtins.toJSON unexpected}"
          )
        ];

        # ------------------------------------------------------------------
        # Test 4: WSL configuration inherits the nix-cache substituter
        #         (regression guard for the change in this PR)
        # ------------------------------------------------------------------
        wsl-config-includes-nix-cache-substituter = makeCheck pkgs "wsl-config-includes-nix-cache-substituter" [
          (assertContains wslSubstituters expectedSubstituter
            "WSL nixosConfiguration must include the nix-cache substituter '${expectedSubstituter}', got: ${builtins.toJSON wslSubstituters}")
        ];

        # ------------------------------------------------------------------
        # Test 5: WSL configuration inherits the nix-cache trusted public key
        # ------------------------------------------------------------------
        wsl-config-includes-nix-cache-trusted-key = makeCheck pkgs "wsl-config-includes-nix-cache-trusted-key" [
          (assertContains wslTrustedKeys expectedPublicKey
            "WSL nixosConfiguration must include the nix-cache trusted-public-key '${expectedPublicKey}', got: ${builtins.toJSON wslTrustedKeys}")
        ];

        # ------------------------------------------------------------------
        # Test 6: nix-cache module sets non-empty substituters list
        #         (boundary / regression test)
        # ------------------------------------------------------------------
        nix-cache-module-substituters-not-empty = makeCheck pkgs "nix-cache-module-substituters-not-empty" [
          (
            if isolatedSubstituters != [ ] then
              true
            else
              throw "nix-cache module must not produce an empty substituters list"
          )
        ];

        # ------------------------------------------------------------------
        # Test 7: nix-cache module sets non-empty trusted-public-keys list
        #         (boundary / regression test)
        # ------------------------------------------------------------------
        nix-cache-module-trusted-keys-not-empty = makeCheck pkgs "nix-cache-module-trusted-keys-not-empty" [
          (
            if isolatedTrustedKeys != [ ] then
              true
            else
              throw "nix-cache module must not produce an empty trusted-public-keys list"
          )
        ];

        # ------------------------------------------------------------------
        # Test 8: substituter URL is well-formed (starts with https://)
        # ------------------------------------------------------------------
        nix-cache-module-substituter-uses-https = makeCheck pkgs "nix-cache-module-substituter-uses-https" [
          (
            let
              nonHttps = builtins.filter (s: !(lib.hasPrefix "https://" s)) isolatedSubstituters;
            in
            if nonHttps == [ ] then
              true
            else
              throw "nix-cache module substituters must use https://; non-https entries: ${builtins.toJSON nonHttps}"
          )
        ];

      };
    };
}
