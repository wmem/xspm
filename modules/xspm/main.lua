import("core.base.json")

local _FORMAT_VERSION = 1
local _MANIFEST_NAME = "xspm.json"
local _LOCK_NAME = "xspm-lock.json"
local _HOOK_NAME = "xspm.lua"
local _DEFAULT_INSTALL_DIR = "deps"
local _STATE_FILE = ".xspm/state/packages.json"

local function _trim(s)
    return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function _git(args)
    return os.iorunv("git", args)
end

local function _git_in(repo, args)
    local argv = {"-C", repo}
    for _, arg in ipairs(args) do
        table.insert(argv, arg)
    end
    return _git(argv)
end

local function _try_git_in(repo, args)
    local ok = false
    local out, err, errors
    try {
        function ()
            out, err = _git_in(repo, args)
            ok = true
        end,
        catch {
            function (e)
                errors = e
            end
        }
    }
    if ok then
        return true, out, err
    end
    return false, nil, errors
end

local function _json_string(value)
    local encoded, errors = json.encode(value)
    if not encoded then
        raise("xspm: cannot encode json value: %s", errors or "json error")
    end
    -- xmake's JSON encoder escapes forward slashes. They are valid JSON but
    -- make source URLs and path keys unnecessarily hard to read in lock/state files.
    return encoded:gsub("\\/", "/")
end

local function _normalize_rel(value, label)
    if type(value) ~= "string" or #value == 0 then
        raise("xspm: %s must be a non-empty relative path", label)
    end
    local rel = value:gsub("\\", "/")
    if rel:sub(1, 1) == "/" or rel:match("^%a:/") then
        raise("xspm: %s must be relative: %s", label, value)
    end
    local parts = {}
    for part in rel:gmatch("[^/]+") do
        if part == ".." then
            raise("xspm: %s must not escape its manifest directory: %s", label, value)
        elseif part ~= "." and #part > 0 then
            table.insert(parts, part)
        end
    end
    if #parts == 0 then
        raise("xspm: %s resolves to an empty path", label)
    end
    return table.concat(parts, "/")
end

local function _manifest_load(filepath)
    local data, errors = json.loadfile(filepath)
    if not data then
        raise("xspm: cannot load %s: %s", filepath, errors or "invalid json")
    end
    if type(data) ~= "table" then
        raise("xspm: %s must contain a JSON object", filepath)
    end
    if data.version ~= nil and data.version ~= _FORMAT_VERSION then
        raise("xspm: unsupported manifest version in %s: %s", filepath, tostring(data.version))
    end
    if data.dependencies == nil then
        data.dependencies = {}
    end
    if type(data.dependencies) ~= "table" then
        raise("xspm: dependencies in %s must be an object", filepath)
    end
    data.installDir = _normalize_rel(data.installDir or _DEFAULT_INSTALL_DIR, "installDir in " .. filepath)
    return data
end

local function _validate_name(name, manifest)
    if type(name) ~= "string" or #name == 0 then
        raise("xspm: dependency names in %s must be non-empty strings", manifest)
    end
    if name == "." or name == ".." or name:find("/", 1, true) or name:find("\\", 1, true) then
        raise("xspm: invalid dependency name '%s' in %s", name, manifest)
    end
end

local function _split_source(source, manifest, name)
    if type(source) ~= "string" then
        raise("xspm: dependency '%s' in %s requires a source string", name, manifest)
    end
    local hash = source:match("^.*()#")
    if not hash then
        raise("xspm: dependency '%s' in %s must use <git-url>#<ref>", name, manifest)
    end
    local git = source:sub(1, hash - 1)
    local ref = source:sub(hash + 1)
    if #git == 0 or #ref == 0 then
        raise("xspm: dependency '%s' in %s must use non-empty <git-url>#<ref>", name, manifest)
    end
    return git, ref
end

