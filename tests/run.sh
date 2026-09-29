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
    git -C "$src" config user.name xspm-test
    git -C "$src" config user.email xspm-test@example.invalid
    echo "$name" >"$src/data.txt"
    git -C "$src" add data.txt
    git -C "$src" commit -q -m init
    git -C "$src" branch -M main
    git clone -q --bare "$src" "$bare"
    git -C "$src" remote add origin "$bare"
    git -C "$src" push -q -u origin main
    git --git-dir="$bare" symbolic-ref HEAD refs/heads/main
}

push_change() {
    local name=$1
    local text=$2
    echo "$text" >>"$BASE/src/$name/data.txt"
    git -C "$BASE/src/$name" add data.txt
    git -C "$BASE/src/$name" commit -q -m "$text"
    git -C "$BASE/src/$name" push -q origin main
}

make_remote leaf
make_remote parent
make_remote extra

cat >"$BASE/src/leaf/xmake.lua" <<'XMAKE'
target("leaf_from_xspm")
    set_kind("phony")
XMAKE
git -C "$BASE/src/leaf" add xmake.lua
git -C "$BASE/src/leaf" commit -q -m xmake
git -C "$BASE/src/leaf" push -q origin main

cat >"$BASE/src/parent/xspm.json" <<MANIFEST
{
  "version": 1,
  "dependencies": {
    "leaf": "file://$BASE/remotes/leaf.git#main"
  }
}
MANIFEST
cat >"$BASE/src/parent/.gitignore" <<'EOF2'
generated/
EOF2
cat >"$BASE/src/parent/xspm.lua" <<'HOOK'
function on_install(ctx)
    os.mkdir(path.join(ctx.rootdir, "generated"))
    io.writefile(path.join(ctx.rootdir, "generated", "commit.txt"), ctx.commit .. "\n")
    local counter = path.join(ctx.projectdir, "hook-count.txt")
    local n = 0
    if os.isfile(counter) then
        n = tonumber((io.readfile(counter) or "0"):match("%d+")) or 0
    end
    io.writefile(counter, tostring(n + 1) .. "\n")
end
HOOK
cat >"$BASE/src/parent/xmake.lua" <<'XMAKE'
target("from_xspm")
    set_kind("phony")
xspm_include("deps/leaf/xmake.lua")
XMAKE
git -C "$BASE/src/parent" add xspm.json xspm.lua xmake.lua .gitignore
git -C "$BASE/src/parent" commit -q -m recursive
git -C "$BASE/src/parent" push -q origin main

mkdir -p "$BASE/project/tools"
git clone -q "$ROOT" "$BASE/project/tools/xspm"
cat >"$BASE/project/xmake.lua" <<'XMAKE'
set_project("xspm-test")
includes("tools/xspm/xmake.lua")
xspm_include("deps/parent/xmake.lua")
XMAKE
FIXED_LEAF=$(git -C "$BASE/src/leaf" rev-parse HEAD)
cat >"$BASE/project/xspm.json" <<MANIFEST
{
  "version": 1,
  "installDir": "deps",
  "dependencies": {
    "parent": "file://$BASE/remotes/parent.git#main",
    "fixed_leaf": {
      "source": "file://$BASE/remotes/leaf.git#$FIXED_LEAF",
      "path": "vendor/fixed_leaf"
    },
    "extra": "file://$BASE/remotes/extra.git#main"
  }
}
MANIFEST

# Missing xspm_include must not prevent project parsing before installation.
(cd "$BASE/project" && "$XMAKE_BIN" show -l targets >/dev/null)

# Recursive install, custom path, hook execution and repeat sync.
(cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null)
test -d "$BASE/project/deps/parent/.git"
test -d "$BASE/project/deps/parent/deps/leaf/.git"
test -d "$BASE/project/vendor/fixed_leaf/.git"
test -d "$BASE/project/deps/extra/.git"
test -f "$BASE/project/.xspm/state/packages.json"
test "$(cat "$BASE/project/hook-count.txt")" = "1"
test "$(cat "$BASE/project/deps/parent/generated/commit.txt" | tr -d '\n')" = "$(git -C "$BASE/project/deps/parent" rev-parse HEAD)"
TARGETS=$(cd "$BASE/project" && "$XMAKE_BIN" show -l targets)
grep -q from_xspm <<<"$TARGETS"
grep -q leaf_from_xspm <<<"$TARGETS"
(cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null)
test "$(cat "$BASE/project/hook-count.txt")" = "1"

# Nested managed packages and ignored hook outputs do not make the parent dirty.
test -z "$(git -C "$BASE/project/deps/parent" status --porcelain --untracked-files=all)"

# list/status are read-only and work without network access.
LIST=$(cd "$BASE/project" && "$XMAKE_BIN" xspm --list)
grep -q 'parent' <<<"$LIST"
grep -q 'parent/leaf' <<<"$LIST"
grep -q 'vendor/fixed_leaf' <<<"$LIST"
STATUS=$(cd "$BASE/project" && "$XMAKE_BIN" xspm --status)
grep -q 'unlocked' <<<"$STATUS"

