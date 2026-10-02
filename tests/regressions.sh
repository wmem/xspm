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
    mkdir -p "$src" "$BASE/remotes"
    git -C "$src" init -q -b main
    git -C "$src" config user.name xspm-test
    git -C "$src" config user.email xspm-test@example.invalid
    echo original >"$src/data.txt"
    git -C "$src" add .
    git -C "$src" commit -qm init
    git clone -q --bare "$src" "$BASE/remotes/$name.git"
}

publish_files() {
    local name=$1
    git -C "$BASE/src/$name" add .
    git -C "$BASE/src/$name" commit -qm fixture
    git -C "$BASE/src/$name" push -q "$BASE/remotes/$name.git" main
}

make_project() {
    local name=$1
    mkdir -p "$BASE/$name"
    cat >"$BASE/$name/xmake.lua" <<XMAKE
includes("$ROOT/xmake.lua")
XMAKE
}

sync_project() {
    local name=$1
    shift
    (cd "$BASE/$name" && "$XMAKE_BIN" xspm "$@") >"$BASE/last.log" 2>&1 || {
        cat "$BASE/last.log" >&2
        return 1
    }
}

expect_failure() {
    local name=$1
    local message=$2
    shift 2
    if (cd "$BASE/$name" && "$XMAKE_BIN" xspm "$@") >"$BASE/last.log" 2>&1; then
        echo "预期操作失败：$name $*" >&2
        cat "$BASE/last.log" >&2
        exit 1
    fi
    if ! grep -q "$message" "$BASE/last.log"; then
        cat "$BASE/last.log" >&2
        exit 1
    fi
}

make_remote basic

# 相对本地路径可重复同步，锁文件保留声明字符串，已安装提交支持离线同步。
make_project relative
cat >"$BASE/relative/xspm.json" <<'JSON'
{"dependencies": {"pkg": "../remotes/basic.git#main"}}
JSON
sync_project relative
sync_project relative
sync_project relative --lock
grep -q '"source": "../remotes/basic.git"' "$BASE/relative/xspm-lock.json"
sync_project relative --status
mv "$BASE/remotes/basic.git" "$BASE/remotes/basic.git.off"
sync_project relative
sync_project relative --status
mv "$BASE/remotes/basic.git.off" "$BASE/remotes/basic.git"

# 本地普通仓库和含空格的绝对路径也可重复同步。
make_project absolute
cp -R "$BASE/src/basic" "$BASE/local source"
cat >"$BASE/absolute/xspm.json" <<JSON
{"dependencies": {"pkg": "$BASE/local source#main"}}
JSON
sync_project absolute
sync_project absolute
sync_project absolute --status

# 嵌套 manifest 的相对源从包目录解析，不依赖命令执行目录。
make_remote relative-parent
cat >"$BASE/src/relative-parent/xspm.json" <<'JSON'
{"dependencies": {"leaf": "../leaf.git#main"}}
JSON
publish_files relative-parent
make_project nested-relative
mkdir -p "$BASE/nested-relative/deps"
git clone -q --bare "$BASE/remotes/basic.git" "$BASE/nested-relative/deps/leaf.git"
cat >"$BASE/nested-relative/xspm.json" <<JSON
{"dependencies": {"parent": "file://$BASE/remotes/relative-parent.git#main"}}
JSON
sync_project nested-relative
sync_project nested-relative
sync_project nested-relative --lock
sync_project nested-relative --status
test -d "$BASE/nested-relative/deps/parent/deps/leaf/.git"

