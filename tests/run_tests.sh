#!/bin/bash
# ─────────────────────────────────────────────────────
#  amalgame-database-sqlite — Test Runner
#  Usage: ./tests/run_tests.sh [/path/to/amc]
#
#  Compiles the test fixtures using `amc`, links the vendored
#  sqlite3.c amalgamation, runs the resulting binaries, and
#  greps stdout for expected output. Designed to run in both
#  the package's GitHub Actions CI and on a contributor's
#  machine.
#
#  Discovers amc in this order:
#    1. First positional arg (when present)
#    2. AMC environment variable
#    3. `amc` on PATH
# ─────────────────────────────────────────────────────

set -u

# ── Locate amc ─────────────────────────────────────────
if [ $# -ge 1 ]; then
    AMC="$1"
elif [ -n "${AMC:-}" ]; then
    : # use env-var as-is
elif command -v amc >/dev/null 2>&1; then
    AMC="$(command -v amc)"
else
    echo "ERROR: amc not found. Pass the path as first arg, set AMC env var, or put amc on PATH." >&2
    exit 2
fi

if [ ! -x "$AMC" ]; then
    echo "ERROR: amc binary at '$AMC' is not executable." >&2
    exit 2
fi

# ── Locate package root (parent of this script) ────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_RUNTIME="$PKG_ROOT/runtime"
SQLITE_C="$PKG_ROOT/runtime/Amalgame_Database/sqlite/sqlite3.c"

if [ ! -f "$SQLITE_C" ]; then
    echo "ERROR: vendored sqlite3.c not found at $SQLITE_C" >&2
    exit 2
fi

# ── Locate amc's runtime/ (the core stdlib C headers) ──
# Convention: it sits alongside the `amc` binary in a normal
# source-build layout (./amc + ./runtime/). When amc has been
# installed via release tarball to ~/.local/bin/, the user
# exports AMC_RUNTIME explicitly.
AMC_DIR="$(cd "$(dirname "$AMC")" && pwd)"
if [ -d "$AMC_DIR/runtime" ]; then
    AMC_RUNTIME="$AMC_DIR/runtime"
elif [ -n "${AMC_RUNTIME:-}" ]; then
    : # honor env-var override
else
    echo "ERROR: can't find amc's runtime/ headers." >&2
    echo "       Tried $AMC_DIR/runtime, AMC_RUNTIME env var unset." >&2
    echo "       Either run from a source build of Amalgame, or set" >&2
    echo "       AMC_RUNTIME=/path/to/Amalgame/runtime before running." >&2
    exit 2
fi
echo "  runtime: $AMC_RUNTIME"

# ── Setup ──────────────────────────────────────────────
BUILD_DIR="$(mktemp -d -t adsq-tests-XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

PROJ_DIR="$BUILD_DIR/proj"
mkdir -p "$PROJ_DIR"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

echo ""
echo "════════════════════════════════════════════"
echo "  amalgame-database-sqlite — Test Suite"
echo "════════════════════════════════════════════"
echo "  amc:     $AMC ($("$AMC" --version 2>&1))"
echo "  package: $PKG_ROOT"
echo ""

# ── Install self via amc add (uses cwd as user project) ─
# We test the package's user-facing install flow by `amc add`-ing
# the package from its local Git working tree. CI fetches via tag.
PKG_GIT_URL="github.com/amalgame-lang/amalgame-database-sqlite"
PKG_TAG="${PKG_TAG:-v0.2.0}"

echo "── Resolving $PKG_GIT_URL@$PKG_TAG ──"
if (cd "$PROJ_DIR" && "$AMC" add "$PKG_GIT_URL@$PKG_TAG") > "$BUILD_DIR/install.log" 2>&1; then
    echo "  installed"
    PKG_CACHE_DIR=$(grep "^Cached at" "$BUILD_DIR/install.log" | awk '{print $3}')
    PKG_SQLITE_C="$PKG_CACHE_DIR/runtime/Amalgame_Database/sqlite/sqlite3.c"
    if [ -z "$PKG_CACHE_DIR" ] || [ ! -f "$PKG_SQLITE_C" ]; then
        echo "  WARNING: cache path missing — falling back to local working tree"
        PKG_SQLITE_C="$SQLITE_C"
    fi
else
    echo "  WARNING: amc add failed (likely offline / no network)"
    echo "  falling back to the local working tree for sqlite3.c"
    cat "$BUILD_DIR/install.log" | head -5 | sed 's/^/    /'
    PKG_SQLITE_C="$SQLITE_C"
fi
echo ""

# ── Pre-compile sqlite3.c once ─────────────────────────
SQLITE_OBJ="$BUILD_DIR/sqlite3.o"
echo "── Pre-compiling sqlite3 amalgamation ──"
gcc -O2 -I"$AMC_RUNTIME" -I"$PKG_RUNTIME" -w -c "$PKG_SQLITE_C" -o "$SQLITE_OBJ"
echo "  built: $SQLITE_OBJ"
echo ""

# ── Helper ─────────────────────────────────────────────
run_test() {
    local name="$1"
    local expected="$2"

    printf "  %-38s" "$name"

    cp "$SCRIPT_DIR/stdlib_database.am" "$PROJ_DIR/test.am"
    local out_base="$PROJ_DIR/test"

    local out
    out=$(cd "$PROJ_DIR" && "$AMC" -o test test.am 2>&1)
    local amc_exit=$?
    if [ $amc_exit -ne 0 ]; then
        echo -e "${RED}FAIL${NC} (amc exited $amc_exit)"
        echo "$out" | head -3 | sed 's/^/    /'
        FAIL=$((FAIL + 1)); return
    fi
    if [ ! -f "$out_base.c" ]; then
        echo -e "${RED}FAIL${NC} (no .c emitted)"
        FAIL=$((FAIL + 1)); return
    fi
    gcc -O2 -I"$AMC_RUNTIME" -I"$PKG_RUNTIME" "$out_base.c" "$SQLITE_OBJ" \
        -lgc -lm -lcurl -ldl -lpthread -o "$out_base" 2>/dev/null
    if [ ! -x "$out_base" ]; then
        echo -e "${RED}FAIL${NC} (gcc link failed)"
        FAIL=$((FAIL + 1)); return
    fi
    local run_output
    run_output=$("$out_base" 2>&1)
    if echo "$run_output" | grep -qF "$expected"; then
        echo -e "${GREEN}PASS${NC}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} (output mismatch)"
        echo "    expected: $expected"
        echo "    got:      $(echo "$run_output" | head -3 | tr '\n' '|')"
        FAIL=$((FAIL + 1))
    fi
}

# ── Cases ──────────────────────────────────────────────
echo "── Database.SQLite ─────────────────────────"
run_test "open memory"                  "[PASS] open memory"
run_test "create table"                 "[PASS] create table"
run_test "insert"                       "[PASS] insert alice"
run_test "last insert id 1"             "[PASS] last insert id 1"
run_test "last insert id 3"             "[PASS] last insert id 3"
run_test "changes counter"              "[PASS] changes 2"
run_test "query rows"                   "[PASS] query 3 rows"
run_test "column text"                  "[PASS] alice name"
run_test "update reflected"             "[PASS] alice age post-update"
run_test "aggregate count"              "[PASS] aggregate count 2"
run_test "error reported"               "[PASS] error reported"
run_test "delete + verify"              "[PASS] delete leaves 2"
run_test "close"                        "[PASS] closed"

# ── Summary ────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────"
echo -e "  ${GREEN}PASS: $PASS${NC}  |  ${RED}FAIL: $FAIL${NC}  |  ${YELLOW}SKIP: $SKIP${NC}"
echo "────────────────────────────────────────────"
echo ""

[ $FAIL -eq 0 ] && exit 0 || exit 1
