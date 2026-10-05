-- 索引配方和本地开发共用准备过程；业务源码只维护在原位置。
function main(output)
    local root = path.directory(os.scriptdir())
    assert(output, "用法：xmake lua scripts/prepare-addon.lua <输出目录>")
    output = path.absolute(output)
    assert(not os.exists(output), "输出目录已存在，拒绝覆盖：" .. output)
    os.mkdir(output)
    os.cp(path.join(root, "addon.lua"), output)
    os.cp(path.join(root, "addon"), output)
    local runtime = path.join(output, "addon/plugins", "xspm", "runtime")
    os.mkdir(runtime)
    for _, name in ipairs({ "modules" }) do
        os.cp(path.join(root, name), runtime)
    end
end

-- 分发配方使用公开清单与资源接口安装，保留 Addon 身份登记。
function install(package)
    import("core.package.addon")
    local stage = os.tmpfile() .. ".addon"
    local previous
    try({
        function()
            main(stage)
            previous = os.cd(stage)
            local manifest = addon.manifest(stage)
            assert(manifest.name == package:name(), "Addon 名称与分发配方不一致")
            for _, payload in ipairs(addon.payloads_of(addon.payloadroot(stage))) do
                os.cp(path.join(addon.payloadroot(stage), payload), package:installdir())
            end
            package:data_set("addon.manifest", manifest)
        end,
        finally({
            function(ok, errors)
                if previous then
                    os.cd(previous)
                end
                os.tryrm(stage)
                if not ok then
                    raise(errors)
                end
            end,
        }),
    })
end
