#!/usr/bin/env bash
# build.sh — local convenience wrapper around swift package manager
set -euo pipefail
case "${1:-run}" in
  build)   swift build ;;
  run)     swift run ;;
  release) swift build -c release ;;
  clean)   swift package clean ;;
  *)       echo "usage: $0 {build|run|release|clean}"; exit 1 ;;
esac
