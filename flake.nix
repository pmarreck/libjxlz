{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          pname = "libjxlz";
          version = "0.1.0";
        in
        with pkgs;
        {
          packages.default = stdenv.mkDerivation {
            inherit pname version;
            src = ./.;
            nativeBuildInputs = [ zig ]
              ++ lib.optionals (stdenv.isDarwin) [
                darwin.cctools
                apple-sdk
              ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              export XDG_CACHE_HOME=$TMPDIR/cache
              mkdir -p $out
              ${lib.optionalString stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              zig build install -Doptimize=ReleaseFast --prefix $out
            '';
            dontInstall = true;
          };

          checks = {
            build = self.packages.${system}.default;
            test = stdenv.mkDerivation {
              pname = "${pname}-test";
              inherit version;
              src = ./.;
              nativeBuildInputs = [ zig ]
                ++ lib.optionals (stdenv.isDarwin) [
                  darwin.cctools
                  apple-sdk
                ];
              dontConfigure = true;
              dontFixup = true;
              buildPhase = ''
                export HOME=$TMPDIR
                export XDG_CACHE_HOME=$TMPDIR/cache
                ${lib.optionalString stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
                zig build test -Doptimize=Debug
              '';
              installPhase = ''
                mkdir -p $out
                echo "tests passed" > $out/result
              '';
            };
          } // lib.optionalAttrs (stdenv.isLinux && stdenv.hostPlatform.isx86_64) {
            windows-x86_64-cross = stdenv.mkDerivation {
              pname = "${pname}-windows-x86_64-cross";
              inherit version;
              src = ./.;
              nativeBuildInputs = [ bash zig ];
              dontConfigure = true;
              dontFixup = true;
              buildPhase = ''
                export HOME=$TMPDIR
                export XDG_CACHE_HOME=$TMPDIR/cache
                bash tests/cli/windows_cross_compile_smoke.sh
              '';
              installPhase = ''
                mkdir -p $out
                echo "windows cross-compile passed" > $out/result
              '';
            };
          };

          devShells.default = mkShell {
            buildInputs = [
              # Existing C++ build deps
              clang
              cmake
              pkg-config
              gtest
              doxygen
              graphviz
              python3
              libclang.python
              libpng
              giflib
              lcms2
              brotli
              ninja
              # Zig + tools
              zig
              hyperfine
            ];
            shellHook = ''
              export CC=clang
              export CXX=clang++
            '';
          };
        }
      );
}
