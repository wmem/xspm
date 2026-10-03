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
    for _, field in ipairs({"dependencies", "devDependencies"}) do
        if data[field] == nil then
            data[field] = {}
        end
        if type(data[field]) ~= "table" then
            raise("xspm: %s in %s must be an object", field, filepath)
        end
    end
    for name, _ in pairs(data.devDependencies) do
        if data.dependencies[name] ~= nil then
            raise("xspm: dependency '%s' is declared in both dependencies and devDependencies in %s", name, filepath)
        end
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

local function _git_source(source, basedir)
    -- URL 和 scp 风格的 SSH 地址交给 Git；本地路径按声明目录解析。
    if source:match("^%a[%w+.-]*://") or
        (source:match("^[^/\\]+:") and not source:match("^%a:[/\\]")) then
        return source
    end
    return path.absolute(source, basedir)
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
    return {name = name, git = git, git_source = _git_source(git, path.directory(manifest_path)),
        ref = ref, install_rel = install_rel}
end

local function _sorted_dependencies(manifest_data, manifest_path, include_dev)
    local deps = {}
    local all = {}
    for _, field in ipairs({"dependencies", "devDependencies"}) do
        for name, value in pairs(manifest_data[field]) do
            local dep = _normalize_dep(name, value, manifest_data, manifest_path)
            dep.dev = field == "devDependencies"
            table.insert(all, dep)
            if not dep.dev or include_dev then
                table.insert(deps, dep)
            end
        end
    end
    -- 两类根目录不能互相包含，否则跳过开发依赖时无法安全同步或清理。
    for i, a in ipairs(all) do
        for j = i + 1, #all do
            local b = all[j]
            if a.dev ~= b.dev and (a.install_rel == b.install_rel or
                a.install_rel:sub(1, #b.install_rel + 1) == b.install_rel .. "/" or
                b.install_rel:sub(1, #a.install_rel + 1) == a.install_rel .. "/") then
                raise("xspm: dependency paths overlap across dependencies and devDependencies: '%s' and '%s' in %s",
                    a.name, b.name, manifest_path)
            end
        end
    end
    table.sort(deps, function (a, b) return a.name < b.name end)
    return deps
end

local function _is_under(key, root)
    return key == root or key:sub(1, #root + 1) == root .. "/"
end

local function _is_development_key(ctx, key, entry)
    -- 当前根清单优先于旧元数据，支持两类依赖之间迁移及旧锁文件升级。
    for _, dep in ipairs(ctx.root_dependencies) do
        if _is_under(key, dep.install_rel) then
            return dep.dev
        end
    end
    return entry and entry.dev == true or false
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
    -- 仓库根目录的 prefix 为空；普通子目录不能继承上层仓库身份。
    local ok, out = _try_git_in(repo, {"rev-parse", "--is-inside-work-tree", "--show-prefix"})
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
    if _git_source(remote, repo) ~= dep.git_source then
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
    -- 初始检出保证后续 ref/锁解析失败时，重试不会把未检出文件误判为本地删除。
    _git({"clone", "--origin", "origin", dep.git_source, repo})
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

    -- 仅提交哈希可以在完整 fetch 后从对象库解析，不能使用残留分支或 tag。
    if #ref >= 4 and #ref <= 64 and ref:match("^%x+$") then
        local fetched = _try_git_in(repo, {"fetch", "--force", "--tags", "origin"})
        if fetched then
            local resolved, out = _try_git_in(repo, {"rev-parse", "--disambiguate=" .. ref})
            if resolved then
                local objects = {}
                for object in out:gmatch("[^\r\n]+") do
                    table.insert(objects, object)
                end
                if #objects == 1 then
                    local commit_ok, commit = _try_git_in(repo, {"rev-parse", "--verify", objects[1] .. "^{commit}"})
                    if commit_ok then
                        return _trim(commit)
                    end
                end
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
            "    %s: {\"name\": %s, \"source\": %s, \"ref\": %s, \"commit\": %s%s}%s",
            _json_string(key), _json_string(e.name), _json_string(e.source), _json_string(e.ref), _json_string(e.commit),
            e.dev and ', "dev": true' or "", comma))
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
            "    %s: {\"name\": %s, \"source\": %s, \"ref\": %s, \"commit\": %s, \"initialized\": %s%s}%s",
            _json_string(key), _json_string(e.name), _json_string(e.source), _json_string(e.ref),
            _json_string(e.commit), e.initialized and "true" or "false", e.dev and ', "dev": true' or "", comma))
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