local function _normalize_dep(name, value, manifest_data, manifest_path)
    _validate_name(name, manifest_path)
    local git, ref, install_rel
    if type(value) == "string" then
        git, ref = _split_source(value, manifest_path, name)
        install_rel = manifest_data.installDir .. "/" .. name
    elseif type(value) == "table" then
        if type(value.source) == "string" then
            git, ref = _split_source(value.source, manifest_path, name)
        else
            git = value.git or value.url
            ref = value.ref
            if type(git) ~= "string" or #git == 0 or type(ref) ~= "string" or #ref == 0 then
                raise("xspm: dependency '%s' in %s requires source='<git-url>#<ref>'", name, manifest_path)
            end
        end
        install_rel = value.path or (manifest_data.installDir .. "/" .. name)
    else
        raise("xspm: dependency '%s' in %s must be a string or object", name, manifest_path)
    end
    install_rel = _normalize_rel(install_rel, "path for dependency '" .. name .. "' in " .. manifest_path)
    return {name = name, git = git, ref = ref, install_rel = install_rel}
end

local function _sorted_dependencies(manifest_data, manifest_path)
    local names = {}
    for name, _ in pairs(manifest_data.dependencies) do
        table.insert(names, name)
    end
    table.sort(names)
    local deps = {}
    for _, name in ipairs(names) do
        table.insert(deps, _normalize_dep(name, manifest_data.dependencies[name], manifest_data, manifest_path))
    end
    return deps
end

local function _logical_child(parent, name)
    if not parent or #parent == 0 then
        return name
    end
    return parent .. "/" .. name
end

local function _path_key(projectdir, repo)
    local rel = path.relative(repo, projectdir):gsub("\\", "/")
    return rel
end

local function _is_git_repo(repo)
    local ok, out = _try_git_in(repo, {"rev-parse", "--is-inside-work-tree"})
    return ok and _trim(out) == "true"
end

local function _remote_url(repo)
    local ok, out = _try_git_in(repo, {"remote", "get-url", "origin"})
    if not ok then
        return nil
    end
    return _trim(out)
end

local function _managed_child_relpaths(repo)
    local manifest_path = path.join(repo, _MANIFEST_NAME)
    if not os.isfile(manifest_path) then
        return {}
    end
    local manifest = _manifest_load(manifest_path)
    local paths = {}
    for _, dep in ipairs(_sorted_dependencies(manifest, manifest_path)) do
        table.insert(paths, dep.install_rel)
    end
    return paths
end

local function _status_text(repo)
    local args = {"status", "--porcelain", "--untracked-files=all", "--", "."}
    for _, rel in ipairs(_managed_child_relpaths(repo)) do
        table.insert(args, ":(exclude)" .. rel)
        table.insert(args, ":(exclude)" .. rel .. "/**")
    end
    local ok, out = _try_git_in(repo, args)
    if not ok then
        raise("xspm: failed to inspect working tree %s", repo)
    end
    return _trim(out)
end

local function _clean_untracked(repo)
    local args = {"clean", "-fd"}
    for _, rel in ipairs(_managed_child_relpaths(repo)) do
        table.insert(args, "-e")
        table.insert(args, rel .. "/")
    end
    _git_in(repo, args)
end

local function _prepare_existing(repo, dep, force)
    if not _is_git_repo(repo) then
        raise("xspm: %s already exists but is not a git worktree", repo)
    end
    local remote = _remote_url(repo)
    if not remote then
        raise("xspm: %s has no origin remote", repo)
    end
    if remote ~= dep.git then
        raise("xspm: origin mismatch for '%s': expected '%s', got '%s'", dep.name, dep.git, remote)
    end
    local dirty = _status_text(repo)
    if #dirty > 0 then
        if not force then
            raise("xspm: package '%s' has local changes in %s; use --force to discard them\n%s", dep.name, repo, dirty)
        end
        cprint("${yellow}xspm: reset local changes: %s${clear}", repo)
        _git_in(repo, {"reset", "--hard", "HEAD"})
        _clean_untracked(repo)
    end
end

local function _ensure_repo(repo, dep, force)
    if os.exists(repo) then
        if not os.isdir(repo) then
            raise("xspm: package path exists and is not a directory: %s", repo)
        end
        _prepare_existing(repo, dep, force)
        return false
    end
    os.mkdir(path.directory(repo))
    cprint("${cyan}xspm: clone %s -> %s${clear}", dep.git, repo)
    _git({"clone", "--no-checkout", "--origin", "origin", dep.git, repo})
    return true
