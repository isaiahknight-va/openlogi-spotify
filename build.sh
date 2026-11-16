#!/bin/zsh
# Builds ./spotify-module, next to module.toml, with the Command Line Tools' swiftc.
#   zsh build.sh              the module
#   zsh build.sh --test OUT   a test binary at OUT, with the fake Spotify from tests/
set -euo pipefail
cd "${0:A:h}"
target="$(uname -m)-apple-macos15.0"
if [[ "${1:-}" == "--test" ]]; then
  out="${2:?usage: zsh build.sh --test OUT}"
  swiftc -O -target "$target" -D FAKE_SPOTIFY -o "$out" Sources/main.swift tests/FakeSpotify.swift
  echo "built $out (test build, fake Spotify)"
else
  swiftc -O -target "$target" -o spotify-module Sources/main.swift
  echo "built ${PWD}/spotify-module"
fi
