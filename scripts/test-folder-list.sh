#!/bin/zsh
# Compiles and runs the folder List stack's pure-logic tests.
set -euo pipefail
cd "${0:A:h}/.."
out="$(mktemp -d)/folder-list-tests"
swiftc -parse-as-library -o "$out" \
  Docky/Views/Tiles/FolderListLayout.swift \
  Docky/Views/Tiles/FolderItemInfo.swift \
  scripts/tests/FolderListTests.swift
"$out"