local function _run_install_hook(ctx, dep, repo, key, commit, force_run, development)
    local state = ctx.state.packages[key]
    if not force_run and state and state.initialized and state.commit == commit and state.source == dep.git then
        if (state.dev == true) ~= (development == true) then
            state.dev = development and true or nil
            _save_state(ctx.state_path, ctx.state.packages)
        end
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
        initialized = true,
        dev = development and true or nil
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

local function _sync_manifest(ctx, manifest_path, logical_parent, stack, depth, refresh_parent, development)
    if not os.isfile(manifest_path) then
        return
    end
    depth = depth or 0
    if depth > 64 then
        raise("xspm: dependency recursion is deeper than 64 levels near %s", manifest_path)
    end

    local manifest = _manifest_load(manifest_path)
    local manifest_dir = path.directory(manifest_path)
    for _, dep in ipairs(_sorted_dependencies(manifest, manifest_path, depth == 0 and not ctx.no_dev)) do
        local is_dev = development or dep.dev
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
        if created and ctx.state.packages[key] then
            -- 新工作区不能复用旧初始化状态；持久化以便后续失败重试也能正确初始化。
            ctx.state.packages[key] = nil
            _save_state(ctx.state_path, ctx.state.packages)
        end
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
        ctx.resolved[key] = {name = dep.name, source = dep.git, ref = dep.ref, commit = commit, dev = is_dev and true or nil}
        ctx.desired[key] = {name = dep.name, repo = repo, logical = logical, dep = dep, commit = commit, dev = is_dev}

        local child_manifest = path.join(repo, _MANIFEST_NAME)
        if os.isfile(child_manifest) then
            local child_stack = {}
            for _, value in ipairs(stack) do
                table.insert(child_stack, value)
            end
            table.insert(child_stack, dep.git)
            _sync_manifest(ctx, child_manifest, logical, child_stack, depth + 1, refresh_this, is_dev)
        end

        -- Initialization is a post-install hook: child source packages are in
        -- place before a package's hook runs.
        _run_install_hook(ctx, dep, repo, key, commit, false, is_dev)
    end
end

