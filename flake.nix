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
          mkZigPackage = optimize: with pkgs; stdenv.mkDerivation {
            inherit pname version;
            src = ./.;
            nativeBuildInputs = [ zig pkg-config libpng giflib zlib brotli ]
              ++ lib.optionals (stdenv.isDarwin) [
                darwin.cctools
                apple-sdk
              ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              export XDG_CACHE_HOME=$TMPDIR/cache
              rm -rf zig-out
              mkdir -p zig-out
              ${lib.optionalString stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              export BROTLI_INCLUDE_DIR=${brotli.dev}/include
              export BROTLI_LIB_DIR=${brotli.lib}/lib
              export GIF_INCLUDE_DIR=${giflib}/include
              export GIF_LIB_DIR=${giflib}/lib
              export CPATH=${giflib}/include''${CPATH:+:$CPATH}
              export LIBRARY_PATH=${giflib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}
              zig build install -Doptimize=${optimize} --prefix zig-out
            '';
            installPhase = ''
              mkdir -p $out
              cp -R zig-out/. $out/
              ${lib.optionalString stdenv.isDarwin ''
                if [ -d "$out/lib" ]; then
                  for archive in "$out"/lib/*.a; do
                    [ -f "$archive" ] || continue
                    libtool -static -o "$archive.repacked" "$archive"
                    mv "$archive.repacked" "$archive"
                  done
                fi
              ''}
            '';
          };
        in
        with pkgs;
        {
          packages = {
            default = mkZigPackage "ReleaseFast";
            debug = mkZigPackage "Debug";
          };

          checks = {
            build = self.packages.${system}.default;
            test = stdenv.mkDerivation {
              pname = "${pname}-test";
              inherit version;
              src = ./.;
            nativeBuildInputs = [ zig pkg-config libpng giflib zlib brotli ]
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
                export BROTLI_INCLUDE_DIR=${brotli.dev}/include
                export BROTLI_LIB_DIR=${brotli.lib}/lib
                export GIF_INCLUDE_DIR=${giflib}/include
                export GIF_LIB_DIR=${giflib}/lib
                export CPATH=${giflib}/include''${CPATH:+:$CPATH}
                export LIBRARY_PATH=${giflib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}
                zig build test -Doptimize=Debug
              '';
              installPhase = ''
                mkdir -p $out
                echo "tests passed" > $out/result
              '';
            };
          } // lib.optionalAttrs (stdenv.isLinux && stdenv.hostPlatform.isx86_64) {
            windows-x86_64-cross = let
              mingwBrotli = pkgs.pkgsCross.mingwW64.brotli;
            in stdenv.mkDerivation {
              pname = "${pname}-windows-x86_64-cross";
              inherit version;
              src = ./.;
              nativeBuildInputs = [ bash zig mingwBrotli ];
              dontConfigure = true;
              dontFixup = true;
              buildPhase = ''
                export HOME=$TMPDIR
                export XDG_CACHE_HOME=$TMPDIR/cache
                export BROTLI_INCLUDE_DIR=${mingwBrotli.dev}/include
                export BROTLI_LIB_DIR=${mingwBrotli.lib}/lib
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
