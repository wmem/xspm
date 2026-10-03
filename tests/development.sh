#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
XMAKE_BIN=${XMAKE_BIN:-xmake}
BASE=$(mktemp -d)
trap 'status=$?; if (( status != 0 )) && test -f "$BASE/last.log"; then cat "$BASE/last.log" >&2; fi; rm -rf "$BASE"' EXIT
export XMAKE_ROOT=${XMAKE_ROOT:-y}

make_remote() {
    local name=$1
    mkdir -p "$BASE/src/$name" "$BASE/remotes"
    git -C "$BASE/src/$name" init -q -b main
    git -C "$BASE/src/$name" config user.name xspm-test
    git -C "$BASE/src/$name" config user.email xspm-test@example.invalid
    echo original >"$BASE/src/$name/data.txt"
    git -C "$BASE/src/$name" add .
    git -C "$BASE/src/$name" commit -qm init
    git clone -q --bare "$BASE/src/$name" "$BASE/remotes/$name.git"
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
    cat >"$BASE/$name/xspm.json" <<JSON
{
  "dependencies": {"lib": "file://$BASE/remotes/lib.git#main"},
  "devDependencies": {"tool": {"source": "file://$BASE/remotes/tool.git#main", "path": "tools/tool"}}
}
JSON
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
    local name=$1 message=$2
    shift 2
    if (cd "$BASE/$name" && "$XMAKE_BIN" xspm "$@") >"$BASE/last.log" 2>&1; then
        echo "预期操作失败：$name $*" >&2
        exit 1
    fi
    rg -q -- "$message" "$BASE/last.log"
}

edit_json() {
    local file=$1 filter=$2
    jq "$filter" "$file" >"$BASE/edited.json"
    mv "$BASE/edited.json" "$file"
}

make_remote leaf
make_remote lib
make_remote tool
for name in lib tool; do
    cat >"$BASE/src/$name/xspm.json" <<JSON
{
  "dependencies": {"leaf": "file://$BASE/remotes/leaf.git#main"},
  "devDependencies": {"unavailable": "file://$BASE/nonexistent.git#main"}
}
JSON
    echo generated/ >"$BASE/src/$name/.gitignore"
    cat >"$BASE/src/$name/xspm.lua" <<'LUA'
function on_install(ctx)
    assert(os.isdir(path.join(ctx.rootdir, "deps/leaf/.git")), "子依赖应先安装")
    assert(not os.exists(path.join(ctx.rootdir, "deps/unavailable")), "不能安装子包的开发依赖")
    local counter = path.join(ctx.projectdir, ctx.name .. "-hooks.txt")
    local count = os.isfile(counter) and tonumber(io.readfile(counter)) or 0
    io.writefile(counter, tostring(count + 1))
    os.mkdir(path.join(ctx.rootdir, "generated"))
    io.writefile(path.join(ctx.rootdir, "generated/ready.txt"), ctx.commit)
end
LUA
    publish_files "$name"
done

# 根项目安装两类依赖；开发工具的普通依赖属于开发子树，子包的开发依赖不传播。
make_project full
sync_project full --lock
for repo in deps/lib deps/lib/deps/leaf tools/tool tools/tool/deps/leaf; do
    test -d "$BASE/full/$repo/.git"
done
test ! -e "$BASE/full/deps/lib/deps/unavailable"
test ! -e "$BASE/full/tools/tool/deps/unavailable"
jq -e '.packages | length == 4' "$BASE/full/xspm-lock.json" >/dev/null
for file in xspm-lock.json .xspm/state/packages.json; do
    jq -e '.packages["tools/tool"].dev == true and .packages["tools/tool/deps/leaf"].dev == true and
        .packages["deps/lib"].dev != true and .packages["deps/lib/deps/leaf"].dev != true' "$BASE/full/$file" >/dev/null
done
sync_project full
test "$(cat "$BASE/full/tool-hooks.txt")" = 1
sync_project full --status
rg -q 'tools/tool  dev' "$BASE/last.log"
sync_project full --list
rg -q 'tool/leaf.*\[dev\]' "$BASE/last.log"