end

local function _has_commit(repo, commit)
    local ok = _try_git_in(repo, {"cat-file", "-e", commit .. "^{commit}"})
    return ok
end

local function _fetch_ref(repo, ref)
    cprint("${dim}xspm: fetch %s (%s)${clear}", repo, ref)
    local ok, _, errors = _try_git_in(repo, {"fetch", "--force", "--tags", "origin", ref})
    if ok then
        local out = _git_in(repo, {"rev-parse", "--verify", "FETCH_HEAD^{commit}"})
        return _trim(out)
    end

    local fetched = _try_git_in(repo, {"fetch", "--force", "--tags", "origin"})
    if fetched then
        local candidates = {ref, "origin/" .. ref}
        local branch = ref:match("^refs/heads/(.+)$")
        if branch then
            table.insert(candidates, "refs/remotes/origin/" .. branch)
        end
        for _, candidate in ipairs(candidates) do
            local resolved, out = _try_git_in(repo, {"rev-parse", "--verify", candidate .. "^{commit}"})
            if resolved then
                return _trim(out)
            end
        end
    end
    raise("xspm: cannot resolve ref '%s' in %s: %s", ref, repo, tostring(errors))
end

local function _ensure_locked_commit(repo, dep, commit)
    if _has_commit(repo, commit) then
        return
    end
    _try_git_in(repo, {"fetch", "--force", "origin", commit})
    if _has_commit(repo, commit) then
        return
    end
    _try_git_in(repo, {"fetch", "--force", "--tags", "origin", dep.ref})
    if _has_commit(repo, commit) then
        return
    end
    _try_git_in(repo, {"fetch", "--force", "--tags", "origin"})
    if not _has_commit(repo, commit) then
        raise("xspm: locked commit %s for '%s' is not available from %s", commit, dep.name, dep.git)
    end
end

local function _head(repo)
    local ok, out = _try_git_in(repo, {"rev-parse", "HEAD"})
    if not ok then
        return nil
    end
    return _trim(out)
end

local function _is_detached(repo)
    local ok = _try_git_in(repo, {"symbolic-ref", "-q", "HEAD"})
    return not ok
end

local function _checkout(repo, dep, commit)
    local current = _head(repo)
    if current == commit and _is_detached(repo) then
        cprint("${green}xspm: ok %s @ %s${clear}", dep.name, commit:sub(1, 12))
        return false
    end
    cprint("${cyan}xspm: checkout %s @ %s${clear}", dep.name, commit:sub(1, 12))
    _git_in(repo, {"checkout", "--detach", commit})
    return current ~= commit
end

local function _load_lock(filepath)
    if not os.isfile(filepath) then
        return nil
    end
    local data, errors = json.loadfile(filepath)
    if not data then
        raise("xspm: cannot load %s: %s", filepath, errors or "invalid json")
    end
    if data.version ~= _FORMAT_VERSION or type(data.packages) ~= "table" then
        raise("xspm: unsupported or invalid lock file: %s", filepath)
    end
    return data
end

local function _load_state(filepath)
    if not os.isfile(filepath) then
        return {version = _FORMAT_VERSION, packages = {}}
    end
    local data, errors = json.loadfile(filepath)
    if not data then
        raise("xspm: cannot load %s: %s", filepath, errors or "invalid json")
    end
    if data.version ~= _FORMAT_VERSION or type(data.packages) ~= "table" then
        raise("xspm: unsupported or invalid state file: %s", filepath)
    end
    return data
end

local function _sorted_keys(entries)
    local keys = {}
    for key, _ in pairs(entries) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return keys
end

local function _save_lock(filepath, entries)
    local keys = _sorted_keys(entries)
    local lines = {"{", "  \"version\": 1,", "  \"packages\": {"}
    for i, key in ipairs(keys) do
        local e = entries[key]
        local comma = i < #keys and "," or ""
        table.insert(lines, string.format(
            "    %s: {\"name\": %s, \"source\": %s, \"ref\": %s, \"commit\": %s}%s",
            _json_string(key), _json_string(e.name), _json_string(e.source), _json_string(e.ref), _json_string(e.commit), comma))
    end
    table.insert(lines, "  }")
    table.insert(lines, "}")
    table.insert(lines, "")
    os.mkdir(path.directory(filepath))
    io.writefile(filepath, table.concat(lines, "\n"))
    cprint("${green}xspm: wrote %s${clear}", filepath)
