-- xmake-gdep integration entry.
-- Include this file from the consuming project's xmake.lua:
--     includes("tools/gdep/xmake.lua")

local _gdep_tooldir = os.scriptdir()

-- Include an xmake.lua supplied by a git dependency without making the
-- consuming project fail before `xmake gdep` has installed that dependency.
-- Paths are resolved from the consuming project's root directory.
function gdep_include(filepath)
    if not filepath or #filepath == 0 then
        return false
    end
    local fullpath = path.absolute(filepath, os.projectdir())
    if os.isfile(fullpath) then
        includes(fullpath)
        return true
    end
    return false
end

task("gdep")
    set_category("plugin")
    set_menu {
        usage = "xmake gdep [options]",
        description = "Synchronize recursive git dependencies from gdep.lua.",
        options = {
            {'u', "update", "k", nil, "Resolve refs from remotes again; update lock if it exists."},
            {'l', "lock",   "k", nil, "Create or refresh gdep.lock with resolved commits."},
            {'f', "force",  "k", nil, "Discard local dependency source changes before syncing."}
        }
    }
    on_run(function ()
        import("core.base.option")
        local main = import("gdep.main", {rootdir = path.join(_gdep_tooldir, "modules"), anonymous = true})
        main.run {
            update = option.get("update") and true or false,
            lock   = option.get("lock") and true or false,
            force  = option.get("force") and true or false
        }
    end)
