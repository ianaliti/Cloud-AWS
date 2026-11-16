#!/usr/bin/env bash
# =============================================================================
# build.sh — Package both Lambda functions as deployment ZIP files
#
# AWS Lambda expects a ZIP archive containing the handler code and all
# third-party dependencies at the root level (not in a sub-folder).
# boto3 is already present in the Lambda runtime, but we include it
# anyway so the same ZIP works for local testing outside the runtime.
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${GREEN}[build]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

build_lambda() {
  local name="$1"      # e.g. "lambda_a"
  local src="$ROOT/$name"
  local build_dir="$src/build"
  local zip_file="$src/function.zip"

  info "Building $name..."
  rm -rf "$build_dir" "$zip_file"
  mkdir -p "$build_dir"

  # Install dependencies into build dir
  python3 -m pip install -q -r "$src/requirements.txt" -t "$build_dir"

  # Copy handler code
  cp "$src/handler.py" "$build_dir/"

  # Create ZIP from inside build dir (so paths are at the root)
  (cd "$build_dir" && zip -qr "$zip_file" .)
  info "$name → $zip_file ($(du -sh "$zip_file" | cut -f1))"
}

build_lambda "lambda_a"
build_lambda "lambda_b"

info "Both packages ready."