end

local function _save_state(filepath, entries)
    local keys = _sorted_keys(entries)
    local lines = {"{", "  \"version\": 1,", "  \"packages\": {"}
    for i, key in ipairs(keys) do
        local e = entries[key]
        local comma = i < #keys and "," or ""
        table.insert(lines, string.format(
            "    %s: {\"name\": %s, \"source\": %s, \"ref\": %s, \"commit\": %s, \"initialized\": %s}%s",
            _json_string(key), _json_string(e.name), _json_string(e.source), _json_string(e.ref),
            _json_string(e.commit), e.initialized and "true" or "false", comma))
    end
    table.insert(lines, "  }")
    table.insert(lines, "}")
    table.insert(lines, "")
    os.mkdir(path.directory(filepath))
    io.writefile(filepath, table.concat(lines, "\n"))
end

local function _lock_commit(ctx, key, dep)
    if not ctx.lock_data then
        return nil
    end
    local entry = ctx.lock_data.packages[key]
    if not entry then
        raise("xspm: '%s' is missing from %s; run `xmake xspm --update` or `xmake xspm --lock`", key, ctx.lock_path)
    end
    if entry.source ~= dep.git or entry.ref ~= dep.ref or entry.name ~= dep.name then
        raise("xspm: lock entry '%s' no longer matches xspm.json; run `xmake xspm --update` or `xmake xspm --lock`", key)
    end
    if type(entry.commit) ~= "string" or #entry.commit == 0 then
        raise("xspm: lock entry '%s' has no commit", key)
    end
    return entry.commit
end

local function _matches_selector(selector, dep, logical, key)
    if not selector then
        return true
    end
    return selector == dep.name or selector == logical or selector == key
end

local function _run_install_hook(ctx, dep, repo, key, commit, force_run)
    local state = ctx.state.packages[key]
    if not force_run and state and state.initialized and state.commit == commit and state.source == dep.git then
        return false
    end

    local hookpath = path.join(repo, _HOOK_NAME)
    if os.isfile(hookpath) then
        cprint("${cyan}xspm: initialize %s${clear}", dep.name)
        local hook = import("xspm", {rootdir = repo, anonymous = true})
        if hook.on_install ~= nil and type(hook.on_install) ~= "function" then
            raise("xspm: on_install in %s must be a function", hookpath)
        end
        if hook.on_install then
            hook.on_install {
                name = dep.name,
                rootdir = repo,
                projectdir = ctx.projectdir,
                commit = commit,
                source = dep.git,
                ref = dep.ref,
                path = key
            }
        end
    end

    ctx.state.packages[key] = {
        name = dep.name,
        source = dep.git,
        ref = dep.ref,
        commit = commit,
        initialized = true
    }
    _save_state(ctx.state_path, ctx.state.packages)
    return os.isfile(hookpath)
end

local function _register_path(ctx, repo, logical)
    local normalized = path.absolute(repo):gsub("\\", "/")
    local previous = ctx.paths[normalized]
    if previous and previous ~= logical then
        raise("xspm: package path collision: '%s' and '%s' both map to %s", previous, logical, repo)
    end
    ctx.paths[normalized] = logical
end

