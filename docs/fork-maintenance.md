# Themby fork 维护规则与迁移清单

## 推荐模型

只维护一个长期开发分支 `main`。上游版本是合并输入，不再为每个版本创建
`themby/<上游版本>` 分支；每个验证通过的集成版本用不可移动的 annotated tag 记录。

- `origin`：自己的 GitHub fork，发布 `main` 和自己的版本 tag。
- `upstream`：原作者仓库，只读取发布版本，不向它推送本地补丁。
- 上游 tag 保持原样，例如 `7.26.3`；本地集成版本使用独立命名，例如
  `themby-7.26.3-r1`、`themby-7.26.3-r2`。
- 不复用或移动旧 tag，也不额外维护一个不断覆盖的 `latest` tag。
- 日常修改直接提交到 `main`，每个行为变化有对应回归测试。多人并行或高风险修改可用
  临时分支，但不再维护按上游版本命名的长期分支。
- tag 只标记测试和实际宿主验证通过的版本，不是每次执行 merge 都立刻打 tag。
- GitHub Release、签名、发布安装包是独立动作；创建 Git tag 不等于这些动作。

## 当前基线与补丁清单

迁移前盘点的代码基线（迁移只改变分支名，不改变代码）：

- 补丁版：`9b5eb8b23ebdfcc843bf272b2a7b4159ed69f7c9`，原分支 `themby/7.26.3`，
  当前本地开发分支为 `main`；该代码基线另由归档 tag 保留。
- 已集成上游：tag `7.26.3`，commit `7ac28fa409601d12ec68eeb2e9468a240d5d90cd`。
- 相对该上游版本的最终差异：41 个文件，4423 行新增、167 行删除，包括实现、测试和文档。
  这是最终树差异，不是补丁是否正确的证明，也不是未来需要逐个重放的提交清单。

| 补丁主题 | 主要实现 | 已存在的回归测试入口 |
| --- | --- | --- |
| 弱网、停滞连接、Range 异常与恢复 | `AVIOReader.swift`、加载/恢复逻辑 | `FastStallReconnectTests.swift`、`WeakOriginStartupTests.swift`、`ResumeIntentCandidateVerificationTests.swift`、`DetourBlockCacheTests.swift`、`Issue309SilentTransportDeathTests.swift` |
| VOD segment 边生产边提供，早期 chunked 响应 | `ProgressiveSegmentBoard.swift`、`MP4SegmentMuxer.swift`、`HLSLocalServer.swift`、segment cache/provider/producer | `ProgressiveVODServeTests.swift` |
| 前向 seek 提前 re-anchor，丢弃被更新请求替代的任务 | `HLSVideoEngine.swift`、`VideoSegmentProvider.swift`、`RestartCoalescer.swift` | `SeekReanchorLeadTests.swift`、`RestartCoalescerTests.swift` |
| 字幕副 reader 的启动带宽优先级、re-anchor grace、丢弃旧锚点前的流 | `SideReaderLinkPolicy.swift`、`SubtitleForwardPrefetcher.swift`、`EmbeddedSubtitleDecoder.swift` | `Issue240SideReaderLinkPriorityTests.swift`、`Issue220SoftwareDecoderDrainTests.swift` |
| 暂停状态和倍速在恢复/host 重建后的延续 | engine、native/audio/software playback hosts | `Issue436ResumeRateTests.swift`；同时审查已有 reload/session 用例 |
| 缩略图复用与抽帧网络诊断 | `FrameCache.swift`、`FrameExtractor.swift`、`FrameDecodeContext.swift`、`Demuxer.swift`、engine diagnostics | `FrameCacheTests.swift`、`ExtractReaderDiagnosticsTests.swift` |
| 本地 CLI 控制和诊断参数 | `Sources/aetherctl/PlaybackCmd.swift`、`Sources/aetherctl/main.swift` | `docs/cli.md` 中的参数说明及 CLI 实测 |

实现位于 `Sources/AetherEngine/` 的相应子目录；测试位于
`Tests/AetherEngineTests/`。这些是审查入口，不代表所有补丁都已经重新验证。

复查最终差异和本地历史：

