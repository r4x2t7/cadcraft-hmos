# 咖啡CAD for HarmonyOS PC (鸿蒙电脑 / 2in1)

**咖啡CAD**（CoffeeCAD）——基于 [storytold/cadcraft](https://github.com/storytold/cadcraft)
（CADCraft，MIT OR Apache-2.0）移植的**原生鸿蒙 CAD 应用**：**ArkUI 壳 + Rust 引擎
Node-API 模块 + CPU 软渲染**。移植与维护：**霁伪**（[r4x2t7](https://github.com/r4x2t7)）。
许可与署名见根目录 `LICENSE-MIT` / `LICENSE-APACHE` / `NOTICE`；对上游的全部修改记录在
git 历史，上游更新用下面的同步命令持续合并。

## 持续合并上游（cadcraft）

```bash
git remote -v                  # origin = 你的 coffeecad 仓库, upstream = storytold/cadcraft
git fetch upstream
git merge upstream/main        # 建议跟随上游 release（或每月）合并一次
```

移植代码全部在**新增路径**（`apps/cadcraft-ohos/`、`packaging/harmony/`），上游对
`crates/*`、`apps/cadcraft{,-cli,-web}` 的改动极少冲突；冲突热点只有 `Cargo.lock`
（解决后重跑 `cargo check -p cadcraft-ohos --target aarch64-unknown-linux-ohos`）。

## 为什么不是直接把桌面版搬过来

桌面版是 eframe/egui，跑在 winit + wgpu 上。winit 官方没有 OHOS 后端
（[rust-windowing/winit#4081](https://github.com/rust-windowing/winit/issues/4081) 仍开放，
社区方案 [tgui-winit-ohos](https://crates.io/crates/tgui-winit-ohos) 尚在 beta），wgpu 也没有
OHOS surface 集成。而本仓库的架构本来就是"**UI crate 可替换、一切皆命令**"
（`AGENTS.md`：engine 在 L4，UI 在 L5），所以正确的移植面是：

```
ArkUI 壳（packaging/harmony，本目录）          ← 重写：菜单/Tool Sets/命令行/面板
   │ import 'libcadcraft_ohos.so'（Node-API）
   ▼
apps/cadcraft-ohos（Rust cdylib）              ← 本仓库新增：引擎桥 + 输入映射
   │ Session::execute / cmdline / start / input / zoom_about / idle_click
   ▼
cadcraft-engine → cadcraft-doc → cadcraft-render（tiny-skia CPU 光栅化）  ← 原封不动
```

渲染路径与 web/plot 一致：`render::build` 出 DisplayList，`raster::render` 出 RGBA，
ArkTS 侧 `PixelMap` → `Canvas.drawImage`。命令行、交互命令提示机、点选、缩放全部是引擎
原生行为，不重实现。

Rust 的 OHOS 目标是 Tier 2（`aarch64-unknown-linux-ohos`、`x86_64-unknown-linux-ohos`，
见 [rustc platform support](https://doc.rust-lang.org/rustc/platform-support/openharmony.html)）；
鸿蒙 PC（MateBook Pro / MateBook Fold，Kirin X90）走 aarch64。

## 目录

```
apps/cadcraft-ohos/            Rust Node-API 模块（真 ohos target cargo check 0 warning）
  src/ffi.rs                   libace_napi.z.so externs（唯一链接库，全部不透明句柄，无结构体布局风险）
  src/app.rs                   App：Session + 画布尺寸 + 输入/缩放/打开保存桥
  src/render.rs                DisplayList → tiny-skia → RGBA 帧
  src/lib.rs                   napi_module 注册 + 16 个导出
packaging/harmony/             DevEco Studio 工程（本目录）
  AppScope/app.json5           bundleName: io.github.r4x2t7.coffeecad（备案前改成你自己的反域名）
  build-profile.json5          compatibleSdkVersion 5.0.2(13)，覆盖全部 2in1 机型
  entry/src/main/module.json5  deviceTypes: ["2in1", "tablet"]
  entry/src/main/ets/pages/Index.ets   PC 壳：菜单栏 / Tool Sets / 画布 / 命令行 / 状态栏
  entry/src/main/ets/bridge/CadBridge.ets  napi 导入与类型包装
  entry/libs/arm64-v8a/        build-ohos.sh 产出的 libcadcraft_ohos.so 放这里
  build-ohos.sh                cargo 交叉编译 + 复制 .so + hvigorw 打包
```

## 构建

前置：DevEco Studio 5.1+（含 HarmonyOS PC SDK）、Rust stable、`rustup target add
aarch64-unknown-linux-ohos`（脚本会自动加）。

```bash
export OHOS_SDK_HOME="$LOCALAPPDATA/OpenHarmony/Sdk"   # 含 native/ 的 SDK 根目录
bash packaging/harmony/build-ohos.sh
```

或 GUI 流程：`build-ohos.sh` 跑完 cargo 步骤后，用 DevEco Studio 打开 `packaging/harmony`，
Build > Build Hap(s)/APP(s)。原生 so 由 `entry/libs/arm64-v8a/` 自动打包，无需 CMake。

运行到鸿蒙 PC：`hdc install entry/build/default/outputs/default/entry-default-signed.hap`，
或 DevEco 直接 Run（PC 插上后即真机调试）。

改动要点提示：
- **cfg 门**：ohos triple 的 `target_os = "linux"`、`target_env = "ohos"`——依赖门必须用
  `target_env = "ohos"`（已写好，`rustc --print cfg` 可验证）。
- **坐标**：所有进入 Cad* 的坐标都是设备像素（vp × densityPixels），原点画布左上。
- 工作区 host CI 不受影响：`apps/cadcraft-ohos` 在非 ohos target 下是空库。

## 无真机验证阶梯

不买设备，从软到硬四层：

1. **模拟器自查**（DevEco Studio > Tools > Device Manager 下载 2in1 镜像；Windows 需
   64 位 + 16GB 内存 + OpenGL 4.1）。模拟器覆盖自由窗口行为，提交审核前对照
   [应用UX体验建议](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/experience-suggestions-ux)逐项过：

   | 检查项 | 本工程现状 |
   | --- | --- |
   | 自由窗口缩放 / 分屏 / 悬浮窗不破版 | `module.json5` `supportWindowMode` 全档 + `layoutWeight` 弹性布局 |
   | 最小窗口尺寸 | `EntryAbility` `setWindowMinSize(480×320vp)`（版本不支持时静默降级） |
   | 右键菜单 | 画布 `bindContextMenu`：取消/缩放范围/撤销/重做/LINE/CIRCLE/ERASE |
   | 键盘快捷键入口 | 画布聚焦时 Esc / Enter / Ctrl+Z / Ctrl+Y，`focusOnTouch` 点击即聚焦 |
   | 清晰的焦点反馈 | 画布聚焦描边高亮，TextInput 自带焦点样式 |
   | 高分屏清晰 | 按设备像素渲染（DPR 换算），无平板拉伸 |

2. **云调试 / 远程真机**（[DevEco Testing](https://developer.huawei.com/consumer/cn/deveco-testing/)）：
   无设备跑性能面板与兼容性/稳定性专项。设备列表以控制台实际显示为准——2in1 机型是否可约以平台当时库存为准，约不到就用 1 + 3。
3. **AGC 内测**（开放式测试）：审核前在 AGC 上传测试包、生成邀请链接，发给有鸿蒙设备的
   朋友（平板打开 2in1/自由窗口模式可近似验证 PC 行为），收崩溃与体验反馈。
4. **审核反馈循环**：被拒会给出具体原因和堆栈，改完重传即可——不必为过审专门买真机。

## 发布到 AppGallery（鸿蒙 PC 应用市场）

1. **开发者账号**：[华为开发者联盟](https://developer.huawei.com/consumer/cn/) 注册 + 实名认证
   （个人或企业；企业账号发布类目更宽）。
2. **App 备案（中国大陆分发必须）**：工信部 App 备案（主体 ICP 备案 + App 备案，包名
   `ai.storyteller.cadcraft` 与签名证书信息要一致），AGC 提交审核时会校验。视类目可能需要
   计算机软件著作权登记证书，提前备好。
3. **创建应用**：AGC 控制台 > 我的项目 > 创建应用（应用类型 App，包名与 app.json5 一致）。
4. **命名过审（应用名"咖啡CAD"）**：
   - AGC 提交时查重，与现有应用重名会被要求改名——"咖啡CAD"组合冲突概率低，以提交时提示为准；
   - **名称里不要出现"鸿蒙/HarmonyOS/华为"字样**（审核禁用系统名与厂商商标暗示）；应用描述里写"支持鸿蒙 PC（2in1）"没问题；
   - **App 备案时填的应用名称必须与上架名称一致**（都写"咖啡CAD"），包名备案后锁死；
   - 个人实名账号可上架效率/办公类目，无资质门槛；
   - 图标：`assets/app-icon` 是 MIT OR Apache-2.0，法律上可沿用，但建议自绘（咖啡+直角尺）避免与 CADCraft 商店条目混淆；换了就按仓库规矩在 `ATTRIBUTION.md` 加一行。
5. **签名材料**：AGC 生成/上传发布证书（.cer）+ 申请发布 Profile（.p7b，绑定包名）+
   本地密钥库（.p12）。DevEco Studio > File > Project Structure > Signing Configs 配置
   release 签名，或填 `build-profile.json5` 的 `signingConfigs`。
6. **打包**：Build > Build App(s)/Hap(s) > Build App(s) 产出 **release .app**（不是 HAP）。
7. **应用信息**：分类（效率/办公-图形设计）、隐私政策 URL（AppGallery 要求可访问的网页；
   本应用 v1 无任何敏感权限，无需权限说明）、2in1 端截图（展示键鼠操作与窗口缩放，
   3120×2080 等 PC 分辨率，横竖多张）。
8. **上传 + 提交审核**：AGC > 版本管理 > 上传 .app > 填版本说明 > 提交审核。审核前先走
   上面"无真机验证阶梯"第 3 条的 AGC 内测拿真实反馈。

**2in1/PC 审核要点**（照着自查，都是审核员会点的）：
- 窗口自由缩放/分屏/悬浮窗不破版（module.json5 已开 `supportWindowMode` 全档）；
- 键鼠完整可用：右键、中键拖拽、快捷键、无平板拉伸 UI；
- 高分屏清晰（本方案按设备像素渲染，天然无模糊）；
- 冷启动时间、退出不丢图（引擎有 undo/自动恢复；`EntryAbility.onWindowStageDestroy`
  留了自动存档 TODO，上架前补上）。

## v2 路线（按投入产出排序）

1. **滚轮缩放**：PC 上滚轮是轴事件。两条路：ArkTS 侧按
   [鼠标事件指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/arkts-interaction-development-guide-mouse)
   的回调转发 `cad.zoom`；或 native 侧 `OH_NativeXComponent_RegisterUIInputEventCallback`
   （API 12+，当前仅轴事件）。同时补 `+`/`-` 键。
2. **直接 blit NativeWindow**：绕过 PixelMap 拷贝 —— XComponent(surface) +
   `OH_NativeWindow_NativeWindowRequestBuffer/FlushBuffer` 直写，配合
   `OH_NativeXComponent_RegisterOnFrameCallback` 帧回调。需要对照 SDK 头文件
   `external_window.h` 核对 `OH_NativeWindowBuffer` 字段（唯一剩余的结构体布局项）。
3. **图层/特性面板**：`cadState` 增加图层表与选中实体属性（engine 侧只读 API 已齐）。
4. **对象捕捉**：`Session::snap_cursor`/`input_snapped` 接到 cadMove。
5. **键盘全量**：`OH_NativeXComponent_RegisterKeyEventCallbackWithResult` 拦截画布按键
   （F8 正交、F3 捕捉等），命令行 TextField 保留输入法。
6. **恢复窗口状态**：filesDir 存 DXF 副本 + 启动恢复。

## 许可

与主仓库一致：MIT OR Apache-2.0。本目录未引入任何新资源（图标复用
`assets/app-icon/`，见 `ATTRIBUTION.md`），上架 AppGallery 不引入额外合规项。
