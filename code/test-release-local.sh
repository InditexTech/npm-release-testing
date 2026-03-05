#!/usr/bin/env bash
# test-release-local.sh
# Simulates the code-npm_node-release workflow locally using a Verdaccio registry.
#
# Usage:
#   ./test-release-local.sh [minor|patch|major]   (default: minor)
#
# Prerequisites: node, npm, npx (verdaccio available via npx)

set -euo pipefail

RELEASE_TYPE=${1:-minor}
REGISTRY="http://localhost:4873"
VERDACCIO_PID=""
NPMRC_BACKUP=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Cleanup ────────────────────────────────────────────────────────────────
cleanup() {
  info "Cleaning up..."

  # Restore .npmrc
  if [ -f "$SCRIPT_DIR/.npmrc.bak" ]; then
    mv "$SCRIPT_DIR/.npmrc.bak" "$SCRIPT_DIR/.npmrc"
    info ".npmrc restored"
  else
    rm -f "$SCRIPT_DIR/.npmrc"
  fi

  # Kill Verdaccio
  if [ -n "$VERDACCIO_PID" ] && kill -0 "$VERDACCIO_PID" 2>/dev/null; then
    kill "$VERDACCIO_PID"
    info "Verdaccio stopped (PID $VERDACCIO_PID)"
  fi
}
trap cleanup EXIT

cd "$SCRIPT_DIR"

echo ""
echo "════════════════════════════════════════════"
echo "  Local release test  •  type: $RELEASE_TYPE"
echo "════════════════════════════════════════════"
echo ""

# ── Step 1: Start Verdaccio ────────────────────────────────────────────────
info "Starting Verdaccio at $REGISTRY ..."
npx --yes verdaccio --config ./verdaccio/config/config.yaml &> /tmp/verdaccio-local.log &
VERDACCIO_PID=$!

# Wait until Verdaccio is ready
for i in {1..15}; do
  if curl -sf "$REGISTRY" > /dev/null 2>&1; then
    success "Verdaccio is ready (PID $VERDACCIO_PID)"
    break
  fi
  sleep 1
  if [ "$i" -eq 15 ]; then
    error "Verdaccio did not start in time. Check /tmp/verdaccio-local.log"
    exit 1
  fi
done

# ── Step 2: Configure .npmrc ───────────────────────────────────────────────
info "Configuring npm to use local registry..."

# Backup existing .npmrc if present
[ -f ".npmrc" ] && mv ".npmrc" ".npmrc.bak"

cat > .npmrc <<EOF
registry=${REGISTRY}
@inditextech:registry=${REGISTRY}
//${REGISTRY#http://}/:_authToken=local-test-token
always-auth=false
EOF

success ".npmrc configured"

# ── Step 3: npm ci ─────────────────────────────────────────────────────────
info "Running npm ci ..."
npm ci
success "Dependencies installed"

# ── Step 4: version:release ────────────────────────────────────────────────
info "Running version:release (type: $RELEASE_TYPE) ..."
export RELEASE_VERSION="$RELEASE_TYPE"
npm run version:release
success "Versions bumped"

# Show resulting versions
echo ""
info "Resulting versions:"
for pkg_json in packages/*/package.json; do
  pkg_name=$(node -p "require('./$pkg_json').name")
  pkg_ver=$(node -p "require('./$pkg_json').version")
  echo "    ${pkg_name}  →  ${pkg_ver}"
done
echo ""

# ── Step 5: release:prepare ────────────────────────────────────────────────
info "Running release:prepare (build + verify each package) ..."
npm run release:prepare
success "Packages prepared"

# ── Step 6: release:perform ────────────────────────────────────────────────
info "Running release:perform (publish to local Verdaccio) ..."
npm run release:perform
success "Packages published!"

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo -e "  ${GREEN}✅ Release test completed successfully${NC}"
echo "════════════════════════════════════════════"
echo ""
echo "  Registry: $REGISTRY"
echo "  Browse:   $REGISTRY (open in browser)"
echo ""
info "Published packages:"
for pkg_json in packages/*/package.json; do
  pkg_name=$(node -p "require('./$pkg_json').name")
  pkg_ver=$(node -p "require('./$pkg_json').version")
  echo "    ${pkg_name}@${pkg_ver}"
done
echo ""
warn "Press Ctrl+C to stop Verdaccio and clean up."
echo ""

# Keep Verdaccio alive so you can browse the registry
wait "$VERDACCIO_PID"