```sh
git diff --stat 7.26.3 main
git diff 7.26.3 main -- Sources Tests docs
git log --first-parent --oneline main
git log --no-merges --oneline 7.26.3..main
```

迁移前把上述命令中的 `main` 换成 `themby/7.26.3`。后续更新时把上游版本换成
实际集成的 tag，不把补丁清单固定在旧版本上。

## 已确认的流程缺陷

`bffae224` 的提交说明记录了上次集成事故：在 `17fe8f3c` 中，根据不完整的文件分类
取出上游整文件，静默覆盖了 5 个带本地修改的文件，随后又恢复实现和测试。
`2615ead8` 还恢复了本地字幕启动日志。

因此问题不只是分支命名。合并必须以 Git 的共同祖先进行三方合并，不根据人工文件
清单批量覆盖整文件，也不把自动合并成功当成语义正确。

禁止把下面这些当作通用冲突解决方法：

- 全局使用 `-s ours` 或 `-X theirs`。
- 批量从上游 checkout 整个 `Sources/`、`Tests/` 或所有「未列入补丁清单」的文件。
- 每次从上游重新开分支并重放整套补丁，或反复 rebase 已发布历史。
- 未检查独有提交就 `branch -D`，或未确认就强推替换旧 `main`。

## 一次性迁移前的检查

当前 Delta 工作区与 GitHub fork 之间还有本机仓库转接：工作区的 `local` 指向主检出，
工作区的 `origin` 指向 Themby 子模块仓库；子模块仓库的 `origin` 才指向
`https://github.com/chicring/AetherEngine`，`upstream` 指向
`https://github.com/superuser404notfound/AetherEngine`。
不要在不同仓库里照抄 `git push origin` 而不确认它实际指向哪里。

本次发现子模块仓库有 14 个本地分支；GitHub fork 有 11 个分支。
旧本地 `main` 是当前补丁版的祖先，但 GitHub `origin/main` 不是：盘点时有 39 个
旧远端 main 独有提交。部分早期 `themby/*` 和诊断分支也有独有提交。
独有提交不一定代表独有行为，可能已被上游吸收、重写或撤销，需要逐项判断。

迁移顺序：

1. 在实际拥有这些分支的仓库操作，先检查未提交修改、worktree、宿主引用和远端当前 SHA。
2. 用归档 tag 或 Git bundle 保留所有待清理分支的 tip，包括旧远端 `main`；在删除前验证
   备份可以取回。归档保留历史，不表示那些历史上的修改应该重新合入。
3. 对各旧分支独有提交分类：当前仍保留、上游已实现、明确废弃、需要补回。
   对需要保留的行为补测试，不盲目合并所有旧分支。
4. 以当前经过修复的补丁版作为新 `main` 的代码基线，保留完整祖先历史，不创建 orphan
   分支或将补丁整体 squash 掉。先处理旧 GitHub `main` 的分歧；如果最终选择改写远端
   `main`，须单独确认，并针对已检查的旧 SHA 使用 `--force-with-lease`，不能普通强推。
5. 验证后创建首个本地集成 tag，再更新 GitHub 默认分支/保护规则及宿主 pin。
6. 最后清理已备份、已审查且不再被引用的旧本地/远端分支。保留上游历史与上游 tags。

## 当前仓库已完成的本地迁移

本次用户确认的范围是当前挂载的 `AetherEngine` Delta 仓库，不包括 Themby 子模块仓库或
GitHub 远端。此处原本只有一个本地分支，因此无需批量删除：

- 创建 annotated tag `archive/themby-7.26.3-before-main`，保留原 tip `9b5eb8b2`；
  已验证 tag 解引用到正确提交。它是恢复点，不是测试通过的发布版本。
- 将 `themby/7.26.3` 改名为 `main`，完整保留历史和本地补丁。
  已验证上游 `7.26.3` 是 `main` 的祖先，且源码、测试、manifest 和依赖锁定文件
  与归档基线完全一致。
- 取消原有 `origin/themby/7.26.3` tracking，避免 `main` 仍跟随旧版本分支。
  当前 `main` 没有 tracking；未将它绑定到尚未处理分歧的 GitHub 旧 `main`。
- 当前仓库配置 `pull.ff=only`：普通 pull 遇到分歧时停止，不偷偷引入 merge/rebase；
  集成上游仍使用下节的显式 merge。