local function _sync_manifest(ctx, manifest_path, logical_parent, stack, depth, refresh_parent)
    if not os.isfile(manifest_path) then
        return
    end
    depth = depth or 0
    if depth > 64 then
        raise("xspm: dependency recursion is deeper than 64 levels near %s", manifest_path)
    end

    local manifest = _manifest_load(manifest_path)
    local manifest_dir = path.directory(manifest_path)
    for _, dep in ipairs(_sorted_dependencies(manifest, manifest_path)) do
        local logical = _logical_child(logical_parent, dep.name)
        local repo = path.absolute(path.join(manifest_dir, dep.install_rel))
        local key = _path_key(ctx.projectdir, repo)
        _register_path(ctx, repo, logical)

        for _, ancestor_git in ipairs(stack) do
            if ancestor_git == dep.git then
                raise("xspm: recursive dependency cycle detected at '%s' (%s)", logical, dep.git)
            end
        end

        local refresh_this = refresh_parent or ctx.refresh_all
        if ctx.update_target and not refresh_this and _matches_selector(ctx.update_target, dep, logical, key) then
            refresh_this = true
            ctx.update_matched = true
        end

        local created = _ensure_repo(repo, dep, ctx.force)
        local commit
        if refresh_this then
            commit = _fetch_ref(repo, dep.ref)
        elseif ctx.lock_data then
            commit = _lock_commit(ctx, key, dep)
            _ensure_locked_commit(repo, dep, commit)
        elseif ctx.update_target and not created then
            -- A selective update without a lock preserves existing unrelated
            -- package commits instead of unexpectedly refreshing them.
            commit = _head(repo)
            if not commit then
                commit = _fetch_ref(repo, dep.ref)
            end
        else
            commit = _fetch_ref(repo, dep.ref)
        end

        _checkout(repo, dep, commit)
        ctx.resolved[key] = {name = dep.name, source = dep.git, ref = dep.ref, commit = commit}
        ctx.desired[key] = {name = dep.name, repo = repo, logical = logical, dep = dep, commit = commit}

        local child_manifest = path.join(repo, _MANIFEST_NAME)
        if os.isfile(child_manifest) then
            local child_stack = {}
            for _, value in ipairs(stack) do
                table.insert(child_stack, value)
            end
            table.insert(child_stack, dep.git)
            _sync_manifest(ctx, child_manifest, logical, child_stack, depth + 1, refresh_this)
        end

        -- Initialization is a post-install hook: child source packages are in
        -- place before a package's hook runs.
        _run_install_hook(ctx, dep, repo, key, commit, false)
    end
end

local function _collect_manifest_tree(ctx, manifest_path, logical_parent, depth)
    if not os.isfile(manifest_path) then
        return
    end
    depth = depth or 0
    if depth > 64 then
        raise("xspm: dependency recursion is deeper than 64 levels near %s", manifest_path)
    end
    local manifest = _manifest_load(manifest_path)
    local manifest_dir = path.directory(manifest_path)
    for _, dep in ipairs(_sorted_dependencies(manifest, manifest_path)) do
        local logical = _logical_child(logical_parent, dep.name)
        local repo = path.absolute(path.join(manifest_dir, dep.install_rel))
        local key = _path_key(ctx.projectdir, repo)
        if ctx.desired[key] then
            raise("xspm: package path collision while reading manifests: %s", repo)
        end
        local node = {name = dep.name, repo = repo, key = key, logical = logical, dep = dep}
        ctx.desired[key] = node
        table.insert(ctx.order, node)
        if os.isdir(repo) then
            local child_manifest = path.join(repo, _MANIFEST_NAME)
            if os.isfile(child_manifest) then
                _collect_manifest_tree(ctx, child_manifest, logical, depth + 1)
            end
        end
    end
end

local function _package_local_status(ctx, node)
    local repo, dep, key = node.repo, node.dep, node.key
    if not os.isdir(repo) then
        return "missing", nil
    end
    if not _is_git_repo(repo) then
        return "not-git", nil
    end
    local remote = _remote_url(repo)
    if remote ~= dep.git then
        return "origin-mismatch", _head(repo)
    end
    local dirty = _status_text(repo)
    if #dirty > 0 then
        return "dirty", _head(repo)
    end
    local head = _head(repo)
    local locked = ctx.lock_data and ctx.lock_data.packages[key]
    if locked then
        if locked.source ~= dep.git or locked.ref ~= dep.ref or locked.name ~= dep.name then
            return "lock-mismatch", head
        end
        if head ~= locked.commit then
            return "commit-mismatch", head
        end
    end
    local state = ctx.state.packages[key]
    if not state or not state.initialized or state.commit ~= head or state.source ~= dep.git then
        return "init-required", head
    end
    if not locked then
        return "unlocked", head
    end
    return "ok", head
end