# 删除远端分支或 tag 后不得回退到本地残留引用，失败不改 HEAD/锁文件。
make_remote deleted
git --git-dir="$BASE/remotes/deleted.git" tag v1 main
make_project deleted
cat >"$BASE/deleted/xspm.json" <<JSON
{"dependencies": {"branch": "file://$BASE/remotes/deleted.git#main", "tag": "file://$BASE/remotes/deleted.git#v1"}}
JSON
sync_project deleted --lock
LOCK_BEFORE=$(sha256sum "$BASE/deleted/xspm-lock.json")
OLD_HEAD=$(git -C "$BASE/deleted/deps/branch" rev-parse HEAD)
git --git-dir="$BASE/remotes/deleted.git" update-ref refs/heads/other "$OLD_HEAD"
git --git-dir="$BASE/remotes/deleted.git" symbolic-ref HEAD refs/heads/other
git --git-dir="$BASE/remotes/deleted.git" update-ref -d refs/heads/main
expect_failure deleted 'cannot resolve ref' --update branch
test "$(git -C "$BASE/deleted/deps/branch" rev-parse HEAD)" = "$OLD_HEAD"
test "$(sha256sum "$BASE/deleted/xspm-lock.json")" = "$LOCK_BEFORE"
git --git-dir="$BASE/remotes/deleted.git" update-ref -d refs/tags/v1
expect_failure deleted 'cannot resolve ref' --update tag
test "$(sha256sum "$BASE/deleted/xspm-lock.json")" = "$LOCK_BEFORE"

# 完整/短提交哈希和显式分支/tag ref 保持可用。
make_project refs
COMMIT=$(git --git-dir="$BASE/remotes/basic.git" rev-parse main)
git --git-dir="$BASE/remotes/basic.git" tag v1 main
cat >"$BASE/refs/xspm.json" <<JSON
{"dependencies": {"full": "file://$BASE/remotes/basic.git#$COMMIT", "short": "file://$BASE/remotes/basic.git#${COMMIT:0:12}", "branch": "file://$BASE/remotes/basic.git#refs/heads/main", "tag": "file://$BASE/remotes/basic.git#refs/tags/v1"}}
JSON
sync_project refs
sync_project refs
for name in full short branch tag; do
    test "$(git -C "$BASE/refs/deps/$name" rev-parse HEAD)" = "$COMMIT"
done
mv "$BASE/remotes/basic.git" "$BASE/remotes/basic.git.off"
expect_failure refs 'cannot resolve ref'
mv "$BASE/remotes/basic.git.off" "$BASE/remotes/basic.git"

# 新克隆必须重新初始化；clone 后 ref 解析失败的重试也不能复用旧状态。
make_remote hook
echo generated.txt >"$BASE/src/hook/.gitignore"
cat >"$BASE/src/hook/xspm.lua" <<'LUA'
function on_install(ctx)
    local counter = path.join(ctx.projectdir, "hook-count.txt")
    local count = os.isfile(counter) and tonumber(io.readfile(counter)) or 0
    io.writefile(counter, tostring(count + 1))
    io.writefile(path.join(ctx.rootdir, "generated.txt"), "initialized")
end
LUA
publish_files hook
make_project reinstall
cat >"$BASE/reinstall/xspm.json" <<JSON
{"dependencies": {"pkg": "file://$BASE/remotes/hook.git#main"}}
JSON
sync_project reinstall
test "$(cat "$BASE/reinstall/hook-count.txt")" = 1
mv "$BASE/reinstall/deps/pkg" "$BASE/reinstall/old-pkg"
sync_project reinstall
test -f "$BASE/reinstall/deps/pkg/generated.txt"
test "$(cat "$BASE/reinstall/hook-count.txt")" = 2
mv "$BASE/reinstall/deps/pkg" "$BASE/reinstall/old-pkg-2"
cat >"$BASE/reinstall/xspm.json" <<JSON
{"dependencies": {"pkg": "file://$BASE/remotes/hook.git#missing"}}
JSON
expect_failure reinstall 'cannot resolve ref'
cat >"$BASE/reinstall/xspm.json" <<JSON
{"dependencies": {"pkg": "file://$BASE/remotes/hook.git#main"}}
JSON
sync_project reinstall
test -f "$BASE/reinstall/deps/pkg/generated.txt"
test "$(cat "$BASE/reinstall/hook-count.txt")" = 3
sync_project reinstall
test "$(cat "$BASE/reinstall/hook-count.txt")" = 3

