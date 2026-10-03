# xmake-xspm

`xspm` 是 **xmake source package manager（xmake 源码包管理器）**的缩写。它是面向 xmake 项目的小型源码包管理器，管理基于 Git 的源码包，将包源码保存在项目目录树中，支持普通依赖与开发依赖、递归处理清单、可选的锁定机制以及包初始化钩子。

它不负责决定包的编译方式。xspm 管理源码获取和生命周期，xmake 管理构建图。

## 集成

将本仓库放入使用它的项目中，例如放在 `tools/xspm`，然后引入：

```lua
-- project/xmake.lua
includes("tools/xspm/xmake.lua")

-- 包尚未安装时也可以安全调用：文件不存在时会直接跳过。
xspm_include("deps/hal/xmake.lua")
```

`xspm_include()` 以调用它的 `xmake.lua` 所在目录为基准解析相对路径，因此已安装的包也可以用它引入自己的嵌套包。

## 清单

在项目根目录创建 `xspm.json`：

```json
{
  "version": 1,
  "installDir": "deps",
  "dependencies": {
    "hal": "https://example.com/hal.git#main",
    "driver": "https://example.com/driver.git#v1.2.0",
    "fixed": "https://example.com/fixed.git#0123456789abcdef"
  },
  "devDependencies": {
    "cautest": {
      "source": "https://example.com/cautest.git#main",
      "path": "tools/cautest"
    },
    "xdtc": {
      "source": "https://example.com/xdtc.git#main",
      "path": "tools/xdtc"
    }
  }
}
```

字符串形式是 Git 源的简写，使用 `<installDir>/<name>` 作为安装路径。`installDir` 默认为 `deps`。

Git 源支持 HTTPS、SSH、`file://` URL 和本地仓库路径，例如 `/share/repos/hal.git#main` 或 `../hal#main`。本地源的相对路径以声明它的 `xspm.json` 所在目录为基准解析，嵌套清单也遵循这一规则。锁文件和状态文件保留清单中声明的源字符串。本地源提供已提交的文件，工作区中未提交的修改不会被安装。

包可以通过 `path` 覆盖默认安装路径。所有安装路径都相对于当前 `xspm.json` 所在目录；不允许使用绝对路径，也不允许通过 `..` 越出该目录。

`dependencies` 声明使用、编译这个源码包所必需的依赖；`devDependencies` 声明维护本项目时需要的测试、生成等工具。两者支持相同的字符串和对象形式，使用相同的默认 `installDir`，可以通过 `path` 将工具安装到 `tools/`。同一清单中名称不能跨类别重复，两类依赖的安装路径也不能相同或互相包含。

默认同步会安装**根项目**的两类依赖。如果已安装的包包含自己的 `xspm.json`，则只递归安装它的 `dependencies`，跳过它的 `devDependencies`。开发工具本身的普通依赖仍然需要安装，并归入根项目的开发依赖子树。因此，维护 cmlib 时可以安装 cautest、xdtc；其他项目将 cmlib 作为源码包安装时不会取得这些工具。

子清单中的路径相对于该包的根目录。xspm 不执行依赖提升，也不解析构建目标之间的依赖关系。若某个生成器是下游项目编译这个包所必需的工具，它应属于 `dependencies`，而不是 `devDependencies`。清单版本仍为 `1`；升级前的 xspm 不会安装新增的 `devDependencies` 字段，使用它需要同时升级管理器。

需要只处理普通依赖时使用 `xmake xspm --no-dev`。这个选项也适用于状态、列表、更新、重新初始化及清理命令；它跳过整个开发子树，保留已有开发包的文件、状态和锁定记录，包括已从清单移除的历史开发包。要删除这些历史包，执行不带 `--no-dev` 的 `--prune`。如果删除普通父目录会连带删除开发包，`--no-dev` 下会拒绝操作，`--force` 也不能绕过这一保护。

## 包初始化

包可以选择提供 `xspm.lua`：

```lua
function on_install(ctx)
    -- ctx.name
    -- ctx.rootdir     包源码目录
    -- ctx.projectdir  使用该包的顶层项目
    -- ctx.commit
    -- ctx.source      Git 源 URL
    -- ctx.ref
    -- ctx.path        相对于顶层项目的安装路径
end
```

`on_install()` 在包及其递归声明的子源码包同步完成后运行。在已安装的工作区中，每个解析得到的提交只会触发一次初始化。新克隆的工作区会重新初始化，即使状态文件中仍保留着同一提交此前的安装记录。成功的初始化会记录在：

```text
.xspm/state/packages.json
```