local function _do_status(ctx, manifest_path)
    _collect_manifest_tree(ctx, manifest_path, "", 0)
    cprint("${bright}PACKAGE  REF  STATUS  COMMIT  PATH${clear}")
    local bad = 0
    for _, node in ipairs(ctx.order) do
        local status, head = _package_local_status(ctx, node)
        if status ~= "ok" and status ~= "unlocked" then
            bad = bad + 1
        end
        print(string.format("%s  %s  %s  %s  %s", node.logical, node.dep.ref, status,
            head and head:sub(1, 12) or "-", node.key))
    end
    if bad > 0 then
        raise("xspm: %d package(s) require attention", bad)
    end
end

local function _do_list(ctx, manifest_path)
    _collect_manifest_tree(ctx, manifest_path, "", 0)
    if #ctx.order == 0 then
        print("xspm: no packages declared")
        return
    end
    for _, node in ipairs(ctx.order) do
        local head = os.isdir(node.repo) and _head(node.repo) or nil
        local lock = ctx.lock_data and ctx.lock_data.packages[node.key]
        local commit = lock and lock.commit or head
        local depth = 0
        for _ in node.logical:gmatch("/") do depth = depth + 1 end
        local prefix = string.rep("  ", depth)
        print(string.format("%s%s  %s#%s  -> %s%s", prefix, node.logical, node.dep.git, node.dep.ref,
            node.key, commit and (" @ " .. commit:sub(1, 12)) or ""))
    end
end

local function _validate_removal(repo, name, force)
    if not os.exists(repo) then
        return
    end
    if not os.isdir(repo) then
        raise("xspm: managed path for '%s' is not a directory: %s", name, repo)
    end
    if _is_git_repo(repo) then
        local dirty = _status_text(repo)
        if #dirty > 0 and not force then
            raise("xspm: package '%s' has local changes in %s; use --force to remove it\n%s", name, repo, dirty)
        end
    elseif not force then
        raise("xspm: managed path for '%s' is no longer a git worktree: %s; use --force to remove it", name, repo)
    end
end

local function _state_nodes(ctx)
    local nodes = {}
    for key, entry in pairs(ctx.state.packages) do
        table.insert(nodes, {
            key = key,
            name = entry.name,
            repo = path.absolute(path.join(ctx.projectdir, key)),
            entry = entry
        })
    end
    table.sort(nodes, function (a, b)
        if #a.key ~= #b.key then
            return #a.key > #b.key
        end
        return a.key > b.key
    end)
    return nodes
end