# --no-dev 的冷安装不克隆开发工具；只锁普通依赖，之后显式更新可补全开发子树。
make_project normal
sync_project normal --no-dev --lock
test -d "$BASE/normal/deps/lib/deps/leaf/.git"
test ! -e "$BASE/normal/tools/tool"
jq -e '.packages | length == 2' "$BASE/normal/xspm-lock.json" >/dev/null
sync_project normal --no-dev --status
expect_failure normal 'missing' --status
expect_failure normal "is missing from"
sync_project normal --update tool
test -d "$BASE/normal/tools/tool/deps/leaf/.git"
sync_project normal --status

# 跳过开发依赖的同步、状态、列表和 prune 均不访问缺失远端、不处理脏开发包。
LOCK_BEFORE=$(sha256sum "$BASE/full/xspm-lock.json")
STATE_BEFORE=$(sha256sum "$BASE/full/.xspm/state/packages.json")
echo valuable-edits >>"$BASE/full/tools/tool/data.txt"
mv "$BASE/remotes/tool.git" "$BASE/remotes/tool.git.off"
sync_project full --no-dev
sync_project full --no-dev --force
sync_project full --no-dev --status
sync_project full --no-dev --list
if rg -q 'tools/tool' "$BASE/last.log"; then exit 1; fi
test "$(sha256sum "$BASE/full/xspm-lock.json")" = "$LOCK_BEFORE"
test "$(sha256sum "$BASE/full/.xspm/state/packages.json")" = "$STATE_BEFORE"
sync_project full --no-dev --prune
test "$(sha256sum "$BASE/full/xspm-lock.json")" = "$LOCK_BEFORE"
rg -q valuable-edits "$BASE/full/tools/tool/data.txt"
mv "$BASE/remotes/tool.git.off" "$BASE/remotes/tool.git"
expect_failure full 'dirty' --status
sync_project full --force

# 更新或刷新普通依赖时保留开发锁；默认选择性更新开发工具会更新其普通子树。
OLD_LEAF=$(git -C "$BASE/full/tools/tool/deps/leaf" rev-parse HEAD)
OLD_TOOL=$(git -C "$BASE/full/tools/tool" rev-parse HEAD)
for name in leaf tool; do
    echo updated >>"$BASE/src/$name/data.txt"
    publish_files "$name"
done
mv "$BASE/remotes/tool.git" "$BASE/remotes/tool.git.off"
sync_project full --no-dev --update
jq -e --arg c "$OLD_LEAF" '.packages["tools/tool/deps/leaf"].commit == $c' "$BASE/full/xspm-lock.json" >/dev/null
sync_project full --no-dev --lock
jq -e --arg c "$OLD_TOOL" '.packages["tools/tool"].commit == $c' "$BASE/full/xspm-lock.json" >/dev/null
mv "$BASE/remotes/tool.git.off" "$BASE/remotes/tool.git"
test "$(git -C "$BASE/full/tools/tool" rev-parse HEAD)" = "$OLD_TOOL"
sync_project full --update tool
test "$(git -C "$BASE/full/tools/tool" rev-parse HEAD)" != "$OLD_TOOL"
test "$(git -C "$BASE/full/tools/tool/deps/leaf" rev-parse HEAD)" != "$OLD_LEAF"

# reinit/clean 遵循范围；clean 保留锁，开发包的本地修改继续受保护。
TOOL_HOOKS=$(cat "$BASE/full/tool-hooks.txt")
LIB_HOOKS=$(cat "$BASE/full/lib-hooks.txt")
sync_project full --no-dev --reinit
test "$(cat "$BASE/full/tool-hooks.txt")" = "$TOOL_HOOKS"
test "$(cat "$BASE/full/lib-hooks.txt")" = "$((LIB_HOOKS + 1))"
expect_failure full 'was not found' --no-dev --reinit tool
expect_failure full 'was not found' --no-dev --update tool
expect_failure full 'selected dependency scope' --no-dev --clean tool
LOCK_BEFORE=$(sha256sum "$BASE/full/xspm-lock.json")
sync_project full --no-dev --clean
test ! -e "$BASE/full/deps/lib"
test -d "$BASE/full/tools/tool/deps/leaf/.git"
test "$(sha256sum "$BASE/full/xspm-lock.json")" = "$LOCK_BEFORE"
sync_project full --no-dev
sync_project full --reinit tool
test "$(cat "$BASE/full/tool-hooks.txt")" = "$((TOOL_HOOKS + 1))"
echo valuable-edits >>"$BASE/full/tools/tool/data.txt"
expect_failure full 'local changes' --clean tool
sync_project full --force --clean tool
test ! -e "$BASE/full/tools/tool"
sync_project full

