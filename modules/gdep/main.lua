import("core.base.json")

local _LOCK_VERSION = 1
local _MANIFEST_NAME = "gdep.lua"
local _LOCK_NAME = "gdep.lock"
local _DEPS_DIR = "gdeps"

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

local function _manifest_load(filepath)
    -- core.sandbox.module is used only as a loader so gdep.lua can stay a
    -- simple Lua data file returning a table. This works on xmake 3.1.1 and
    -- keeps the public manifest syntax independent of xmake project APIs.
    local module_loader = import("core.sandbox.module", {anonymous = true})
    local data, errors = module_loader._loadfile(filepath)
    if data == nil then
        raise("gdep: cannot load %s: %s", filepath, errors or "unknown error")
    end
    if type(data) ~= "table" then
        raise("gdep: %s must return a table", filepath)
    end
    if data.dependencies == nil then
        data.dependencies = {}
    end
    if type(data.dependencies) ~= "table" then
        raise("gdep: dependencies in %s must be a table", filepath)
    end
    return data
end

local function _validate_name(name, manifest)
    if type(name) ~= "string" or #name == 0 then
        raise("gdep: dependency names in %s must be non-empty strings", manifest)
    end
    if name == "." or name == ".." or name:find("/", 1, true) or name:find("\\", 1, true) then
        raise("gdep: invalid dependency name '%s' in %s", name, manifest)
    end
end

local function _split_source(source, manifest, name)
    if type(source) ~= "string" then
        raise("gdep: dependency '%s' in %s must be a string or table", name, manifest)
    end
    local hash = source:match("^.*()#")
    if not hash then
        raise("gdep: dependency '%s' in %s must use <git-url>#<ref>", name, manifest)
    end
    local git = source:sub(1, hash - 1)
    local ref = source:sub(hash + 1)
    if #git == 0 or #ref == 0 then
        raise("gdep: dependency '%s' in %s must use non-empty <git-url>#<ref>", name, manifest)
    end
    return git, ref
end

local function _normalize_dep(name, value, manifest)
    _validate_name(name, manifest)
    local git, ref
    if type(value) == "string" then
        git, ref = _split_source(value, manifest, name)
    elseif type(value) == "table" then
        git = value.git or value.url
        ref = value.ref
        if not git and value.source then
            git, ref = _split_source(value.source, manifest, name)
        end
        if type(git) ~= "string" or #git == 0 or type(ref) ~= "string" or #ref == 0 then
            raise("gdep: dependency '%s' in %s requires git/url and ref", name, manifest)
        end
    else
        raise("gdep: dependency '%s' in %s must be a string or table", name, manifest)
    end
    return {name = name, git = git, ref = ref}
end

local function _sorted_dependencies(manifest_data, manifest_path)
    local names = {}
    for name, _ in pairs(manifest_data.dependencies) do
        table.insert(names, name)
    end
    table.sort(names)
    local deps = {}
    for _, name in ipairs(names) do
        table.insert(deps, _normalize_dep(name, manifest_data.dependencies[name], manifest_path))
    end
    return deps
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

local function _status(repo)
    -- Nested gdeps are manager-owned and intentionally ignored when deciding
    -- whether the dependency source itself has local edits.
    local ok, out = _try_git_in(repo, {
        "status", "--porcelain", "--untracked-files=all", "--", ".",
        ":(exclude)gdeps", ":(exclude)gdeps/**"
    })
    if not ok then
        raise("gdep: failed to inspect working tree %s", repo)
    end
    return _trim(out)
end

