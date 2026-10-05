-- 全局源码包命令，业务逻辑仍由 xspm.main 实现。
task("xspm")
set_category("plugin")
set_menu({
    usage = "xmake xspm [options] [package]",
    description = "Manage source packages declared by xspm.json.",
    options = {
        { "C", "config", "kv", "xspm.json", "Manifest file, relative to the project root." },
        {
            "u",
            "update",
            "k",
            nil,
            "Resolve remote refs again; PACKAGE limits the update to that package subtree.",
        },
        {
            "l",
            "lock",
            "k",
            nil,
            "Resolve all refs, synchronize packages and create/refresh xspm-lock.json.",
        },
        {
            "s",
            "status",
            "k",
            nil,
            "Check local package state without modifying files or accessing remotes.",
        },
        {
            nil,
            "list",
            "k",
            nil,
            "List the currently declared package tree without modifying it.",
        },
        {
            "r",
            "reinit",
            "k",
            nil,
            "Run on_install() again; PACKAGE limits it to matching installed packages.",
        },
        {
            "p",
            "prune",
            "k",
            nil,
            "Remove packages no longer declared by the current manifest tree.",
        },
        {
            "c",
            "clean",
            "k",
            nil,
            "Remove installed packages; PACKAGE limits removal to matching package subtrees.",
        },
        {
            "f",
            "force",
            "k",
            nil,
            "Allow destructive operations to discard local source changes.",
        },
        {
            nil,
            "no-dev",
            "k",
            nil,
            "Skip root development dependencies and preserve their installed files and lock entries.",
        },
        { nil, "package", "v", nil, "Package selector used with --update, --reinit or --clean." },
    },
})
on_run("main")