# 普通子目录不能继承主项目仓库身份，包含 --force 在内的同步都不得修改主项目。
git clone -q "$BASE/remotes/basic.git" "$BASE/ancestor"
make_project ancestor
git -C "$BASE/ancestor" config user.name xspm-test
git -C "$BASE/ancestor" config user.email xspm-test@example.invalid
cat >"$BASE/ancestor/xspm.json" <<JSON
{"dependencies": {"pkg": "$BASE/remotes/basic.git#main"}}
JSON
printf '.xmake/\n.xspm/\n' >"$BASE/ancestor/.gitignore"
git -C "$BASE/ancestor" add .
git -C "$BASE/ancestor" commit -qm project
mkdir -p "$BASE/ancestor/deps/pkg"
ROOT_HEAD=$(git -C "$BASE/ancestor" rev-parse HEAD)
expect_failure ancestor 'not a git worktree'
expect_failure ancestor 'not a git worktree' --force
expect_failure ancestor 'not-git' --status
test "$(git -C "$BASE/ancestor" rev-parse HEAD)" = "$ROOT_HEAD"
test -f "$BASE/ancestor/xspm.json"
test -f "$BASE/ancestor/xmake.lua"

# 正常的 linked worktree 根目录仍可作为已安装包。
make_project worktree
cat >"$BASE/worktree/xspm.json" <<JSON
{"dependencies": {"pkg": "$BASE/remotes/basic.git#main"}}
JSON
git -C "$BASE/src/basic" remote add origin "$BASE/remotes/basic.git"
mkdir -p "$BASE/worktree/deps"
git -C "$BASE/src/basic" worktree add -q --detach "$BASE/worktree/deps/pkg" main
test -f "$BASE/worktree/deps/pkg/.git"
sync_project worktree
sync_project worktree --status

# prune 必须在删除任何内容前拒绝移除仍包含声明子包的父目录，--force 也不能绕过。
make_remote parent
cat >"$BASE/src/parent/xspm.json" <<JSON
{"dependencies": {"child": "file://$BASE/remotes/basic.git#main"}}
JSON
publish_files parent
make_project prune
cat >"$BASE/prune/xspm.json" <<JSON
{"dependencies": {"parent": "file://$BASE/remotes/parent.git#main"}}
JSON
sync_project prune --lock
cat >"$BASE/prune/xspm.json" <<JSON
{"dependencies": {"child": {"source": "file://$BASE/remotes/basic.git#main", "path": "deps/parent/deps/child"}}}
JSON
echo valuable-edits >>"$BASE/prune/deps/parent/deps/child/data.txt"
STATE_BEFORE=$(sha256sum "$BASE/prune/.xspm/state/packages.json")
LOCK_BEFORE=$(sha256sum "$BASE/prune/xspm-lock.json")
expect_failure prune 'contains declared package' --prune
expect_failure prune 'contains declared package' --prune --force
grep -q valuable-edits "$BASE/prune/deps/parent/deps/child/data.txt"
test -d "$BASE/prune/deps/parent/.git"
test "$(sha256sum "$BASE/prune/.xspm/state/packages.json")" = "$STATE_BEFORE"
test "$(sha256sum "$BASE/prune/xspm-lock.json")" = "$LOCK_BEFORE"

# 无锁的状态正常；存在锁文件但缺少包条目时 status 必须失败且保持只读。
make_project status
cat >"$BASE/status/xspm.json" <<JSON
{"dependencies": {"pkg": "file://$BASE/remotes/basic.git#main"}}
JSON
sync_project status
sync_project status --status
grep -q unlocked "$BASE/last.log"
sync_project status --lock
echo '{"version": 1, "packages": {}}' >"$BASE/status/xspm-lock.json"
STATE_BEFORE=$(sha256sum "$BASE/status/.xspm/state/packages.json")
LOCK_BEFORE=$(sha256sum "$BASE/status/xspm-lock.json")
expect_failure status 'lock-missing' --status
expect_failure status 'is missing from'
test "$(sha256sum "$BASE/status/.xspm/state/packages.json")" = "$STATE_BEFORE"
test "$(sha256sum "$BASE/status/xspm-lock.json")" = "$LOCK_BEFORE"

echo "xspm regression tests passed"
