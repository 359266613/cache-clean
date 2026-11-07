# CacheClean 审查与使用边界

## 本次确认并修复的问题

- 原构建脚本没有配置 EXE 图标。现在从 `clean.png` 生成多尺寸 ICO，并把窗口图标内嵌到 EXE。
- 原扫描逐分类串行执行。现在将目录扫描分配到最多两个并发任务，限制磁盘争用；不缓存旧统计结果。
- 原回收站仅提供清空操作，没有实现统计。现在查询当前用户所有磁盘的回收站，并在清理后重新查询差额。数量是 Windows 返回的项目数，包含文件夹，不是递归文件数。
- 原系统分类在非管理员状态完全跳过统计。现在尝试读取可访问的部分，受限时明确标记“权限不足 / 未知”，并提供管理员重启按钮。系统清理仍必须提权。
- 原空 HashSet 被 PowerShell 判为 false，导致第一次目标去重失效。现修复，避免 TEMP 与 LocalAppData\Temp 重复统计。
- 原保护目录集合区分大小写，而且没有拒绝目标路径中的链接祖先。现在使用不区分大小写的比较，并拒绝链接目标及链接祖先。
- 原扫描和内部文件删除没有一致跳过文件型链接。现在 C# 扫描与删除都跳过这些链接。
- 更新缓存清理会处理 wuauserv 与 BITS，只恢复原本运行的服务；停止失败则跳过该分类，避免继续删除。服务恢复失败计入失败数。
- 浏览器仅清理 Edge/Chrome 的 Cache、Code Cache、GPUCache 和 Firefox 的 cache2；不清理 Service Worker 离线缓存，优先保护网站数据。
- pnpm 存储、其它开发缓存改为默认不勾选。这些内容可能影响离线构建，不应无条件推荐清理。
- 后台任务结束后释放 PowerShell 与 runspace，重新扫描时重置共享结果，避免显示上次结果。
- 单文件 EXE 优先使用内嵌核心和界面，不被旁边同名源码覆盖。
- v1.1.2：清理完成弹窗绑定主窗口，弹窗前先刷新“清理完成”状态，避免底部一直显示最后一个分类。清理期间显示已用时间。
- v1.1.2：回收站部分清理失败后仍重新统计实际差额，错误详情和剩余项目写入结果；已空的回收站直接成功返回。

## 搜索范围是否完整

**不是全盘垃圾扫描，也不保证覆盖所有软件。** 当前采用可审查的固定路径白名单：

| 类别 | 当前范围 |
| --- | --- |
| 用户临时文件 | 当前进程 TEMP、当前用户 LocalAppData\Temp |
| 崩溃转储 | 当前用户 CrashDumps |
| 缩略图与图标缓存 | 当前用户 Explorer 数据库 |
| 开发缓存 | npm、pnpm、pip、Yarn、Go、Cargo、Gradle 的部分常见默认目录 |
| 浏览器 | Edge、Chrome 默认数据目录中的多配置文件缓存；Firefox 默认本地配置目录 cache2 |
| 回收站 | 当前用户、所有磁盘，按 Windows 回收站接口查询 |
| 系统临时文件 | SystemRoot\Temp |
| 更新缓存 | SystemRoot\SoftwareDistribution\Download |

未覆盖：其它 Windows 用户、浏览器自定义/便携配置目录、开发工具自定义存储目录、其它应用缓存、Windows 组件存储、旧系统安装、还原点等。
不会递归扫描项目目录删除 node_modules，也不会把下载、文档等用户数据当作清理分类。
不建议为了“完整”直接扩大到整盘删除，新增类别应逐项确认路径和风险。

## 是否适合其它设备

- 路径使用目标设备的环境变量，而不是写死本机用户名或系统盘符。
- 当前构建目标为 Windows x64，依赖 Windows PowerShell 5.1、.NET Framework 和 WPF；无需另装 ps2exe 才能使用 EXE。
- 运行 EXE 不需要附带源码、PNG 或 ICO；修改图片后需要重新构建。
- 普通权限可处理当前用户类别；系统目录的完整统计和清理需要管理员权限。受组织策略、杀毒软件或 ACL 限制时，管理员也不保证能访问全部文件。
- 若 UAC 使用另一管理员账号凭据，重新启动后“当前用户”将变为该管理员账号，不再是原账号。
- 尚未在其它用户设备、ARM64、32 位系统或不同 Windows 版本上实测，不能声明所有设备兼容。
- EXE 未进行代码签名，分发时可能出现 Windows 或安全软件的信任提示。

## 统计及清理注意事项

- 浏览器账号信息属于禁止清理的数据：Cookies、密码库、Local State、网站本地存储、IndexedDB、会话、扩展数据、书签、历史记录和 Service Worker 均不在浏览器清理白名单中。
- `tests/browser-protection.ps1` 使用模拟浏览器配置目录，验证缓存被删除后，上述账号和网站数据仍逐字节保持不变。不使用真实浏览器资料进行删除测试。

- 显示的是逻辑文件长度，不是文件系统实际占用空间；硬链接、压缩、稀疏文件等情况下，实际释放量可能不同。
- 扫描与清理之间文件可能变化，预计大小不保证与清理结果完全相等。
- 扫描无法读取的目录会标记为部分不可访问，不应把可见的小计当作完整总量。
- 使用前退出相关应用，避免删除正在使用但未锁定的缓存或临时文件。
- 更新下载缓存可能在下次更新时重新下载。不要在系统正在安装更新时使用此项。
- 本次验证只删除隔离测试目录中的人工文件，没有清空真实回收站，也没有删除真实系统或应用缓存。
- 管理员 UAC 交互与真实 Windows 更新服务停止/恢复没有实际执行；相关失败路径采用测试替身验证。

## 验证方式

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\verify.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\browser-protection.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\recycle-completion.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\smoke-exe.ps1
```

`smoke-exe.ps1` 把 EXE 复制到独立目录，通过 Windows UI Automation 等待扫描完成，不执行清理操作。

## 自动发布

- 提交并推送到 `main/master` 后，GitHub Actions 自动计算版本、构建 EXE、创建标签和发布 Release，不再需要手动打标签。
- 一次推送即一次构建；一次推送包含多个提交时只发布一版。PR 只构建，不发布；在其它分支手动运行也不发布。
- 版本格式为 `1.0.构建序号`。例如构建序号 `23`，得到 EXE 版本 `1.0.23`，标签 `v1.0.23`。本地默认版本为 `1.0.0`。
- 版本前两段只在 `build.ps1` 的默认 `Version` 参数维护，CI 通过 PowerShell 语法树读取主版本和次版本，并用 GitHub 构建序号替换第三段，不另写一份版本配置。
- 同一任务重新运行沿用同一版本号，不创建下一版；构建序号可能因 PR、失败构建等出现间隔，不要求连续。
- 每段版本号限定为 `0..65534`（构建序号至少为 1），超出范围明确失败，不再悄悄降级成 `0.0.1`。
- Release 明确绑定本次构建的提交，附件为对应 EXE。缺少附件时发布失败；仓库须允许 Actions 写入内容。不可变 Release 策略可能阻止重跑时覆盖已发布附件。
- 工作流不监听标签推送，因此自动创建标签不会再重复构建。手动触发入口仍保留，选择 `main/master` 即可发布。
- 本地可执行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\ci-version.ps1` 验证版本计算。真正的 GitHub 发布需推送本次工作流修改后验证。
