# xmake-xspm

`xspm` means **xmake source package manager**. It is a small source-package manager for xmake projects. Version 0.2 manages Git-backed source packages, keeps package sources in the project tree, supports recursive manifests, optional locking, and package initialization hooks.

It deliberately does not decide how packages are compiled. xspm manages source acquisition and lifecycle; xmake manages the build graph.

## Integrate

Put this repository in the consuming project, for example at `tools/xspm`, then include it:

```lua
-- project/xmake.lua
includes("tools/xspm/xmake.lua")

-- Safe before the package is installed: a missing file is simply skipped.
xspm_include("deps/hal/xmake.lua")
```

`xspm_include()` resolves relative paths from the `xmake.lua` that calls it, so an installed package may also use it for its own nested packages.

## Manifest

Create `xspm.json` in the project root:

```json
{
  "version": 1,
  "installDir": "deps",
  "dependencies": {
    "hal": "https://example.com/hal.git#main",
    "driver": "https://example.com/driver.git#v1.2.0",
    "fixed": "https://example.com/fixed.git#0123456789abcdef",
    "cautest": {
      "source": "https://example.com/cautest.git#main",
      "path": "tools/cautest"
    }
  }
}
```

The string form is shorthand for a Git source and uses `<installDir>/<name>` as its install path. `installDir` defaults to `deps`.

A package can override its path with `path`. All install paths are relative to the directory containing the current `xspm.json`; absolute paths and `..` escapes are rejected.

If an installed package contains its own `xspm.json`, that manifest is processed recursively. The child manifest's paths are relative to that package root. xspm does not perform dependency hoisting or build-target dependency resolution.

## Package initialization

A package may optionally provide `xspm.lua`:

```lua
function on_install(ctx)
    -- ctx.name
    -- ctx.rootdir     package source directory
    -- ctx.projectdir  top-level consuming project
    -- ctx.commit
    -- ctx.source      Git URL
    -- ctx.ref
    -- ctx.path        install path relative to the top-level project
end
```

`on_install()` runs after the package and its recursively declared child source packages are synchronized. It runs once for each resolved commit. Successful initialization is recorded in:

```text
.xspm/state/packages.json
```

If the hook fails, initialization is not recorded and the next sync retries it. Hook-generated files inside a Git package should normally be ignored by that package's `.gitignore`; otherwise the next xspm run will correctly report the package as dirty.

The top-level project should normally ignore `.xspm/` in its own `.gitignore`.

## Lock file

`xspm-lock.json` is optional. Without it, a normal `xmake xspm` resolves declared refs from Git remotes. With it, a normal sync uses the exact recorded commits and avoids remote access when those commits are already available locally.

The lock records the complete recursively resolved package graph, keyed by actual install path. A nested package's own `xspm-lock.json` is not used while it is being consumed as a dependency; the top-level project's lock controls the resolved graph.

## Commands

```text
xmake xspm
    Synchronize all packages to xspm.json / xspm-lock.json.

xmake xspm --update
    Re-resolve all Git refs. If a lock exists, refresh it.

xmake xspm --update PACKAGE
    Re-resolve only the matching package and its recursive subtree.
    Other locked packages remain pinned.

xmake xspm --lock
    Re-resolve all refs, synchronize the tree, and create/refresh xspm-lock.json.

xmake xspm --status
    Check package existence, origin, dirty state, lock/HEAD agreement, and init state.
    This command does not modify packages or access remotes.

xmake xspm --list
    Show the declared package tree, source/ref, install path, and known commit.
    This command does not modify packages or access remotes.

xmake xspm --reinit [PACKAGE]
    Run package on_install() again without changing package commits.

xmake xspm --prune
    Remove installed packages that are no longer present in the current manifest tree.
    If a lock exists, stale lock entries are removed too.

xmake xspm --clean [PACKAGE]
    Remove installed packages. Selecting a package removes its installed subtree.
    The lock file is preserved so the same commits can be installed again.

--force
    May be combined with destructive sync/clean/prune operations to discard local source changes.
```

xmake 3.1.1 task options do not support one option being both a bare flag and an optional `--name=value` option. Therefore single-package operations use a positional selector, for example `xmake xspm --update hal`, rather than `--update=hal`.

## Existing package checks

Every normal synchronization checks existing package directories. A managed package must:

- be a Git worktree;
- have the expected `origin` URL;
- have no unmanaged local source changes unless `--force` is used;
- converge to the desired commit.

Nested package install directories declared by that package's own `xspm.json` are excluded from the parent's dirty-worktree check, including custom child install paths.