# Lock creation and offline locked sync.
(cd "$BASE/project" && "$XMAKE_BIN" xspm --lock >/dev/null)
test -f "$BASE/project/xspm-lock.json"
grep -q 'vendor/fixed_leaf' "$BASE/project/xspm-lock.json"
STATUS=$(cd "$BASE/project" && "$XMAKE_BIN" xspm --status)
grep -q ' ok ' <<<"$STATUS"
mv "$BASE/remotes/parent.git" "$BASE/remotes/parent.git.off"
mv "$BASE/remotes/leaf.git" "$BASE/remotes/leaf.git.off"
mv "$BASE/remotes/extra.git" "$BASE/remotes/extra.git.off"
(cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null)
mv "$BASE/remotes/parent.git.off" "$BASE/remotes/parent.git"
mv "$BASE/remotes/leaf.git.off" "$BASE/remotes/leaf.git"
mv "$BASE/remotes/extra.git.off" "$BASE/remotes/extra.git"

# Local edits fail unless --force is used.
echo dirty >>"$BASE/project/deps/parent/data.txt"
if (cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null 2>&1); then
    echo "expected dirty package failure" >&2
    exit 1
fi
(cd "$BASE/project" && "$XMAKE_BIN" xspm --force >/dev/null)
! grep -q dirty "$BASE/project/deps/parent/data.txt"
test -d "$BASE/project/deps/parent/deps/leaf/.git"

# Reinitialize a single package without changing its commit.
COUNT=$(cat "$BASE/project/hook-count.txt")
(cd "$BASE/project" && "$XMAKE_BIN" xspm --reinit parent >/dev/null)
test "$(cat "$BASE/project/hook-count.txt")" = "$((COUNT + 1))"

# Selective update refreshes the selected package subtree but not unrelated packages.
OLD_PARENT=$(git -C "$BASE/project/deps/parent" rev-parse HEAD)
OLD_LEAF=$(git -C "$BASE/project/deps/parent/deps/leaf" rev-parse HEAD)
OLD_EXTRA=$(git -C "$BASE/project/deps/extra" rev-parse HEAD)
push_change parent parent-update
push_change leaf leaf-update
push_change extra extra-update
NEW_PARENT=$(git -C "$BASE/src/parent" rev-parse HEAD)
NEW_LEAF=$(git -C "$BASE/src/leaf" rev-parse HEAD)
NEW_EXTRA=$(git -C "$BASE/src/extra" rev-parse HEAD)
test "$OLD_PARENT" != "$NEW_PARENT"
test "$OLD_LEAF" != "$NEW_LEAF"
test "$OLD_EXTRA" != "$NEW_EXTRA"
(cd "$BASE/project" && "$XMAKE_BIN" xspm --update parent >/dev/null)
test "$(git -C "$BASE/project/deps/parent" rev-parse HEAD)" = "$NEW_PARENT"
test "$(git -C "$BASE/project/deps/parent/deps/leaf" rev-parse HEAD)" = "$NEW_LEAF"
test "$(git -C "$BASE/project/deps/extra" rev-parse HEAD)" = "$OLD_EXTRA"
grep -q "$NEW_PARENT" "$BASE/project/xspm-lock.json"
grep -q "$NEW_LEAF" "$BASE/project/xspm-lock.json"
grep -q "$OLD_EXTRA" "$BASE/project/xspm-lock.json"

# Prune removes packages no longer declared and removes stale lock/state entries.
python3 - "$BASE/project/xspm.json" <<'PY'
import json, sys
p = sys.argv[1]
with open(p) as f:
    data = json.load(f)
data["dependencies"].pop("extra")
with open(p, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
(cd "$BASE/project" && "$XMAKE_BIN" xspm --prune >/dev/null)
test ! -e "$BASE/project/deps/extra"
! grep -q 'deps/extra' "$BASE/project/xspm-lock.json"
! grep -q 'deps/extra' "$BASE/project/.xspm/state/packages.json"

# Clean a package removes its nested package subtree but preserves the lock.
LOCK_BEFORE=$(sha256sum "$BASE/project/xspm-lock.json" | awk '{print $1}')
(cd "$BASE/project" && "$XMAKE_BIN" xspm --clean parent >/dev/null)
test ! -e "$BASE/project/deps/parent"
test -d "$BASE/project/vendor/fixed_leaf/.git"
test "$(sha256sum "$BASE/project/xspm-lock.json" | awk '{print $1}')" = "$LOCK_BEFORE"
(cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null)
test -d "$BASE/project/deps/parent/deps/leaf/.git"

# Existing repository origin is verified.
git -C "$BASE/project/deps/parent" remote set-url origin "file://$BASE/remotes/leaf.git"
if (cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null 2>&1); then
    echo "expected origin mismatch failure" >&2
    exit 1
fi

# Invalid escaping install paths are rejected before cloning.
cat >"$BASE/project/xspm.json" <<MANIFEST
{
  "version": 1,
  "dependencies": {
    "bad": {"source": "file://$BASE/remotes/leaf.git#main", "path": "../outside"}
  }
}
MANIFEST
if (cd "$BASE/project" && "$XMAKE_BIN" xspm >/dev/null 2>&1); then
    echo "expected escaping path failure" >&2
    exit 1
fi

echo "xspm tests passed"