# 开发依赖从清单移除后，--no-dev 仍保留其历史记录；普通 prune 才删除它。
edit_json "$BASE/full/xspm.json" 'del(.devDependencies.tool)'
sync_project full --no-dev --update
sync_project full --no-dev --prune
test -d "$BASE/full/tools/tool/deps/leaf/.git"
jq -e '.packages["tools/tool"].dev == true' "$BASE/full/xspm-lock.json" >/dev/null
sync_project full --prune
test ! -e "$BASE/full/tools/tool"
jq -e '.packages["tools/tool"] == null and .packages["tools/tool/deps/leaf"] == null' "$BASE/full/xspm-lock.json" >/dev/null
jq -e '.packages["tools/tool"] == null' "$BASE/full/.xspm/state/packages.json" >/dev/null

# 无 dev 元数据的旧锁/状态可按当前根清单识别开发子树，且不重复执行初始化钩子。
make_project legacy
sync_project legacy --lock
for file in xspm-lock.json .xspm/state/packages.json; do
    edit_json "$BASE/legacy/$file" '.packages |= with_entries(.value |= del(.dev))'
done
STATE_BEFORE=$(sha256sum "$BASE/legacy/.xspm/state/packages.json")
LOCK_BEFORE=$(sha256sum "$BASE/legacy/xspm-lock.json")
sync_project legacy --no-dev --status
sync_project legacy --no-dev --list
test "$(sha256sum "$BASE/legacy/.xspm/state/packages.json")" = "$STATE_BEFORE"
test "$(sha256sum "$BASE/legacy/xspm-lock.json")" = "$LOCK_BEFORE"
sync_project legacy
jq -e '.packages["tools/tool/deps/leaf"].dev == true' "$BASE/legacy/.xspm/state/packages.json" >/dev/null
mv "$BASE/remotes/tool.git" "$BASE/remotes/tool.git.off"
sync_project legacy --no-dev --update
sync_project legacy --no-dev --prune
mv "$BASE/remotes/tool.git.off" "$BASE/remotes/tool.git"
jq -e '.packages["tools/tool/deps/leaf"].dev == true' "$BASE/legacy/xspm-lock.json" >/dev/null
sync_project legacy
test "$(cat "$BASE/legacy/tool-hooks.txt")" = 1

# 同一路径在普通/开发依赖之间迁移后，当前清单覆盖历史分类。
edit_json "$BASE/legacy/xspm.json" '.dependencies.tool = .devDependencies.tool | del(.devDependencies.tool)'
sync_project legacy --no-dev --update
jq -e '.packages["tools/tool"].dev != true and .packages["tools/tool/deps/leaf"].dev != true' "$BASE/legacy/xspm-lock.json" >/dev/null
jq -e '.packages["tools/tool"].dev != true and .packages["tools/tool/deps/leaf"].dev != true' "$BASE/legacy/.xspm/state/packages.json" >/dev/null
edit_json "$BASE/legacy/xspm.json" '.devDependencies.tool = .dependencies.tool | del(.dependencies.tool)'
sync_project legacy --no-dev --lock
jq -e '.packages["tools/tool"].dev == true' "$BASE/legacy/xspm-lock.json" >/dev/null
sync_project legacy
jq -e '.packages["tools/tool"].dev == true and .packages["tools/tool/deps/leaf"].dev == true' "$BASE/legacy/.xspm/state/packages.json" >/dev/null
test "$(cat "$BASE/legacy/tool-hooks.txt")" = 1

