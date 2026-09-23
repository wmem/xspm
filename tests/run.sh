#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
XMAKE_BIN=${XMAKE_BIN:-xmake}
BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
export XMAKE_ROOT=${XMAKE_ROOT:-y}

make_remote() {
    local name=$1
    local src="$BASE/src/$name"
    local bare="$BASE/remotes/$name.git"
    mkdir -p "$src" "$BASE/remotes"
    git -C "$src" init -q
    git -C "$src" config user.name gdep-test
    git -C "$src" config user.email gdep-test@example.invalid
    echo "$name" >"$src/data.txt"
    git -C "$src" add data.txt
    git -C "$src" commit -q -m init
    git -C "$src" branch -M main
    git clone -q --bare "$src" "$bare"
    git -C "$src" remote add origin "$bare"
    git -C "$src" push -q -u origin main
    git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
}

make_remote leaf
make_remote parent

cat >"$BASE/src/leaf/xmake.lua" <<'XMAKE'
target("leaf_from_gdep")
    set_kind("phony")
XMAKE
git -C "$BASE/src/leaf" add xmake.lua
git -C "$BASE/src/leaf" commit -q -m xmake
git -C "$BASE/src/leaf" push -q origin main

cat >"$BASE/src/parent/gdep.lua" <<MANIFEST
return {
    dependencies = {
        leaf = "file://$BASE/remotes/leaf.git#main"
    }
}
MANIFEST
cat >"$BASE/src/parent/xmake.lua" <<'XMAKE'
target("from_gdep")
    set_kind("phony")
gdep_include("gdeps/leaf/xmake.lua")
XMAKE
git -C "$BASE/src/parent" add gdep.lua xmake.lua
git -C "$BASE/src/parent" commit -q -m recursive
git -C "$BASE/src/parent" push -q origin main

mkdir -p "$BASE/project/tools"
git clone -q "$ROOT" "$BASE/project/tools/gdep"
cat >"$BASE/project/xmake.lua" <<'XMAKE'
set_project("gdep-test")
includes("tools/gdep/xmake.lua")
gdep_include("gdeps/parent/xmake.lua")
XMAKE
cat >"$BASE/project/gdep.lua" <<MANIFEST
return {
    dependencies = {
        parent = "file://$BASE/remotes/parent.git#main"
    }
}
MANIFEST

# Missing gdep_include must not prevent project parsing.
(cd "$BASE/project" && "$XMAKE_BIN" show -l targets >/dev/null)

# Recursive install and repeat sync.
(cd "$BASE/project" && "$XMAKE_BIN" gdep >/dev/null)
test -d "$BASE/project/gdeps/parent/.git"
test -d "$BASE/project/gdeps/parent/gdeps/leaf/.git"
TARGETS=$(cd "$BASE/project" && "$XMAKE_BIN" show -l targets)
grep -q from_gdep <<<"$TARGETS"
grep -q leaf_from_gdep <<<"$TARGETS"
(cd "$BASE/project" && "$XMAKE_BIN" gdep >/dev/null)

# Manager-owned nested gdeps must not count as source dirtiness.
git -C "$BASE/project/gdeps/parent" status --short | grep -q '^?? gdeps/'

# Lock creation and offline locked sync.
(cd "$BASE/project" && "$XMAKE_BIN" gdep --lock >/dev/null)
test -f "$BASE/project/gdep.lock"
mv "$BASE/remotes/parent.git" "$BASE/remotes/parent.git.off"
mv "$BASE/remotes/leaf.git" "$BASE/remotes/leaf.git.off"
(cd "$BASE/project" && "$XMAKE_BIN" gdep >/dev/null)
mv "$BASE/remotes/parent.git.off" "$BASE/remotes/parent.git"
mv "$BASE/remotes/leaf.git.off" "$BASE/remotes/leaf.git"

# Local edits must fail unless --force is used.
echo dirty >>"$BASE/project/gdeps/parent/data.txt"
if (cd "$BASE/project" && "$XMAKE_BIN" gdep >/dev/null 2>&1); then
    echo "expected dirty dependency failure" >&2
    exit 1
fi
(cd "$BASE/project" && "$XMAKE_BIN" gdep --force >/dev/null)
! grep -q dirty "$BASE/project/gdeps/parent/data.txt"
test -d "$BASE/project/gdeps/parent/gdeps/leaf/.git"

# A locked normal sync stays pinned; --update moves the lock.
OLD=$(git -C "$BASE/project/gdeps/parent" rev-parse HEAD)
echo update >>"$BASE/src/parent/data.txt"
git -C "$BASE/src/parent" add data.txt
git -C "$BASE/src/parent" commit -q -m update
git -C "$BASE/src/parent" push -q origin main
NEW=$(git -C "$BASE/src/parent" rev-parse HEAD)
test "$OLD" != "$NEW"
(cd "$BASE/project" && "$XMAKE_BIN" gdep >/dev/null)
test "$(git -C "$BASE/project/gdeps/parent" rev-parse HEAD)" = "$OLD"
(cd "$BASE/project" && "$XMAKE_BIN" gdep --update >/dev/null)
test "$(git -C "$BASE/project/gdeps/parent" rev-parse HEAD)" = "$NEW"
grep -q "$NEW" "$BASE/project/gdep.lock"

# Existing repository origin is verified.
git -C "$BASE/project/gdeps/parent" remote set-url origin "file://$BASE/remotes/leaf.git"
if (cd "$BASE/project" && "$XMAKE_BIN" gdep >/dev/null 2>&1); then
    echo "expected origin mismatch failure" >&2
    exit 1
fi

echo "gdep tests passed"
