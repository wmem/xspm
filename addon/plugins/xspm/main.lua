import("core.base.option")

function main()
    local modules = path.join(os.scriptdir(), "runtime/modules")
    assert(
        os.isdir(modules),
        "插件尚未准备：请通过索引仓库安装，或先执行 scripts/prepare-addon.lua"
    )
    import("xspm.main", { rootdir = modules, anonymous = true }).run({
        config = option.get("config"),
        update = option.get("update"),
        lock = option.get("lock"),
        status = option.get("status"),
        list = option.get("list"),
        reinit = option.get("reinit"),
        prune = option.get("prune"),
        clean = option.get("clean"),
        force = option.get("force"),
        no_dev = option.get("no-dev"),
        package = option.get("package"),
    })
end