如果钩子执行失败，则不会记录初始化状态，并会在下次同步时重试。钩子在 Git 包内生成的文件通常应由该包的 `.gitignore` 忽略；否则，下次运行 xspm 时会正确地报告该包存在本地修改。

顶层项目通常应在自己的 `.gitignore` 中忽略 `.xspm/`。

## 锁文件

`xspm-lock.json` 是可选的。没有锁文件时，普通的 `xmake xspm` 会从 Git 远端解析清单中声明的引用（ref）。存在锁文件时，普通同步会使用其中记录的确切提交；如果这些提交在本地已可用，则不会访问远端。

如果远端分支或标签不存在，解析会失败，不会回退到过期的本地引用。支持完整提交哈希和无歧义的缩写提交哈希。存在锁文件时，如果其中缺少包条目，`--status` 会报告 `lock-missing` 并以错误状态退出。

锁文件以实际安装路径为键，记录递归解析得到的完整包依赖图。嵌套包作为依赖被使用时，不会使用它自己的 `xspm-lock.json`；解析得到的依赖图由顶层项目的锁文件控制。

开发依赖及其普通子依赖的锁定条目、初始化状态带有 `"dev": true` 标记。没有该标记的旧文件仍然可以使用，当前根清单负责识别已声明包的类别；普通依赖与开发依赖之间迁移不会单独触发初始化钩子。升级管理器后，应在移除开发依赖声明前先执行一次完整同步和锁定，以保存历史包的类别信息。

`--lock --no-dev` 只解析普通依赖；已有开发锁定记录会保留，没有锁文件时则只创建普通依赖的锁定记录。之后恢复开发模式，如果锁文件缺少开发包条目，普通同步会报错；执行 `xmake xspm --update` 补全全部依赖，或执行 `xmake xspm --update cautest` 补全指定工具的子树。

## 命令

```text
xmake xspm
    根据 xspm.json / xspm-lock.json 同步根项目的普通依赖与开发依赖。

xmake xspm --no-dev
    仅同步普通依赖，保留已安装的开发包及其锁定记录。

xmake xspm --update
    重新解析所有 Git 引用。如果存在锁文件，则刷新它。

xmake xspm --update PACKAGE
    仅重新解析匹配的包及其递归子树。
    其他已锁定的包保持原有提交。

xmake xspm --lock
    重新解析所有引用，同步包目录树，并创建或刷新 xspm-lock.json。

xmake xspm --status
    检查包是否存在、origin、本地修改状态、锁文件与 HEAD 是否一致，以及初始化状态。
    输出 SCOPE 列，区分 normal 与 dev；此命令不会修改包，也不会访问远端。

xmake xspm --list
    显示清单中声明的包目录树、源和引用、安装路径以及已知提交。
    开发子树标记为 [dev]；此命令不会修改包，也不会访问远端。

xmake xspm --reinit [PACKAGE]
    再次运行包的 on_install()，保持包的提交不变。

xmake xspm --prune
    移除当前清单树中已不再声明的已安装包。
    如果存在锁文件，也会移除其中过期的条目。

xmake xspm --clean [PACKAGE]
    移除已安装的包。指定包时，会移除其已安装的子树。
    保留锁文件，以便再次安装相同的提交。

--force
    可与具有破坏性的同步、clean 或 prune 操作组合使用，以丢弃本地源码修改。
```

xmake 3.1.1 的任务选项不支持同一个选项既作为无值开关，又作为可选的 `--name=value` 选项。因此，针对单个包的操作使用位置参数来选择包，例如 `xmake xspm --update hal`，而不是 `--update=hal`。所有选项应放在包名之前，例如 `xmake xspm --force --clean cautest`。

如果过期的包目录中仍包含当前清单声明的包，`--prune` 会拒绝移除该目录，即使使用 `--force` 也如此。清理过期的父目录前，应先将仍被声明的包移到其他安装路径。

## 已安装包检查

每次普通同步都会检查已存在的包目录。受管理的包必须满足以下条件：

- 是 Git 工作区的根目录，而不是其他仓库内的普通目录；
- 具有预期的 `origin` URL；
- 不存在未受管理的本地源码修改，除非使用了 `--force`；
- 最终切换到所需的提交。

该包自身的 `xspm.json` 所声明的嵌套包安装目录，会从父包的本地修改检查中排除，包括自定义的子包安装路径。

## 验证

在本仓库根目录执行 `bash tests/run.sh`，需要 Bash、Git、xmake、Python 3、jq 和 rg。测试使用临时目录和本地 Git 远端，不安装全局工具。该入口包含已有集成与回归测试，以及 [开发依赖测试](tests/development.sh)，覆盖根项目与下游消费、开发工具的普通子依赖、范围筛选、锁定记录保留、类别迁移、初始化失败重试和清理保护。