local function _prepare_existing(repo, dep, force)
    if not _is_git_repo(repo) then
        raise("gdep: %s already exists but is not a git worktree", repo)
    end
    local remote = _remote_url(repo)
    if not remote then
        raise("gdep: %s has no origin remote", repo)
    end
    if remote ~= dep.git then
        raise("gdep: origin mismatch for '%s': expected '%s', got '%s'", dep.name, dep.git, remote)
    end
    local dirty = _status(repo)
    if #dirty > 0 then
        if not force then
            raise("gdep: dependency '%s' has local changes in %s; use --force to discard them\n%s", dep.name, repo, dirty)
        end
        cprint("${yellow}gdep: reset local changes: %s${clear}", repo)
        _git_in(repo, {"reset", "--hard", "HEAD"})
        -- Preserve nested dependencies managed by gdep.
        _git_in(repo, {"clean", "-fd", "-e", "gdeps/"})
    end
end

local function _ensure_repo(repo, dep, force)
    if os.exists(repo) then
        if not os.isdir(repo) then
            raise("gdep: dependency path exists and is not a directory: %s", repo)
        end
        _prepare_existing(repo, dep, force)
        return false
    end
    os.mkdir(path.directory(repo))
    cprint("${cyan}gdep: clone %s -> %s${clear}", dep.git, repo)
    _git({"clone", "--no-checkout", "--origin", "origin", dep.git, repo})
    return true
end

local function _has_commit(repo, commit)
    local ok = _try_git_in(repo, {"cat-file", "-e", commit .. "^{commit}"})
    return ok
end

local function _fetch_ref(repo, ref)
    cprint("${dim}gdep: fetch %s (%s)${clear}", repo, ref)
    local ok, _, errors = _try_git_in(repo, {"fetch", "--force", "--tags", "origin", ref})
    if ok then
        local out = _git_in(repo, {"rev-parse", "--verify", "FETCH_HEAD^{commit}"})
        return _trim(out)
    end

    -- Some servers do not allow fetching an arbitrary commit object by SHA.
    -- Fetch the configured refs and resolve the requested value locally as a
    -- fallback. A clone normally has the default origin fetch refspec.
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
    raise("gdep: cannot resolve ref '%s' in %s: %s", ref, repo, tostring(errors))
end

local function _ensure_locked_commit(repo, dep, commit)
    if _has_commit(repo, commit) then
        return
    end
    -- First try the exact object, then the declared ref, then the remote's
    -- configured fetch refspec. This handles branch/tag locks and most commit
    -- locks without forcing network access when the object already exists.
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
        raise("gdep: locked commit %s for '%s' is not available from %s", commit, dep.name, dep.git)
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
        cprint("${green}gdep: ok %s @ %s${clear}", dep.name, commit:sub(1, 12))
        return
    end
    cprint("${cyan}gdep: checkout %s @ %s${clear}", dep.name, commit:sub(1, 12))
    _git_in(repo, {"checkout", "--detach", commit})
end

local function _load_lock(filepath)
    if not os.isfile(filepath) then
        return nil
    end
    local data, errors = json.loadfile(filepath)
    if not data then
        raise("gdep: cannot load %s: %s", filepath, errors or "invalid json")
    end
    if data.version ~= _LOCK_VERSION or type(data.dependencies) ~= "table" then
        raise("gdep: unsupported or invalid lock file: %s", filepath)
    end
    return data
end

local function _json_string(value)
    local encoded, errors = json.encode(value)
    if not encoded then
        raise("gdep: cannot encode lock value: %s", errors or "json error")
    end
    return encoded
end

local function _save_lock(filepath, entries)
    local keys = {}
    for key, _ in pairs(entries) do
        table.insert(keys, key)
    end
    table.sort(keys)
    local lines = {
        "{",
        "  \"version\": 1,",
        "  \"dependencies\": {"
    }
    for i, key in ipairs(keys) do
        local entry = entries[key]
        local comma = i < #keys and "," or ""
        table.insert(lines, string.format("    %s: {\"git\": %s, \"ref\": %s, \"commit\": %s}%s",
            _json_string(key), _json_string(entry.git), _json_string(entry.ref), _json_string(entry.commit), comma))
    end
    table.insert(lines, "  }")
    table.insert(lines, "}")
    table.insert(lines, "")
    io.writefile(filepath, table.concat(lines, "\n"))
    cprint("${green}gdep: wrote %s${clear}", filepath)
