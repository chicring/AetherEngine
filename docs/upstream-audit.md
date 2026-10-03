# 上游差异与旧分支清理审查

## 审查范围与快照

本次在当前挂载的 AetherEngine 仓库运行 `git fetch upstream --tags`，并从 GitHub fork
直接取回旧 `main`，而不是仅使用本机缓存判断：

- 远程上游 `main`：`7ac28fa409601d12ec68eeb2e9468a240d5d90cd`，即 tag `7.26.3`。
- 本地主干审查快照：`0c4003e709e3ba7b76ed4422bc255295a2f1eafa`。
- GitHub fork 旧 `main`：`a723548bd800e6982c464433edf4c0e19c95de0e`。
- Themby 子模块当前检出：`themby/7.26.3`，`9b5eb8b2`，只读检查时没有未提交修改。

`git rev-list --left-right --count upstream/main...main` 为 `0 33`：全部上游提交都在
本地主干的祖先历史中，没有漏合上游提交。树差异是 43 个文件（含本次迁移前加入的
两份文档改动），不是 33 个独立功能。包含所有上游历史不能证明冲突处理后的代码语义正确。

## 当前补丁是否与上游重复

检查了主要差异路径、上游对应实现以及已有回归用例。没有发现可以仅因「上游已经有同名
机制」就安全整块删除的当前补丁；多个补丁是对上游现有机制的扩展，不是第二套可互换实现：

| 主题 | 上游已有机制 | 本地实际增量与结论 |
| --- | --- | --- |
| 网络 stall | 20 秒 delivery-gap watchdog、重连预算、首字节 witness | 1 秒需求侧 delivery floor、慢首字节 standby race、Range 拒绝计数。快慢 watchdog 分别处理需求侧饥饿和连接静默，不宜删掉其中一套当作去重；修改行为和复杂度都显著，需要继续保留回归证据。 |
| load 取消 | 单个 probe abort handle、load generation、任务取消 | 注册 fallback/reload 等多个正在 open 的 demuxer；是扩展覆盖面，不是另起一套取消协议。 |
| VOD 输出 | 已完成文件 serve、media segment 慢响应早 header | 本地增加 staging-file fragment 发布/读取、init.mp4 慢响应 header。早 header 只防 TTFB 超时，不等同于边生产边输出数据。 |
| seek | restart coalescer、authoritative recovery、deadline re-anchor | 本地增加前向提前 re-anchor 和用户 seek epoch，避免等待远处 segment 及执行已过期请求；原恢复路径仍需保留。 |
| 字幕带宽 | side-reader 仲裁、anchor grace、producer tap | 本地增加 startup 优先级及独立 re-anchor grace。沿用一个仲裁器，不再复制 reader 侧另一份判定。 |
| 暂停/倍速 | `desiredRate`、`defaultRate`、session rebuild transport policy | 本地补齐暂停时只记忆速度、audio clock armed/EOF、premature-end 恢复的 intent 检查；不是应恢复旧 fork 整套 rate 写法的理由。 |
| 抽帧 | bucket cache、取消 token、HTTP read deadline | 本地增加 5 秒附近缩略图复用、复用在途 thumbnail task 和宿主可见诊断；snapshot 路径保持精确。 |
| 网络字节诊断 | 上游已有内部 `demuxerBytesFetched` 和统一计数源 | 本地只把已有计数公开给宿主，不另加第二套计数。 |

主要风险仍是大幅修改的 AVIOReader、多路径取消/重建与全量运行不稳定；本次没有为了减少
差异行数而删掉带有行为增量的代码。接口去重需要按契约判断，不能只按函数名或提交标题。

## 旧 GitHub main 的独有功能

旧远端 `main` 有 39 个不在当前主干历史中的提交，其中 16 个是非 merge 提交。
`git cherry` 对它们均为 `+`，不能用 patch-id 声称已经等价合入。逐类核对后：

| 历史功能 | 当前状态 | 迁移处理 |
| --- | --- | --- |
| `diskCacheBudgetBytes` (`a81f3a07`) | 当前 LoadOptions 没有该显式字节预算接口；上游有自动 retention/prefetch budget，但不等于宿主指定预算 | 归档；是否恢复该接口需要产品决定，不盲目 cherry-pick 旧 cache/retention 实现。 |
| `shortFirstSegmentSeconds` (`167e8741`、`6f6ba916`) | 当前没有该选项；progressive VOD serve 可降低等待，但不等于更改 segment plan 首段长度 | 归档；需要短首段契约时单独基于新 planner 实现和测试。 |
| `prepareBitmapSubtitleOCR` (`5f9b7d4a`) | 当前没有独立 OCR opt-out 字段 | 归档；现有原生字幕/OCR 选择规则不是该字段的 API 等价替代。 |
| 首帧显示 latch (`5feef9d8`、`ce8fd1f6`) | 上游已有 load-scoped `hasFirstFrameReadyForDisplay`，名称和契约不同于旧 `isFirstFrameDisplayReady` | 复用现有公开契约，不恢复第二个 latch。 |
| sidecar ASS header 发布顺序 (`1c4d933f`) | 上游先写 `sidecarASSHeader` 再写 `subtitleCues` | 不重放旧实现。 |
| overlay batch/cap (`bdd645d0`、`047df9a9`) | 上游已有 off-main batch decode、每 tick 单次发布、解码 cap 和新的 retention 规则 | 不重放旧整块 drainer；旧 count backstop 与新 retention 并非逐行等价，必要时另作压力测试。 |
| PGS 固定 120 秒 placeholder cap (`7cbb9d12`) | 当前未保留该固定截断；上游根据 successor、覆盖区间和重建状态处理 open-ended cue | 不直接恢复任意 120 秒截断；需要以孤立 cue/内存压力测试判断是否仍有缺口。 |
| OCR 熔断 (`b3239b18`) | 上游已有 accurate-model 失败后转 fast 的 latch，以及有界识别 executor；并非旧「连续识别失败全部停用」逻辑 | 保留当前降级规则，不将两种机制称作完全等价。 |
| 弱网与倍速剩余提交 | 当前上游及本地补丁使用更新后的连接和 transport 规则覆盖相同问题域 | 不将旧版本整文件或旧 generation 规则拼回新代码。 |

