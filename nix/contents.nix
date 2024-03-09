let

  sources = import ./sources.nix;
  defNixpkgs = import sources.nixpkgs { };
  nix-filter = import sources.nix-filter;

in { nixpkgs ? defNixpkgs }:

let
  inherit (nixpkgs.lib.attrsets) getAttrFromPath mapAttrs;

  # Lists all packages made available through this nix project.
  # The format is `{ <pkgName> : <pkgDir> }` (we refer to this as pInfo).
  # The used directory should be the path of the directory relative to the root
  # of the project.
  pkgList = {
    tmp-postgres = nix-filter {
      root = ../.;
      include = with nix-filter; [
        "tmp-postgres.cabal"
        "LICENSE"
        (and "profiling" (or_ (matchExt "hs") isDirectory))
        (and "resource-soak-test" (or_ (matchExt "hs") isDirectory))
        (and "src" (or_ (matchExt "hs") isDirectory))
        (and "test" (or_ (matchExt "hs") isDirectory))
      ];
    };
  };

in {
  inherit pkgList;

  # Get an attribute from a string path from a larger attrSet
  getPkg = pkgs: pPath: getAttrFromPath [pPath] pkgs;

  overrides = selfh: superh:
    let
      callCabalOn = name: dir:
        selfh.callCabal2nix "${name}" dir { };

    in mapAttrs callCabalOn pkgList;

  # Tests are run during the build, and they require some setup:
  # - Here we make sure that initdb can create a PostgreSQL cluster in its
  #   home directory (which is normally set to /homeless-shelter).
  # - That TMP is /tmp (and not /build).
  # - That the tests can run procps and things like initdb.
  testOverrides = self: superh: {
    tmp-postgres = nixpkgs.haskell.lib.overrideCabal superh.tmp-postgres (drv: {
      preBuild = ''
        export HOME=$TEMPDIR
        export TMP=/tmp
      '' + (drv.preBuild or "");
      # procps is necessary for the tests, while the postgresql binaries are
      # necessary for both the tests and for normal operations. This means
      # that we could specify postgresql_11 in libraryToolDepends, but users
      # of this package might want a different version.
      # In particular, all the tests pass with PostgreSQL 14, except the one
      # called "can support backup and restore", which uses a recovery.conf
      # file. Such a file is no longer supported in version 12 and above.
      testToolDepends = drv.testToolDepends or [] ++ [nixpkgs.buildPackages.postgresql_11 nixpkgs.procps];
    });
  };
}
