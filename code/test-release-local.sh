#!/usr/bin/env bash
# test-release-local.sh
# Simulates the code-npm_node-release and code-npm_node-publish_snapshot
# workflows locally using a Verdaccio registry.
#
# Usage:
#   ./test-release-local.sh [release|snapshot] [minor|patch|major]
#
#   release  (default) — mirrors code-npm_node-publish-release-and-snapshot.yml (release path)  → tag: latest
#   snapshot           — mirrors code-npm_node-publish-release-and-snapshot.yml (snapshot path) → tag: next
#
# Examples:
#   ./test-release-local.sh                    # release minor
#   ./test-release-local.sh release patch      # release patch
#   ./test-release-local.sh snapshot minor     # snapshot minor
#
# Prerequisites: node, npm, npx (verdaccio available via npx)

set -euo pipefail

MODE=${1:-release}
RELEASE_TYPE=${2:-minor}
REGISTRY="http://localhost:4873"
VERDACCIO_PID=""
PACK_DIR=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Validate mode
if [[ "$MODE" != "release" && "$MODE" != "snapshot" ]]; then
  echo "Usage: $0 [release|snapshot] [minor|patch|major]"
  exit 1
fi

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

  # Remove temp pack dir
  [ -n "$PACK_DIR" ] && rm -rf "$PACK_DIR"

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
echo "  Local $MODE test  •  type: $RELEASE_TYPE"
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

# ── Step 4: compute version ────────────────────────────────────────────────
if [[ "$MODE" == "snapshot" ]]; then
  # Mirrors the "Define snapshot version" step in code-npm_node-publish-release-and-snapshot.yml:
  # CLEAN_VERSION-SNAPSHOT.<run_number>.<run_attempt>
  # Locally simulated as: bumped version + -SNAPSHOT.1.1
  CLEAN_VERSION=$(node -e "
    const p = require('./packages/core/package.json');
    const v = p.version.replace(/-.*\$/, '').split('.').map(Number);
    if ('$RELEASE_TYPE' === 'major')       { v[0]++; v[1] = 0; v[2] = 0; }
    else if ('$RELEASE_TYPE' === 'minor')  { v[1]++; v[2] = 0; }
    else                                   { v[2]++; }
    console.log(v.join('.'));
  ")
  PUBLISH_VERSION="${CLEAN_VERSION}-SNAPSHOT.1.1"
  NPM_TAG="next"
  info "Snapshot version: $PUBLISH_VERSION (tag: $NPM_TAG)"
else
  PUBLISH_VERSION="$RELEASE_TYPE"
  NPM_TAG="latest"
fi

# ── Step 5: version:release ────────────────────────────────────────────────
info "Running version:release (RELEASE_VERSION=$PUBLISH_VERSION) ..."
export RELEASE_VERSION="$PUBLISH_VERSION"
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

# ── Step 6: release:prepare ────────────────────────────────────────────────
info "Running release:prepare (build + verify each package) ..."
npm run release:prepare
success "Packages prepared"

# ── Step 7: pack (mirrors code-npm_node-publish-release-and-snapshot.yml) ───
PACK_DIR="/tmp/npm-packages-local-$$"
mkdir -p "$PACK_DIR"
info "Packing workspaces to $PACK_DIR ..."
npm pack --workspaces --pack-destination "$PACK_DIR"
success "Packages packed:"
ls "$PACK_DIR"/*.tgz | while read -r f; do echo "    $(basename "$f")"; done

# ── Step 8: publish from tarball ───────────────────────────────────────────
info "Publishing tarballs to local Verdaccio (tag: $NPM_TAG) ..."
for tarball in "$PACK_DIR"/*.tgz; do
  npm publish "$tarball" --access public --tag "$NPM_TAG"
  success "Published $(basename "$tarball") → tag:$NPM_TAG"
done

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo -e "  ${GREEN}✅ ${MODE} test completed successfully${NC}"
echo "════════════════════════════════════════════"
echo ""
echo "  Registry: $REGISTRY"
echo "  Browse:   $REGISTRY (open in browser)"
echo ""
info "Published packages (tag: $NPM_TAG):"
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