end

local function _logical_child(parent, name)
    if not parent or #parent == 0 then
        return name
    end
    return parent .. "/" .. name
end

local function _lock_commit(ctx, logical, dep)
    if not ctx.lock_data or ctx.refresh then
        return nil
    end
    local entry = ctx.lock_data.dependencies[logical]
    if not entry then
        raise("gdep: '%s' is missing from %s; run `xmake gdep --update` or `xmake gdep --lock`", logical, ctx.lock_path)
    end
    if entry.git ~= dep.git or entry.ref ~= dep.ref then
        raise("gdep: lock entry '%s' no longer matches gdep.lua; run `xmake gdep --update` or `xmake gdep --lock`", logical)
    end
    if type(entry.commit) ~= "string" or #entry.commit == 0 then
        raise("gdep: lock entry '%s' has no commit", logical)
    end
    return entry.commit
end

local function _sync_manifest(ctx, manifest_path, logical_parent, stack, depth)
    if not os.isfile(manifest_path) then
        return
    end
    depth = depth or 0
    if depth > 64 then
        raise("gdep: dependency recursion is deeper than 64 levels near %s", manifest_path)
    end
    local manifest = _manifest_load(manifest_path)
    local manifest_dir = path.directory(manifest_path)
    for _, dep in ipairs(_sorted_dependencies(manifest, manifest_path)) do
        local logical = _logical_child(logical_parent, dep.name)
        local repo = path.join(manifest_dir, _DEPS_DIR, dep.name)

        for _, ancestor_git in ipairs(stack) do
            if ancestor_git == dep.git then
                raise("gdep: recursive dependency cycle detected at '%s' (%s)", logical, dep.git)
            end
        end

        _ensure_repo(repo, dep, ctx.force)
        local commit = _lock_commit(ctx, logical, dep)
        if commit then
            _ensure_locked_commit(repo, dep, commit)
        else
            commit = _fetch_ref(repo, dep.ref)
        end

        _checkout(repo, dep, commit)
        ctx.resolved[logical] = {git = dep.git, ref = dep.ref, commit = commit}

        local child_manifest = path.join(repo, _MANIFEST_NAME)
        if os.isfile(child_manifest) then
            local child_stack = {}
            for _, value in ipairs(stack) do
                table.insert(child_stack, value)
            end
            table.insert(child_stack, dep.git)
            _sync_manifest(ctx, child_manifest, logical, child_stack, depth + 1)
        end
    end
end

function run(opt)
    opt = opt or {}
    local projectdir = os.projectdir()
    local manifest_path = path.join(projectdir, _MANIFEST_NAME)
    local lock_path = path.join(projectdir, _LOCK_NAME)
    if not os.isfile(manifest_path) then
        raise("gdep: %s not found", manifest_path)
    end

    -- Fail early with a useful message if git is unavailable.
    local git_ok = try {function () _git({"--version"}); return true end}
    if not git_ok then
        raise("gdep: git executable is required")
    end

    local lock_data = _load_lock(lock_path)
    local refresh = opt.update or opt.lock
    local ctx = {
        force = opt.force,
        refresh = refresh,
        lock_data = lock_data,
        lock_path = lock_path,
        resolved = {}
    }

    if lock_data and not refresh then
        cprint("${dim}gdep: using lock file %s${clear}", lock_path)
    elseif refresh then
        cprint("${dim}gdep: resolving refs from remotes${clear}")
    else
        cprint("${dim}gdep: no lock file; resolving refs from remotes${clear}")
    end

    _sync_manifest(ctx, manifest_path, "", {}, 0)

    if opt.lock or (lock_data and opt.update) then
        _save_lock(lock_path, ctx.resolved)
    end
    cprint("${green}gdep: synchronized %d dependencies${clear}", #table.keys(ctx.resolved))
end

