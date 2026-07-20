# 重签 + 注入 —— 进度与交接（handoff，2026-07-20）

> 取代 [2026-07-17-resign-progress-handoff.md]。本文覆盖：计划 4 完成、真机测试中发现并修复的两个真实 bug（App ID name / 通配回退）、M3 注入版排查结论、以及新方向「C 方案：注入式重签」的设计+计划。

- 分支：`feature/resign-adhoc`（**未合并、未推送**；从 `main` @ `17b5ff9` 分出）
- 当前 HEAD：`d61f5ab`，`swift test` **全绿**（gated 真机探针默认跳过）
- 运行中的可点 app：`dist/ReSignMac.app`（**本地未签名测试版**，含通配修法）。正式分发用 `scripts/package-resign.sh`（需 `DEV_ID_APP`+`NOTARY_PROFILE`）。

## 一、计划 4（ReSignApp UI + 打包）—— 已完成

9 任务 + 最终 opus 全分支复审 + 2 个 Important 修复,全部落地(commits `763602d`..`a1597c6`)。安全核心经复审确认正确:泄漏修复、无弹窗签名、明文私钥 shred、密钥格式跨层一致、与注册 app 隔离。详见 [plans/2026-07-17-resignapp-plan4-ui-packaging.md] + `.superpowers/sdd/progress.md`。

**待用户执行的发布前关卡（仍未做）:** ① 公证打包 `scripts/package-resign.sh`;② 真机 E2E(顺带验证真实重签前后登录钥匙串证书数不变、真 Aqua 会话目视窗口)。

## 二、真机测试中发现并修复的两个真实 bug

用户拿真账号(`jgz_xp`, keyID `QA2MC7L8X7`, team `T46A6Q874U`, 49 台设备)测重签 `M3_v4.7.5_84303.ipa` 时暴露:

1. **App ID name 非法**（`a9e6a14`, 测试 `1825878`）：建 App ID 时把带点 bundle id 当 name 传给苹果被拒。修法：`ASCClient.sanitizedAppIdName` 把非法字符换空格。
2. **显式 App ID「not available」→ 通配回退**（`9ded2d7`）：第三方 app 的 bundle id 被原开发者团队占用,建显式 App ID 报 409。修法：`ReSignModel.resolveBundleIdForAdHoc` **显式优先、409 回退通配 App ID `*`**。**已用真账号真实验证**(通配 `*` 资源 id `SYBWQ53DXF`,49 设备,描述文件成功建出)。

另外补了 **`exportProfile`/「导出描述文件」按钮**（`51a6dd3`）——也走通配回退。现在 app 里「一键重签」「导出描述文件」对**干净的**第三方 app 都可用。

## 三、M3 排查结论（重要,决定了 C 方案边界）

`M3_v4.7.5_84303.ipa` 是**被 TrollFools 注入了越狱插件的魔改版**(`CydiaSubstrate.framework` + `FakeGPS.dylib` + 注入版 `GMObjC`)。硬证据:
- 原始二进制(注入前 `.bak`)`codesign` **能签**;注入版二进制 **签不了**(`internal error in Code Signing subsystem`)。
- 注入版 GMObjC 的 Mach-O 签名后有 22 字节尾随数据,`codesign`/`--remove-signature` 都拒;本机无 `ldid`。

**结论:标准重签工具(含我们)签不了别人已注入的脏 app;要签得上专门越狱工具链。** 用户当前用**我们导出的通配描述文件 + app 导出的 p12**,在**锥子助手**里成功重签了这个注入版 M3(已验证走通)。→ 这正是做 C 方案的动因。

## 四、C 方案（注入式重签）—— 已设计 + 出计划,待执行

目标:把工具升级为「干净·已解密 IPA + 插件 dylib → 注入 + 自带 ElleKit 运行时 → 通配签名 → 可装 IPA」,注入全流程集成、免依赖外部工具。

- **设计 spec**：[specs/2026-07-20-resign-injection-design.md]（`14dc46b`）
- **实现计划 1**：[plans/2026-07-20-resign-injection-plan1-core-and-poc.md]（`def66ec`）—— 4 任务：
  1. 内置 `insert_dylib`(源码构建)+ `ElleKit.dylib`(预编译)→ `Resources/inject/` — **需联网**
  2. `MachOInspect`（cryptid/架构/依赖）— 合成测试
  3. `DylibInjector`（preflight + 注入:拷入 Frameworks/改依赖指向 ElleKit/insert_dylib 插 LC_LOAD_DYLIB）— 合成 arm64 二进制端到端测试
  4. **真机 PoC 门槛** — **需用户材料**

### 下一步（新会话从这里起）
执行 [injection plan 1]。Task 1–3 **不依赖用户材料,现在就能做**(Task 1 需联网克隆/构建 `insert_dylib`、拉 `ElleKit`;无网则请用户提供这两个文件)。**Task 4 PoC 阻塞在用户材料:干净(未注入)已解密 IPA + 具体插件 dylib(如 FakeGPS)+ 测试设备——用户说会导入给我测。** 建议起手:`superpowers:subagent-driven-development` 执行 plan 1;或先 `superpowers:executing-plans`。

### C 方案范围（spec 已定）
- **v1 只做**：`.dylib` 注入 + ElleKit + 通配签名。
- **v2/v3 后续**：`.deb` 解包 / `.framework` 嵌入 / 开关类(文件访问·App多开·去跳转)。
- **硬约束**：输入须已解密(`cryptid==0`)、仅 arm64、只往干净 app 注入、不含扩展/Watch。

## 五、遗留 / 台账

- **A 档(用户之前选过,已推迟到 C 之后)**：导入 IPA 后展示元数据预览 + **只改版本号** + 「开启文件访问」开关(写 Info.plist,签名前)。用户确认:只改版本号、图标 Assets.car 限制可接受。未写 spec。
- **签名健壮性(推迟)**：签名前 `xattr -cr`(M3 有 1550 文件带 quarantine xattr);遇已注入二进制给人话报错。
- **账号副作用(测试期间建的,无害)**：`ReSign Wildcard` 通配 App ID(`SYBWQ53DXF`)+ `ReSign AdHoc Wildcard` 描述文件——正是通配修法要用的,留着。
- **gated 真机探针** `Tests/ReSignAppCoreTests/LiveAdHocReproTests.swift`（`d61f5ab`）：`LIVE_REPRO/EXPORT_PROFILE/LIVE_INTEGRATED/LIVE_RESIGN=1` 才跑,复用于注入 PoC。
- **分支收尾**：计划 4 走到 `finishing-a-development-branch` 时用户选了「先测再定」,随后进入本轮 bug 修复 + C 方案。分支仍未合并；C 方案做完再一起定合并/PR。

## 六、新会话速查

- 真账号：`jgz_xp` / keyID `QA2MC7L8X7` / team `T46A6Q874U` / 49 设备(48 provisioned,1 disabled) / 通配 App ID `SYBWQ53DXF`。
- 通配回退逻辑：`Sources/ReSignAppCore/ReSignModel.swift` 的 `resolveBundleIdForAdHoc`。
- 重签流水线共用:`ReSignModel.buildAdHocProfile`（resign() 与 exportProfile() 共用）。
- 无弹窗签名 / 泄漏修复要点见 `resign-feature-progress` 记忆 + `.superpowers/sdd/progress.md`。
</content>
