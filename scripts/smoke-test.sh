#!/usr/bin/env bash
# End-to-end smoke test: start a local Soroban network, deploy each primitive
# with the stellar CLI and exercise `initialize` + one state-changing call +
# one read per contract, exactly as a real user would.
#
# Usage:
#   scripts/smoke-test.sh
#
# Requires the `stellar` CLI and Docker. Exits non-zero if any deploy or invoke
# step fails or returns an unexpected result.
#
# Pinned stellar CLI version: see .stellar-cli-version in the repository root.
# Install via: cargo install --locked stellar-cli --version "$(cat .stellar-cli-version)"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

NETWORK="local"
SOURCE="smoke-admin"
WASM_DIR="target/wasm32v1-none/release"

fail() {
  echo "SMOKE TEST FAILED: $*" >&2
  exit 1
}

cleanup() {
  stellar container stop "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

expect() {
  local label="$1" expected="$2" actual="$3"
  if [ "$actual" != "$expected" ]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
  echo "    ok: $label = $actual"
}

invoke() {
  local id="$1"
  shift
  stellar contract invoke --id "$id" --source "$SOURCE" --network "$NETWORK" -- "$@"
}

deploy() {
  local wasm="$WASM_DIR/$1.wasm"
  [ -f "$wasm" ] || fail "missing build artifact $wasm"
  stellar contract deploy --wasm "$wasm" --source "$SOURCE" --network "$NETWORK"
}

echo "==> Starting local network..."
stellar container start "$NETWORK" --limits unlimited
for _ in $(seq 1 60); do
  if curl -sf -X POST -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' \
      http://localhost:8000/rpc | grep -q '"healthy"'; then
    break
  fi
  sleep 2
done

echo "==> Funding identities..."
stellar keys generate "$SOURCE" --network "$NETWORK" --fund --overwrite
stellar keys generate smoke-user --network "$NETWORK" --fund --overwrite
ADMIN="$(stellar keys address "$SOURCE")"
USER_ADDR="$(stellar keys address smoke-user)"

echo "==> Building contracts..."
stellar contract build

echo "==> denylist-gate"
DENY_ID="$(deploy denylist_gate)" || fail "deploy denylist-gate"
invoke "$DENY_ID" initialize --admin "$ADMIN" || fail "denylist-gate initialize"
expect "check before add" "true" "$(invoke "$DENY_ID" check --address "$USER_ADDR")"
invoke "$DENY_ID" add_to_denylist --admin "$ADMIN" --address "$USER_ADDR" || fail "denylist-gate add_to_denylist"
expect "check after add" "false" "$(invoke "$DENY_ID" check --address "$USER_ADDR")"

echo "==> allowlist-token"
TOKEN_ID="$(stellar contract id asset --asset native --network "$NETWORK")" || fail "resolve native SAC"
stellar contract asset deploy --asset native --source "$SOURCE" --network "$NETWORK" >/dev/null 2>&1 || true
ALLOW_ID="$(deploy allowlist_token)" || fail "deploy allowlist-token"
invoke "$ALLOW_ID" initialize --admin "$ADMIN" --token "$TOKEN_ID" || fail "allowlist-token initialize"
expect "is_allowed before add" "false" "$(invoke "$ALLOW_ID" is_allowed --address "$USER_ADDR")"
invoke "$ALLOW_ID" add_to_allowlist --admin "$ADMIN" --address "$USER_ADDR" || fail "allowlist-token add_to_allowlist"
expect "is_allowed after add" "true" "$(invoke "$ALLOW_ID" is_allowed --address "$USER_ADDR")"

echo "==> jurisdiction-flag"
JUR_ID="$(deploy jurisdiction_flag)" || fail "deploy jurisdiction-flag"
invoke "$JUR_ID" initialize --issuer "$ADMIN" || fail "jurisdiction-flag initialize"
invoke "$JUR_ID" set_jurisdiction --issuer "$ADMIN" --address "$USER_ADDR" --code US || fail "jurisdiction-flag set_jurisdiction"
expect "get_jurisdiction" '"US"' "$(invoke "$JUR_ID" get_jurisdiction --address "$USER_ADDR")"

echo "==> Smoke test passed."
