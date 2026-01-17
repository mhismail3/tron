#!/usr/bin/env bash
#
# Tron Build Script
#
# Unified build script for all tiers: beta, prod, public
#
# Usage:
#   ./scripts/build.sh [tier] [options]
#
# Tiers:
#   beta    - Development build (default)
#   prod    - Personal production build
#   public  - Public release build
#
# Options:
#   --clean     Clean before build
#   --watch     Watch mode (beta only)
#   --install   Install after build
#   --help      Show this help
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TRON_HOME="${TRON_DATA_DIR:-$HOME/.tron}"

# Defaults
TIER="beta"
CLEAN=false
WATCH=false
INSTALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        beta|prod|public)
            TIER="$1"
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --watch)
            WATCH=true
            shift
            ;;
        --install)
            INSTALL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [tier] [options]"
            echo ""
            echo "Tiers:"
            echo "  beta    Development build with hot-reload (default)"
            echo "  prod    Personal production build"
            echo "  public  Public release build"
            echo ""
            echo "Options:"
            echo "  --clean     Clean before build"
            echo "  --watch     Watch mode (beta only)"
            echo "  --install   Install after build"
            echo "  --help      Show this help"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

log() { echo -e "${BLUE}[build:$TIER]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; exit 1; }

header() {
    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}${BOLD}                    Tron Build System                          ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  Tier:     ${BOLD}$TIER${NC}"
    echo -e "  Project:  $PROJECT_DIR"
    echo -e "  Clean:    $CLEAN"
    echo -e "  Watch:    $WATCH"
    echo -e "  Install:  $INSTALL"
    echo ""
}

# Clean build artifacts
clean_build() {
    log "Cleaning build artifacts..."
    cd "$PROJECT_DIR"

    rm -rf packages/*/dist
    rm -rf packages/*/.turbo
    rm -rf node_modules/.cache
    rm -rf .tsbuildinfo

    success "Clean complete"
}

# Build for beta tier (development)
build_beta() {
    log "Building for beta (development)..."
    cd "$PROJECT_DIR"

    export NODE_ENV=development
    export TRON_BUILD_TIER=beta
    export TRON_DEV=1

    # Type check first
    log "Type checking..."
    npm run typecheck || warn "Type errors found (continuing anyway)"

    # Build all packages
    log "Compiling TypeScript..."
    npm run build

    success "Beta build complete"

    if [ "$WATCH" = true ]; then
        log "Starting watch mode..."
        exec npm run dev:tui
    fi
}

# Build for prod tier (personal production)
build_prod() {
    log "Building for prod (personal production)..."
    cd "$PROJECT_DIR"

    export NODE_ENV=production
    export TRON_BUILD_TIER=prod

    # Clean and rebuild
    log "Type checking..."
    npm run typecheck

    log "Compiling TypeScript..."
    npm run build

    # Create prod install directory
    local install_dir="$TRON_HOME/install/prod"
    mkdir -p "$install_dir"

    # Bundle for production
    log "Creating production bundle..."

    # Copy built packages
    rm -rf "$install_dir/packages"
    mkdir -p "$install_dir/packages"

    for pkg in core server tui; do
        cp -r "packages/$pkg/dist" "$install_dir/packages/$pkg"
        cp "packages/$pkg/package.json" "$install_dir/packages/$pkg/"
    done

    # Copy root files
    cp package.json "$install_dir/"
    cp package-lock.json "$install_dir/" 2>/dev/null || true

    # Install production dependencies only
    log "Installing production dependencies..."
    cd "$install_dir"
    npm install --production --ignore-scripts 2>/dev/null || {
        # Fallback: copy node_modules from project
        log "Copying node_modules from project..."
        cp -r "$PROJECT_DIR/node_modules" "$install_dir/"
    }

    success "Prod build complete at $install_dir"

    if [ "$INSTALL" = true ]; then
        install_prod
    fi
}

# Build for public tier (public release)
build_public() {
    log "Building for public (public release)..."
    cd "$PROJECT_DIR"

    export NODE_ENV=production
    export TRON_BUILD_TIER=public
    export TRON_PUBLIC=1

    # Clean and rebuild
    log "Type checking..."
    npm run typecheck

    log "Running tests..."
    npm test || warn "Tests failed - continuing with build anyway"

    log "Compiling TypeScript..."
    npm run build

    # Create release directory
    local version
    version=$(node -p "require('./package.json').version")
    local release_dir="$PROJECT_DIR/releases/tron-$version"

    rm -rf "$release_dir"
    mkdir -p "$release_dir"

    log "Creating release bundle v$version..."

    # Copy built packages
    mkdir -p "$release_dir/packages"
    for pkg in core server tui; do
        cp -r "packages/$pkg/dist" "$release_dir/packages/$pkg"
        cp "packages/$pkg/package.json" "$release_dir/packages/$pkg/"
    done

    # Copy required files
    cp package.json "$release_dir/"
    cp package-lock.json "$release_dir/" 2>/dev/null || true
    cp README.md "$release_dir/"
    cp LICENSE "$release_dir/" 2>/dev/null || true

    # Copy deploy configs
    cp -r deploy "$release_dir/"
    cp -r scripts "$release_dir/"

    # Create tarball
    log "Creating tarball..."
    cd "$PROJECT_DIR/releases"
    tar -czf "tron-$version.tar.gz" "tron-$version"

    # Calculate SHA256
    local sha256
    sha256=$(shasum -a 256 "tron-$version.tar.gz" | cut -d' ' -f1)
    echo "$sha256" > "tron-$version.sha256"

    success "Public build complete"
    echo ""
    echo "  Release:  $release_dir"
    echo "  Tarball:  releases/tron-$version.tar.gz"
    echo "  SHA256:   $sha256"
    echo ""
}

# Install prod build
install_prod() {
    log "Installing prod build..."

    local install_dir="$TRON_HOME/install/prod"
    local bin_dir="$HOME/.local/bin"

    mkdir -p "$bin_dir"

    # Create wrapper script
    cat > "$bin_dir/tron" << EOF
#!/usr/bin/env bash
# Tron CLI wrapper (prod build)
export TRON_BUILD_TIER=prod
export NODE_ENV=production
exec node "$install_dir/packages/tui/dist/cli.js" "\$@"
EOF
    chmod +x "$bin_dir/tron"

    success "Installed tron to $bin_dir/tron"

    # Check if bin_dir is in PATH
    if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
        warn "$bin_dir is not in your PATH"
        echo "  Add this to your shell profile:"
        echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
}

# Main
header

if [ "$CLEAN" = true ]; then
    clean_build
fi

case "$TIER" in
    beta)
        build_beta
        ;;
    prod)
        build_prod
        ;;
    public)
        build_public
        ;;
    *)
        error "Unknown tier: $TIER"
        ;;
esac

echo ""
success "Build complete!"