- 当前仓库配置 `rerere.enabled=true`、`rerere.autoupdate=false`：记录冲突解决供下次参考，
  但复用后仍须检查并手工暂存，不自动接受。
- 添加只读用途的 `upstream` 远端，fetch URL 为原作者 GitHub 仓库，push URL 为
  `DISABLED`，防止误推。未 fetch 或合并新的上游版本。

`local`、`origin` 的本机转接关系保持不变，缓存的 `origin/themby/*` 不是本地开发分支，
它们仍反映另一个仓库的分支；本次未删除这些引用，也未删除其对应远端分支。
分支、tags 和本地 Git 配置属于本次工作仓库的状态，不是文档提交的内容；其他克隆以及
用户主检出的分支/配置不会因为这份提交自动迁移。没有执行 push、远端改名或强推。

### 本次验证与发布状态

工具链：Xcode 27.0 / Apple Swift 6.4。

- `swift build` 通过（现有 `String(cString:)` 弃用警告未修改）。
- 首次全量 `swift test` 返回失败：日志脱敏和 server stop 日志断言失败，音轨重建与
  首字节诊断用例超时。失败 suite 单独复跑时，64 个 Swift Testing 用例全部通过；
  这说明失败有全量运行环境/并发相关迹象，但尚未定位根因。
- 第二次全量 `swift test --skip-build --no-parallel` 在命令的 180 秒限制内未完成，
  没有成功的全量结果；不将该选项视为 Swift Testing 跨 suite 串行化的保证。
- 补丁专项复跑：127 个 Swift Testing 用例、19 个 suite，以及 5 个抽帧诊断 XCTest
  全部通过，覆盖上表中的主要本地补丁入口。
- 已有文档链接检查及 Git whitespace 检查通过。
- CI 运行时脚本、跨平台构建与实际宿主播放尚未验证。

因此本次只保留归档 tag，暂不创建 `themby-7.26.3-r1` 发布 tag。全量测试、实际宿主
验证通过后，才按下节创建首个集成版本；归档恢复点不能冒充已验证版本。

## 后续每次集成上游的固定流程

以下命令只在已迁移到 `main`、且 `origin`/`upstream` 已确认的仓库运行。
先确保工作区干净、当前本地 `main` 包含已发布提交，且选定 tag 来自正确的上游。
下面用 `7.26.3` 示范版本格式，不要求把已经集成的版本再次合并。

```sh
git switch main
git status --short --branch
git remote -v
git fetch upstream --tags
git show --no-patch 7.26.3
GIT_EDITOR=true git merge --no-ff --no-commit refs/tags/7.26.3
```

存在冲突时逐个三方解决；没有冲突也检查最终 diff、补丁行为和上游变化。
在提交前至少完成：

```sh
git diff --check
git diff --cached --check
git diff --cached --stat
swift build
swift test
python3 Scripts/check-doc-links.py
```

另外跑补丁相关回归入口、当前 CI 中的运行时回归脚本，并在实际宿主确认启动、弱网、
seek、暂停/倍速、字幕和缩略图。Swift 单元测试不能替代实际播放验证。

如果需要等 CI 才能完成验证，可以先提交并推送 `main`，CI 通过且宿主验证完成后再打 tag。
失败则继续修复，不给失败版本打发布 tag。CI 当前只自动检查面向 `main` 的 push/PR。

```sh
GIT_EDITOR=true git commit -m "merge: integrate upstream 7.26.3"
git push origin main
# 等待验证通过；确认名字未用过，且 HEAD 就是已验证的提交。
GIT_EDITOR=true git tag -a themby-7.26.3-r1 -m "Themby integration of upstream 7.26.3; verified local patches"
git push origin refs/tags/themby-7.26.3-r1
```

同一上游版本继续修补时递增 `r2`、`r3`；上游升级则使用新上游版本的 `r1`。
推送单个明确的 tag，不使用 `git push --tags` 把所有上游和归档 tags 一起发布。
宿主以已验证的 SHA/tag 固定依赖；如果使用 submodule，仍需在宿主仓库提交新的 gitlink SHA，
仅创建 tag 或切换引擎分支不会自动更新宿主。