local function _do_clean(ctx, selector)
    local all = _state_nodes(ctx)
    local roots = {}
    if selector then
        for _, node in ipairs(all) do
            if selector == node.name or selector == node.key then
                table.insert(roots, node.key)
            end
        end
        if #roots == 0 then
            raise("xspm: package '%s' is not installed", selector)
        end
    end

    local selected = {}
    for _, node in ipairs(all) do
        local remove = not selector
        if selector then
            for _, root in ipairs(roots) do
                if node.key == root or node.key:sub(1, #root + 1) == root .. "/" then
                    remove = true
                    break
                end
            end
        end
        if remove then
            table.insert(selected, node)
        end
    end

    for _, node in ipairs(selected) do
        _validate_removal(node.repo, node.name, ctx.force)
    end
    for _, node in ipairs(selected) do
        if os.exists(node.repo) then
            cprint("${yellow}xspm: remove %s${clear}", node.key)
            os.rm(node.repo)
        end
        ctx.state.packages[node.key] = nil
    end
    _save_state(ctx.state_path, ctx.state.packages)
    cprint("${green}xspm: removed %d package(s)${clear}", #selected)
end

local function _do_prune(ctx, manifest_path)
    _collect_manifest_tree(ctx, manifest_path, "", 0)
    local stale = {}
    for _, node in ipairs(_state_nodes(ctx)) do
        if not ctx.desired[node.key] then
            table.insert(stale, node)
        end
    end
    for _, node in ipairs(stale) do
        _validate_removal(node.repo, node.name, ctx.force)
    end
    for _, node in ipairs(stale) do
        if os.exists(node.repo) then
            cprint("${yellow}xspm: prune %s${clear}", node.key)
            os.rm(node.repo)
        end
        ctx.state.packages[node.key] = nil
    end
    _save_state(ctx.state_path, ctx.state.packages)

    if ctx.lock_data then
        local kept = {}
        for key, entry in pairs(ctx.lock_data.packages) do
            if ctx.desired[key] then
                kept[key] = entry
            end
        end
        _save_lock(ctx.lock_path, kept)
        ctx.lock_data.packages = kept
    end
    cprint("${green}xspm: pruned %d package(s)${clear}", #stale)
end

local function _do_reinit(ctx, manifest_path, selector)
    _collect_manifest_tree(ctx, manifest_path, "", 0)
    local matched = 0
    for _, node in ipairs(ctx.order) do
        if not selector or selector == node.name or selector == node.logical or selector == node.key then
            matched = matched + 1
            if not os.isdir(node.repo) or not _is_git_repo(node.repo) then
                raise("xspm: cannot reinitialize missing package '%s' at %s", node.logical, node.repo)
            end
            _prepare_existing(node.repo, node.dep, ctx.force)
            local commit = _head(node.repo)
            _run_install_hook(ctx, node.dep, node.repo, node.key, commit, true)
        end
    end
    if selector and matched == 0 then
        raise("xspm: package '%s' was not found in the installed manifest tree", selector)
    end
    cprint("${green}xspm: reinitialized %d package(s)${clear}", matched)
end

local function _validate_action(opt)
    local names = {"update", "lock", "status", "list", "reinit", "prune", "clean"}
    local count = 0
    for _, name in ipairs(names) do
        if opt[name] then count = count + 1 end
    end
    if count > 1 then
        raise("xspm: choose only one primary operation at a time")
    end
    if opt.package and not (opt.update or opt.reinit or opt.clean) then
        raise("xspm: a package argument is only valid with --update, --reinit or --clean")
    end
end

function run(opt)
    opt = opt or {}
    _validate_action(opt)

    local projectdir = os.projectdir()
    local manifest_path = path.join(projectdir, _MANIFEST_NAME)
    local lock_path = path.join(projectdir, _LOCK_NAME)
    local state_path = path.join(projectdir, _STATE_FILE)
    if not os.isfile(manifest_path) then
        raise("xspm: %s not found", manifest_path)
    end

    local lock_data = _load_lock(lock_path)
    local state = _load_state(state_path)
    local ctx = {
        projectdir = projectdir,
        lock_path = lock_path,
        state_path = state_path,
        lock_data = lock_data,
        state = state,
        force = opt.force,
        resolved = {},
        desired = {},
        order = {},
        paths = {},
        refresh_all = opt.lock or (opt.update and not opt.package),
        update_target = opt.update and opt.package or nil,
        update_matched = false
    }

    if opt.status then
        _do_status(ctx, manifest_path)
        return
    elseif opt.list then
        _do_list(ctx, manifest_path)
        return
    elseif opt.reinit then
        _do_reinit(ctx, manifest_path, opt.package)
        return
    elseif opt.prune then
        _do_prune(ctx, manifest_path)
        return
    elseif opt.clean then
        _do_clean(ctx, opt.package)
        return
    end

    local git_ok = try {function () _git({"--version"}); return true end}
    if not git_ok then
        raise("xspm: git executable is required")
    end

    if lock_data and not opt.update and not opt.lock then
        cprint("${dim}xspm: using lock file %s${clear}", lock_path)
    elseif opt.lock then
        cprint("${dim}xspm: resolving all refs and refreshing lock${clear}")
    elseif opt.update then
        if opt.package then
            cprint("${dim}xspm: updating package subtree '%s'${clear}", opt.package)
        else
            cprint("${dim}xspm: updating all package refs${clear}")
        end
    else
        cprint("${dim}xspm: no lock file; resolving refs from remotes${clear}")
    end

    _sync_manifest(ctx, manifest_path, "", {}, 0, false)

    if ctx.update_target and not ctx.update_matched then
        raise("xspm: update package '%s' was not found", ctx.update_target)
    end

    if opt.lock or (lock_data and opt.update) then
        _save_lock(lock_path, ctx.resolved)
    end
    cprint("${green}xspm: synchronized %d package(s)${clear}", #table.keys(ctx.resolved))
end
