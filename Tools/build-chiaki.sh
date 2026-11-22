#!/bin/zsh
# Builds libchiaki (the PS5 connection and pairing library from chiaki-ng) into vendor/chiaki-ng/build.
# Needed once after cloning, and again only when the chiaki-ng submodule changes.
# Usage: Tools/build-chiaki.sh            (expects the Homebrew packages listed below)
#        Tools/build-chiaki.sh --deps     (installs them first)
set -euo pipefail
cd "$(dirname "$0")/.."

DEPS=(cmake protobuf opus json-c miniupnpc libevent openssl@3 libnghttp2 pkgconf)
if [[ "${1:-}" == "--deps" ]]; then
    brew install --quiet "${DEPS[@]}"
fi

# Only the submodules libchiaki needs (chiaki-ng also carries Android, Switch and Steam Deck code).
git submodule update --init vendor/chiaki-ng
git -C vendor/chiaki-ng submodule update --init --depth 1 \
    third-party/curl third-party/gf-complete third-party/jerasure third-party/nanopb

# nanopb's generator needs Python with grpcio-tools.
if [[ ! -x vendor/.venv/bin/python ]]; then
    python3 -m venv vendor/.venv
    vendor/.venv/bin/pip install --quiet grpcio-tools
fi

cmake -S vendor/chiaki-ng -B vendor/chiaki-ng/build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_GUI=OFF \
    -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF -DCHIAKI_ENABLE_SPEEX=OFF \
    -DCHIAKI_ENABLE_RUDP=OFF -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF \
    -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
    -DPYTHON_EXECUTABLE="$PWD/vendor/.venv/bin/python"
cmake --build vendor/chiaki-ng/build -j "$(sysctl -n hw.ncpu)"
echo "built vendor/chiaki-ng/build/lib/libchiaki.a"
