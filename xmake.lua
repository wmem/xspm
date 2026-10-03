-- xmake-xspm integration entry.
-- Include this file from the consuming project's xmake.lua:
--     includes("tools/xspm/xmake.lua")

local _xspm_tooldir = os.scriptdir()

-- Include an xmake.lua supplied by a source package without making the
-- consuming project fail before `xmake xspm` has installed that package.
-- Relative paths are resolved from the xmake.lua that calls xspm_include().
function xspm_include(filepath)
    if not filepath or #filepath == 0 then
        return false
    end
    local fullpath = path.absolute(filepath, os.scriptdir())
    if os.isfile(fullpath) then
        includes(fullpath)
        return true
    end
    return false
end

task("xspm")
    set_category("plugin")
    set_menu {
        usage = "xmake xspm [options] [package]",
        description = "Manage source packages declared by xspm.json.",
        options = {
            {'u', "update", "k", nil, "Resolve remote refs again; PACKAGE limits the update to that package subtree."},
            {'l', "lock",   "k", nil, "Resolve all refs, synchronize packages and create/refresh xspm-lock.json."},
            {'s', "status", "k", nil, "Check local package state without modifying files or accessing remotes."},
            {nil, "list",   "k", nil, "List the currently declared package tree without modifying it."},
            {'r', "reinit", "k", nil, "Run on_install() again; PACKAGE limits it to matching installed packages."},
            {'p', "prune",  "k", nil, "Remove packages no longer declared by the current manifest tree."},
            {'c', "clean",  "k", nil, "Remove installed packages; PACKAGE limits removal to matching package subtrees."},
            {'f', "force",  "k", nil, "Allow destructive operations to discard local source changes."},
            {nil, "no-dev", "k", nil, "Skip root development dependencies and preserve their installed files and lock entries."},
            {nil, "package", "v", nil, "Package selector used with --update, --reinit or --clean."}
        }
    }
    on_run(function ()
        import("core.base.option")
        local main = import("xspm.main", {rootdir = path.join(_xspm_tooldir, "modules"), anonymous = true})
        main.run {
            update  = option.get("update") and true or false,
            lock    = option.get("lock") and true or false,
            status  = option.get("status") and true or false,
            list    = option.get("list") and true or false,
            reinit  = option.get("reinit") and true or false,
            prune   = option.get("prune") and true or false,
            clean   = option.get("clean") and true or false,
            force   = option.get("force") and true or false,
            no_dev  = option.get("no-dev") and true or false,
            package = option.get("package")
        }
    end)