# 开发依赖的钩子失败必须重试，不得提前写入初始化状态。
make_remote failing
cat >"$BASE/src/failing/xspm.lua" <<'LUA'
function on_install(ctx)
    assert(os.isfile(path.join(ctx.projectdir, "allow-hook")), "开发钩子失败")
end
LUA
publish_files failing
make_project failing
cat >"$BASE/failing/xspm.json" <<JSON
{"devDependencies": {"tool": "$BASE/remotes/failing.git#main"}}
JSON
expect_failure failing '开发钩子失败'
if test -f "$BASE/failing/.xspm/state/packages.json"; then
    jq -e '.packages["deps/tool"] == null' "$BASE/failing/.xspm/state/packages.json" >/dev/null
fi
touch "$BASE/failing/allow-hook"
sync_project failing
jq -e '.packages["deps/tool"].initialized and .packages["deps/tool"].dev' "$BASE/failing/.xspm/state/packages.json" >/dev/null

# 消费带开发依赖的源码包时，只安装其普通依赖，即使根项目默认包含自己的开发依赖。
make_remote consumer-package
cp "$BASE/normal/xspm.json" "$BASE/src/consumer-package/xspm.json"
publish_files consumer-package
make_project consumer
cat >"$BASE/consumer/xspm.json" <<JSON
{"dependencies": {"pkg": "$BASE/remotes/consumer-package.git#main"}}
JSON
mv "$BASE/remotes/tool.git" "$BASE/remotes/tool.git.off"
sync_project consumer --lock
sync_project consumer --status
test -d "$BASE/consumer/deps/pkg/deps/lib/deps/leaf/.git"
test ! -e "$BASE/consumer/deps/pkg/tools/tool"
mv "$BASE/remotes/tool.git.off" "$BASE/remotes/tool.git"

# 清单格式、重复名称以及跨类别重叠路径在克隆之前报错，--no-dev 也不能绕过。
make_project invalid
echo '{"devDependencies": "bad"}' >"$BASE/invalid/xspm.json"
expect_failure invalid 'devDependencies.*must be an object'
cat >"$BASE/invalid/xspm.json" <<JSON
{"dependencies": {"same": "$BASE/remotes/lib.git#main"}, "devDependencies": {"same": "$BASE/remotes/tool.git#main"}}
JSON
expect_failure invalid 'declared in both' --no-dev
for tool_path in deps/lib deps/lib/tool; do
    cat >"$BASE/invalid/xspm.json" <<JSON
{"dependencies": {"lib": "$BASE/remotes/lib.git#main"}, "devDependencies": {"tool": {"source": "$BASE/remotes/tool.git#main", "path": "$tool_path"}}}
JSON
    expect_failure invalid 'paths overlap' --no-dev
    test ! -e "$BASE/invalid/deps/lib"
done
echo '{"devDependencies": {"tool": {"source": "repo#main", "path": "../escape"}}}' >"$BASE/invalid/xspm.json"
expect_failure invalid 'must not escape' --no-dev

# 历史普通父目录包含当前开发包时，--no-dev clean/prune 均拒绝连带删除，--force 也不能绕过。
make_project containment
cat >"$BASE/containment/xspm.json" <<JSON
{"dependencies": {"lib": "$BASE/remotes/lib.git#main"}}
JSON
sync_project containment --lock
cat >"$BASE/containment/xspm.json" <<JSON
{"devDependencies": {"leaf": {"source": "$BASE/remotes/leaf.git#main", "path": "deps/lib/deps/leaf"}}}
JSON
LOCK_BEFORE=$(sha256sum "$BASE/containment/xspm-lock.json")
STATE_BEFORE=$(sha256sum "$BASE/containment/.xspm/state/packages.json")
for action in clean prune; do
    expect_failure containment 'contains development package' --no-dev --"$action" --force
done
test -d "$BASE/containment/deps/lib/deps/leaf/.git"
test "$(sha256sum "$BASE/containment/xspm-lock.json")" = "$LOCK_BEFORE"
test "$(sha256sum "$BASE/containment/.xspm/state/packages.json")" = "$STATE_BEFORE"

echo "xspm development dependency tests passed"
