#!/bin/zsh
# Builds the test binary (fake Spotify) into a temp folder and runs the tests.
# Never touches the real Spotify app, OpenLogi, or the user's caches.
set -euo pipefail
cd "${0:A:h}/.."
work="$(mktemp -d -t spotify-module-tests)"
trap 'rm -rf "$work"' EXIT
zsh build.sh --test "$work/spotify-module-test" >/dev/null
MODULE_TEST_BINARY="$work/spotify-module-test" python3 -I -B tests/test_module.py -v "$@"