只读搜索当前 Themby 宿主受 Git 跟踪的文件，未发现对上面四个旧字段名的调用。这减少了
直接编译兼容风险，但不是证明这些功能不再需要，也没有替代宿主构建/播放验证。

旧 GitHub `main` 已另由当前工作仓库的 annotated tag
`archive/fork-main-before-migration` 保存。该 tag 尚未发布，不能当作子模块或 GitHub 已有备份。

## 哪些旧分支可清理

下表针对只读检查的 Themby 子模块本地 refs，以 `9b5eb8b2` 补丁版为比较基线：

| 分支 | 历史核对 | 删除条件 |
| --- | --- | --- |
| 旧本地 `main`、`themby/7.14.0`、`themby/7.15.1`、`themby/7.16.1`、`themby/7.19.0`、`themby/7.26.3` | tip 均已被当前补丁版历史包含 | 归档后、检出切到新 main 且确认没有其他 worktree 占用，可清理。 |
| `themby/6.82.0`、`themby/6.86.0`、`themby/7.1.0`、`themby/7.3.0`、`themby/7.7.1`、`themby/7.8.0` | 每支 1 个独有提交，`git cherry` 均为 `-`，补丁等价已在当前历史 | 保留旧 tip 的归档后可清理，不必再次合入。 |
| `themby/7.10.0` | 6 个独有提交，`git cherry` 均为 `-` | 归档后可清理，不再次重放这 6 个补丁。 |
| `diag/log-refused-urls` | 重连补丁等价；其余 URL 日志添加及撤销互为逆补丁，已校验 patch-id | 归档后可清理，不恢复原始 URL 日志。 |
| GitHub 旧 `main` | 与本地旧 main 不同，39 个独有提交，存在上述功能差异 | 不直接删除/覆盖；先保留远端可取回备份并确认功能取舍。 |

GitHub 的 `themby/*` 和诊断分支 tip 在本次检查时与相应子模块本地 tip 一致；清理执行时
仍需重新检查服务器 refs，不能把本次快照作为不变事实。GitHub 默认分支 `main` 应替换为
审查通过的长期主干，而不是先删掉默认分支。

## 同步与强推的边界

1. 当前 `origin` 指向本机子模块仓库，不是 GitHub。不能在这里直接
   `git push --force origin main` 当作发布。
2. 子模块旧本地 `main` 已是当前主干祖先；更新该 ref 可 fast-forward，**不需要强推**。
   子模块检出切到 main 后，若要宿主记录新版本，还须在 Themby 父仓库提交新的 gitlink SHA。
3. GitHub 旧 `main` 与当前主干分叉，普通 push 会被拒绝。若决定以当前版本替代它，先把
   `a723548b` 及其他待删除 tip 归档到可取回的远端 tags 或已验证的持久 bundle，再明确确认
   功能取舍；针对执行前重新核对的旧 SHA 使用 `--force-with-lease`，不使用裸 `--force`。
4. 子模块和 Themby 父仓库目前没有挂载到此线程；本次只读检查，没有向它们写 refs、
   修改检出、提交 gitlink、删除分支或推送。执行同步前必须挂载目标仓库，或用户明确选择
   直接修改未挂载的检出。

## 验证结果与结论限制

本轮针对上游/本地交叉的取消、重建、倍速、seek、字幕、缩略图、OCR 和文档契约用例复跑：
132 个 Swift Testing 用例（18 个 suite）及 19 个 XCTest 全部通过。
前一轮 `swift build` 和补丁专项也通过，但全量测试尚未得到成功结果，实际宿主和跨平台
验证未完成。因此没有发布稳定版本 tag，也不把本次差异审查表述成「全部代码正确」。

结论：当前主干可作为单-main 工作流基线；大部分旧版本分支可在备份后清理。
旧 GitHub main 的 API/行为取舍、全量测试以及子模块实际迁移仍是后续步骤。
