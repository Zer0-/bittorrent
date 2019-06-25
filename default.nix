{ nixpkgs ? import <nixpkgs> {}, compiler ? "default", doBenchmark ? false }:

let

  inherit (nixpkgs) pkgs;

  intset = pkgs.callPackage ../intset/default.nix {};
  base32-bytestring = pkgs.callPackage ../base32-bytestring/default.nix {};

  f = { mkDerivation, async, attoparsec, base, base16-bytestring
      , base64-bytestring, bencoding
      , bytestring, cereal, cereal-conduit, conduit, conduit-extra
      , containers, convertible, cryptohash, data-default, deepseq
      , directory, entropy, fast-logger, filepath, hashable, hspec
      , http-client, http-conduit, http-types, iproute
      , lens, lifted-async, lifted-base, mmap, monad-control
      , monad-logger, monad-loops, mtl, network, network-uri, old-locale
      , optparse-applicative, pretty, process, PSQueue
      , QuickCheck, quickcheck-instances, random, random-shuffle
      , resourcet, SafeSemaphore, split, split-channel, stdenv, stm
      , temporary, text, time, transformers-base, unordered-containers
      , vector, cabal-install
      , intset
      , base32-bytestring
      }:
      mkDerivation {
        pname = "bittorrent";
        version = "0.0.0.3";
        #sha256 = "155bbqqn33mlavvcm6xfxs4dqij66jfhqxjmrjkyxvzd36yz0ann";
        src = ./.;
        isLibrary = true;
        isExecutable = true;
        libraryHaskellDepends = [
          attoparsec base base16-bytestring base32-bytestring
          base64-bytestring bencoding bytestring cereal
          cereal-conduit conduit conduit-extra containers convertible
          cryptohash data-default deepseq directory entropy fast-logger
          filepath hashable http-client http-conduit http-types intset
          iproute lens lifted-async lifted-base mmap monad-control
          monad-logger mtl network network-uri old-locale pretty PSQueue
          random random-shuffle resourcet SafeSemaphore split split-channel
          stm text time transformers-base unordered-containers vector
        ];
        testHaskellDepends = [
          async base bencoding bytestring cereal conduit conduit-extra
          containers convertible data-default directory filepath hspec
          http-types iproute monad-logger monad-loops mtl network
          optparse-applicative process QuickCheck quickcheck-instances
          resourcet temporary text time cabal-install
        ];
        homepage = "https://github.com/cobit/bittorrent";
        description = "BitTorrent protocol implementation";
        license = stdenv.lib.licenses.bsd3;
        doCheck = false;
      };

  haskellPackages = if compiler == "default"
                       then pkgs.haskellPackages
                       else pkgs.haskell.packages.${compiler};

  variant = if doBenchmark then pkgs.haskell.lib.doBenchmark else pkgs.lib.id;

  drv = variant
    ( haskellPackages.callPackage f
      {
        intset = intset;
        base32-bytestring = base32-bytestring;
      }
    );

in
  #drv

  if pkgs.lib.inNixShell then drv.env else drv
