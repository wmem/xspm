# xmake-gdep

A small recursive Git dependency manager for xmake projects.

## Integrate

Clone/copy this repository into your project, for example `tools/gdep`, then:

```lua
-- project/xmake.lua
includes("tools/gdep/xmake.lua")

gdep_include("gdeps/hil/xmake.lua")
```

`gdep_include()` is safe before dependencies are installed: a missing file is skipped with a hint instead of making xmake project loading fail.

## Manifest

Create `gdep.lua` in the project root:

```lua
return {
    dependencies = {
        hil = "https://example.com/hil.git#main",
        driver = "https://example.com/driver.git#v1.2.0",
        fixed = "https://example.com/fixed.git#0123456789abcdef"
    }
}
```

A table form is also accepted:

```lua
return {
    dependencies = {
        hil = {git = "https://example.com/hil.git", ref = "main"}
    }
}
```

Dependencies are installed under `gdeps/<name>`. If a dependency itself contains a `gdep.lua`, it is resolved recursively into that repository's own `gdeps/` directory.

## Commands

```text
xmake gdep           sync dependencies
xmake gdep --update  resolve remote refs again; refresh gdep.lock if one exists
xmake gdep --lock    resolve refs and create/refresh gdep.lock
xmake gdep --force   discard local source edits in managed dependency repositories
```

`gdep.lock` is optional. Without it, each normal `xmake gdep` resolves refs from remotes. With it, normal sync uses the locked commits and avoids remote access when those commits are already present locally.

Existing dependency directories are checked on every run: they must be Git repositories, have the expected `origin`, have no unmanaged local edits, and be at the desired commit. The manager-owned nested `gdeps/` directory is excluded from dirty-worktree checks.
