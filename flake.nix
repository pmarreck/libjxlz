{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ]
      (system:
        let
          pkgs = import nixpkgs {
            inherit system;
          };
          zigPkg = zig-overlay.packages.${system}."0.16.0";
          pname = "libjxlz";
          version = "0.1.0";
          zigNativeTarget = if pkgs.stdenv.isLinux then
            pkgs.lib.replaceStrings [ "-unknown" ] [ "" ] pkgs.stdenv.hostPlatform.config
          else
            null;
          mkZigPackage = optimize: with pkgs; stdenv.mkDerivation {
            inherit pname version;
            src = ./.;
            nativeBuildInputs = [ zigPkg pkg-config libpng giflib zlib brotli ]
              ++ lib.optionals stdenv.isLinux [ patchelf ]
              ++ lib.optionals (stdenv.isDarwin) [
                darwin.cctools
                apple-sdk
              ];
            dontConfigure = true;
            dontFixup = !stdenv.isLinux;
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
              zig build install -Doptimize=${optimize} ${lib.optionalString (zigNativeTarget != null) "-Dtarget=${zigNativeTarget}"} --prefix zig-out
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
            fixupPhase = lib.optionalString stdenv.isLinux ''
              runHook preFixup
              dynamic_linker="$(cat ${stdenv.cc}/nix-support/dynamic-linker)"
              rpath="${lib.makeLibraryPath [ brotli giflib libpng zlib ]}"
              for binary in "$out"/bin/*; do
                [ -f "$binary" ] || continue
                patchelf --print-interpreter "$binary" >/dev/null 2>&1 || continue
                patchelf --set-interpreter "$dynamic_linker" --set-rpath "$rpath" "$binary"
              done
              runHook postFixup
            '';
          };
        in
        with pkgs;
        {
          packages = {
            default = mkZigPackage "ReleaseSafe";
            releasefast = mkZigPackage "ReleaseFast";
            debug = mkZigPackage "Debug";
          };

          checks = let
            conformanceCorpus = pkgs.fetchFromGitHub {
              owner = "libjxl";
              repo = "conformance";
              rev = "b1d0f990b03e57bf6d137c365cd5dc8b470b9191";
              hash = "sha256-tpKnt44FgZUqzvk5YcMBmVsDCdvlA6Cz+KNYMTVUacc=";
            };
            # The Zig unit tests are the mode-sensitive surface: `undefined`
            # memory reads behave differently per optimize mode, and exactly that
            # produced a ReleaseFast-only encoder failure that a ReleaseSafe-only
            # gate could not see (ExtraChannelInfo.name_buf, fixed 2026-08-01).
            # libjxlz ships ReleaseSafe binaries, but Zig consumers compile this
            # code at whatever mode they choose, so both are gated.
            mkTestCheck = mode: stdenv.mkDerivation {
              pname = "${pname}-test-${mode}";
              inherit version;
              src = ./.;
            nativeBuildInputs = [ zigPkg pkg-config libpng giflib zlib brotli ]
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
                ${lib.optionalString stdenv.isLinux ''
                # On Linux, Zig 0.16 bakes the FHS dynamic-linker path
                # (/lib64/ld-linux-x86-64.so.2 etc.) into libc-linked
                # binaries. That path doesn't exist in the Nix sandbox,
                # so `zig build test` fails to spawn the test binaries
                # with `FileNotFound` — even though every test passed
                # under cross-build coverage. We compile the test bins
                # via `test-compile`, then invoke each through Nix's
                # actual loader. Mirrors the pattern in c0/flake.nix.
                zig build test-compile -Doptimize=${mode} ${lib.optionalString (zigNativeTarget != null) "-Dtarget=${zigNativeTarget}"}
                DL="$(cat ${stdenv.cc}/nix-support/dynamic-linker)"
                TEST_LIBRARY_PATH="${lib.makeLibraryPath [ brotli ]}"
                rc=0
                for f in zig-out/test-bins/*; do
                  [ -x "$f" ] || continue
                  "$DL" --library-path "$TEST_LIBRARY_PATH" "$f" || rc=1
                done
                [ $rc -eq 0 ] || { echo "Tests failed"; exit 1; }
                ''}
                ${lib.optionalString (!stdenv.isLinux) ''
                zig build test -Doptimize=${mode}
                ''}
              '';
              installPhase = ''
                mkdir -p $out
                echo "tests passed" > $out/result
              '';
            };
          in {
            build = self.packages.${system}.default;
            test = mkTestCheck "ReleaseSafe";
            test-releasefast = mkTestCheck "ReleaseFast";
            conformance-acceptance = pkgs.runCommand "${pname}-conformance-acceptance" {
              nativeBuildInputs = [ pkgs.bash pkgs.coreutils pkgs.gawk ];
            } ''
              cd ${./.}
              bash tests/cli/conformance_acceptance_controls_smoke.sh
              source tests/lib/strict_mutation_matrix.bash
              source tests/lib/conformance_acceptance.bash
              mkdir -p "$out"
              if ! run_conformance_acceptance ${conformanceCorpus}/testcases ${self.packages.${system}.default}/bin/jxlz "$out" 40 27; then
                cat "$out/results.tsv" >&2
                exit 1
              fi
              cp ${conformanceCorpus}/LICENSE "$out/CORPUS_LICENSE"
              cp ${conformanceCorpus}/testcases/README.md "$out/CORPUS_CREDITS.md"
              printf '%s\n' 'https://github.com/libjxl/conformance' 'b1d0f990b03e57bf6d137c365cd5dc8b470b9191' 'sha256-tpKnt44FgZUqzvk5YcMBmVsDCdvlA6Cz+KNYMTVUacc=' > "$out/provenance.txt"
            '';
          } // lib.optionalAttrs (stdenv.isLinux && stdenv.hostPlatform.isx86_64) {
            windows-x86_64-cross = let
              mingwBrotli = pkgs.pkgsCross.mingwW64.brotli;
            in stdenv.mkDerivation {
              pname = "${pname}-windows-x86_64-cross";
              inherit version;
              src = ./.;
              nativeBuildInputs = [ bash zigPkg mingwBrotli ];
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
              zigPkg
              hyperfine
            ];
            nativeBuildInputs = [
              luajit
              # Differential decode oracle for the ground-truth corpus tests.
              # decode_ground_truth_oracle_djxl() falls back to `command -v djxl`,
              # so before this the oracle was whatever happened to be installed
              # on the machine: it worked from Peter's user profile and failed 7
              # suites on every CI runner with "command not found". The nixpkgs
              # input is pinned to a revision carrying libjxl 0.12.0, matching
              # the version the corpus manifests are baselined against, so the
              # oracle is now locked by flake.lock rather than by whatever the
              # host happens to have. Taking only the `bin` output keeps upstream
              # libjxl headers and libraries off the include and link paths,
              # which matters because this repository is a fork of libjxl and its
              # own headers must win.
              libjxl.bin
            ];
            shellHook = ''
              export CC=clang
              export CXX=clang++
              # build.zig reads this to add brotli's headers, which the static
              # libraries now need directly: they add includes only and no longer
              # inherit them from linkSystemLibrary's pkg-config lookup.
              # Deliberately NOT exporting BROTLI_LIB_DIR here. Executables still
              # resolve brotli through pkg-config, and
              # tests/cli/windows_cross_compile_smoke.sh treats "both vars set" as
              # "the caller already chose a brotli" and would then skip resolving
              # the MinGW cross build it actually needs.
              export BROTLI_INCLUDE_DIR="${brotli.dev}/include"
            '';
          };
        }
      );
}
