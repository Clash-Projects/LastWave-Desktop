{
  description = "Next-Gen Lossless Music player with Algorithmic Smart Playlist Generator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
          };
        };

        lib = pkgs.lib;

        libraries = with pkgs; [
          gtk3
          glib
          glib-networking
          gsettings-desktop-schemas
          libepoxy
          pcre2
          libappindicator-gtk3
          libayatana-appindicator
          mpv
          ffmpeg
          openssl
          alsa-lib
          libpulseaudio
          libx11
          sqlite
          libsecret
          webkitgtk_4_1
          libsoup_3
          keybinder3
          libass
          sysprof
          libxdmcp
        ];

        # Custom builder for sqlite3 Dart package (v3.5.2) to fetch upstream precompiled libsqlcipher
        sqlite3Builder = {
          version,
          src,
          ...
        }: let
          system-alias = {
            aarch64-linux = "arm64.linux";
            x86_64-linux = "x64.linux";
          };
          sqlcipher = pkgs.stdenv.mkDerivation {
            name = "libsqlcipher.so";
            src = pkgs.fetchurl {
              url = "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-${version}/libsqlcipher.${system-alias.${pkgs.stdenv.hostPlatform.system} or (throw "Unsupported system for sqlite3 sqlcipher")}.so";
              hash =
                {
                  "3.5.2-x86_64-linux" = "sha256-RdsYQ+ujyR16Ip72A7u2o7uavqtDC72V26pAJAxxOAk=";
                  "3.5.2-aarch64-linux" = "sha256-LMKxM9hJXdCGytVuYSro3iYbMuDwDk6fcqvzVYHD7s0=";
                }.${
                  "${version}-${pkgs.stdenv.hostPlatform.system}"
                } or (throw "Unsupported version ${version} for sqlite3 sqlcipher");
            };
            unpackPhase = ":";
            installPhase = "mkdir -p $out/lib && cp $src $out/lib/libsqlcipher.so";
          };
        in
          pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "sqlite3";
            inherit version src;
            inherit (src) passthru;
            setupHook = pkgs.writeScript "${finalAttrs.pname}-setup-hook" ''
              sqliteFixupHook() {
                runtimeDependencies+=('${lib.getLib pkgs.sqlite}')
                runtimeDependencies+=('${lib.getLib sqlcipher}')
              }
              preFixupHooks+=(sqliteFixupHook)
            '';
            postPatch = ''
              substituteInPlace lib/src/hook/compile/description.dart \
                --replace-fail "return fromGitHub(LibraryType.sqlite3);" "return LookupSystem('sqlite3');"
              substituteInPlace lib/src/hook/compile/description.dart \
                --replace-fail "return fromGitHub(LibraryType.sqlcipher);" "return LookupSystem('sqlcipher');"
            '';
            installPhase = ''
              runHook preInstall
              cp --recursive . "$out"
              runHook postInstall
            '';
          });

        lastwave = pkgs.flutter.buildFlutterApplication {
          pname = "lastwave-desktop";
          version = "1.0.0";
          src = ./.;

          autoPubspecLock = ./pubspec.lock;

          customSourceBuilders = {
            sqlite3 = sqlite3Builder;
          };

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.makeWrapper
          ];

          buildInputs = libraries;

          extraWrapProgramArgs = ''
            --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath libraries}" \
            --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}" \
            --prefix GIO_MODULE_DIR : "${pkgs.glib-networking}/lib/gio/modules"
          '';

          preBuild = ''
            if [ ! -f lib/core/env/secrets.g.dart ]; then
              dart tool/obfuscate_secrets.dart || true
            fi
          '';

          postInstall = ''
            if [ -f linux/packaging/lastwave.desktop ]; then
              install -Dm644 linux/packaging/lastwave.desktop $out/share/applications/lastwave.desktop
              substituteInPlace $out/share/applications/lastwave.desktop \
                --replace-fail "/opt/lastwave/lastwave_desktop" "$out/bin/lastwave_desktop" || true
            fi
            if [ -f lastwave-logo.png ]; then
              install -Dm644 lastwave-logo.png $out/share/icons/hicolor/512x512/apps/lastwave.png
            fi
          '';

          meta = with lib; {
            description = "Next-Gen Lossless Music player with Algorithmic Smart Playlist Generator";
            homepage = "https://github.com/Clash-Projects/LastWave-Desktop";
            license = licenses.gpl3Plus;
            platforms = ["x86_64-linux" "aarch64-linux"];
            mainProgram = "lastwave_desktop";
          };
        };
      in {
        packages = {
          default = lastwave;
          lastwave-desktop = lastwave;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = lastwave;
          name = "lastwave_desktop";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [lastwave];
          packages = with pkgs; [
            flutter
            clang
            cmake
            ninja
            pkg-config
          ];
          shellHook = ''
            export LD_LIBRARY_PATH="${lib.makeLibraryPath libraries}:$LD_LIBRARY_PATH"
            export XDG_DATA_DIRS="${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${pkgs.gtk3}/share/gsettings-schemas/${pkgs.gtk3.name}:$XDG_DATA_DIRS"
            export GIO_MODULE_DIR="${pkgs.glib-networking}/lib/gio/modules"

            # Ensure obfuscated secrets stub exists so development builds don't fail
            if [ ! -f lib/core/env/secrets.g.dart ]; then
              dart tool/obfuscate_secrets.dart 2>/dev/null || true
            fi
          '';
        };
      }
    );
}