local function _collect_manifest_tree(ctx, manifest_path, logical_parent, depth, development)
    if not os.isfile(manifest_path) then
        return
    end
    depth = depth or 0
    if depth > 64 then
        raise("xspm: dependency recursion is deeper than 64 levels near %s", manifest_path)
    end
    local manifest = _manifest_load(manifest_path)
    local manifest_dir = path.directory(manifest_path)
    for _, dep in ipairs(_sorted_dependencies(manifest, manifest_path, depth == 0 and not ctx.no_dev)) do
        local is_dev = development or dep.dev
        local logical = _logical_child(logical_parent, dep.name)
        local repo = path.absolute(path.join(manifest_dir, dep.install_rel))
        local key = _path_key(ctx.projectdir, repo)
        if ctx.desired[key] then
            raise("xspm: package path collision while reading manifests: %s", repo)
        end
        local node = {name = dep.name, repo = repo, key = key, logical = logical, dep = dep, dev = is_dev}
        ctx.desired[key] = node
        table.insert(ctx.order, node)
        if os.isdir(repo) then
            local child_manifest = path.join(repo, _MANIFEST_NAME)
            if os.isfile(child_manifest) then
                _collect_manifest_tree(ctx, child_manifest, logical, depth + 1, is_dev)
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
    if not remote or _git_source(remote, repo) ~= dep.git_source then
        return "origin-mismatch", _head(repo)
    end
    local dirty = _status_text(repo)
    if #dirty > 0 then
        return "dirty", _head(repo)
    end
    local head = _head(repo)
    local locked = ctx.lock_data and ctx.lock_data.packages[key]
    if ctx.lock_data and not locked then
        return "lock-missing", head
    end
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
    cprint("${bright}PACKAGE  REF  STATUS  COMMIT  PATH  SCOPE${clear}")
    local bad = 0
    for _, node in ipairs(ctx.order) do
        local status, head = _package_local_status(ctx, node)
        if status ~= "ok" and status ~= "unlocked" then
            bad = bad + 1
        end
        print(string.format("%s  %s  %s  %s  %s  %s", node.logical, node.dep.ref, status,
            head and head:sub(1, 12) or "-", node.key, node.dev and "dev" or "normal"))
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
        print(string.format("%s%s  %s#%s  -> %s%s%s", prefix, node.logical, node.dep.git, node.dep.ref,
            node.key, commit and (" @ " .. commit:sub(1, 12)) or "", node.dev and " [dev]" or ""))
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
        local safe_key = _normalize_rel(key, "package path in xspm state")
        if safe_key ~= key:gsub("\\", "/") then
            raise("xspm: invalid package path in state: %s", key)
        end
        table.insert(nodes, {
            key = safe_key,
            name = entry.name,
            repo = path.absolute(path.join(ctx.projectdir, safe_key)),
            dev = _is_development_key(ctx, safe_key, entry),
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

local function _validate_development_removal(ctx, node)
    if not ctx.no_dev then
        return
    end
    local function protect(key)
        if _is_under(key, node.key) then
            raise("xspm: cannot remove '%s' with --no-dev: it contains development package '%s'", node.key, key)
        end
    end
    for _, dep in ipairs(ctx.root_dependencies) do
        if dep.dev then
            protect(dep.install_rel)
        end
    end
    for key, entry in pairs(ctx.state.packages) do
        if _is_development_key(ctx, key, entry) then
            protect(key)
        end
    end
end

local function _do_clean(ctx, selector)
    local all = _state_nodes(ctx)
    local roots = {}
    if selector then
        for _, node in ipairs(all) do
            if not (ctx.no_dev and node.dev) and (selector == node.name or selector == node.key) then
                table.insert(roots, node.key)
            end
        end
        if #roots == 0 then
            raise("xspm: package '%s' is not installed in the selected dependency scope", selector)
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
        if remove and not (ctx.no_dev and node.dev) then
            table.insert(selected, node)
        end
    end

    for _, node in ipairs(selected) do
        _validate_development_removal(ctx, node)
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
        if not ctx.desired[node.key] and not (ctx.no_dev and node.dev) then
            table.insert(stale, node)
        end
    end
    for _, node in ipairs(stale) do
        _validate_development_removal(ctx, node)
        for desired_key, _ in pairs(ctx.desired) do
            if desired_key:sub(1, #node.key + 1) == node.key .. "/" then
                raise("xspm: cannot prune '%s': it contains declared package '%s'; move that package first",
                    node.key, desired_key)
            end
        end
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
            if ctx.desired[key] or (ctx.no_dev and _is_development_key(ctx, key, entry)) then
                entry.dev = _is_development_key(ctx, key, entry) and true or nil
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
            _run_install_hook(ctx, node.dep, node.repo, node.key, commit, true, node.dev)
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
    local root_dependencies = _sorted_dependencies(_manifest_load(manifest_path), manifest_path, true)
    local ctx = {
        projectdir = projectdir,
        lock_path = lock_path,
        state_path = state_path,
        lock_data = lock_data,
        state = state,
        root_dependencies = root_dependencies,
        no_dev = opt.no_dev,
        force = opt.force,
        resolved = {},
        desired = {},
        order = {},
        paths = {},
        refresh_all = opt.lock or (opt.update and not opt.package),
        update_target = opt.update and opt.package or nil,
        update_matched = false
    }
    -- 仅在写操作保存时持久化分类；status/list 仍然完全只读。
    for key, entry in pairs(state.packages) do
        local development = _is_development_key(ctx, key, entry) and true or nil
        if entry.dev ~= development then
            entry.dev = development
            ctx.state_scope_changed = true
        end
    end

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

    local synchronized = #table.keys(ctx.resolved)
    if opt.lock or (lock_data and opt.update) then
        if ctx.no_dev and lock_data then
            -- 跳过开发依赖不代表删除它们的锁定记录，包括暂时移出清单的开发包。
            for key, entry in pairs(lock_data.packages) do
                if not ctx.resolved[key] and _is_development_key(ctx, key, entry) then
                    entry.dev = true
                    ctx.resolved[key] = entry
                end
            end
        end
        _save_lock(lock_path, ctx.resolved)
    end
    if ctx.state_scope_changed then
        _save_state(state_path, state.packages)
    end
    cprint("${green}xspm: synchronized %d package(s)${clear}", synchronized)
end
