# Quick Share ↔ AirDrop Restore for OPPO Find X9 Ultra (CN / PMA110)

简体中文 | [English](README_EN.md)

这是面向国行 **OPPO Find X9 Ultra（`PMA110`）** 的非官方工具。在 KernelSU Root 环境下，通过临时挂载与配置变更加载 Mosey 组件，让 Google Quick Share 与 Apple AirDrop 互通。物理系统分区保留原样。

**v1.0 正式版。** 基于作者在国行 PMA110 上验证过的 v1.0.7，已确认手机端流程可用，并有与 Mac 双向互传小文件的实测记录。v1.0 安装包已在 macOS 上从实际固件镜像构建并通过签名校验。具体机型、固件和 Google Play 服务版本见下方基准环境。

**获取方式。** 本仓库提供项目源码和构建工具。请自行从匹配的 OTA 提取原厂组件并[本地构建](#四从源码本地构建)。构建出的 APK 和 `vendor/*.tar` 含 Google 或 OPPO 原厂组件，MIT 许可仅覆盖本项目原创代码。请勿把这些产物、固件镜像或签名密钥上传到公开仓库或 Releases。

> **AI 辅助开发与免责提示**：本项目的代码实现、安全审计与文档整理均使用 AI 辅助完成；涉及 Root 权限、动态挂载、框架软重启与 GMS 本地配置变更，使用前请先阅读[免责声明](#七ai-辅助开发说明与免责声明)并自行备份数据，所有风险由使用者自行承担。

---

## 快速开始

1. 核对[基准环境](#一基准环境与兼容性)。手机需要 KernelSU Root，且主用户能正常打开 Google Quick Share。
2. 下载[指定的印尼区 OTA](#2-提取并校验原厂组件)，在电脑上导出 `system_ext.img`，按[构建步骤](#四从源码本地构建)提取五个组件并生成 APK。
3. 按[手机端使用方法](#五手机端使用方法)安装、授予 Root 并点「加载」。如果提示软重启，执行后再点一次「加载」，然后用「查看状态」确认结果。

## 一、基准环境与兼容性

### 1. 作者已实测通过的基准环境
- **机型**：国行 OPPO Find X9 Ultra（`ro.product.model = PMA110`）
- **固件**：`PMA110_17.0.0.105(CN01)`
- **Google Play 服务（GMS）**：`26.45.31`（`versionCode = 264531035`）
- **Root 管理器**：KernelSU（基准为 `ksud 3.3.1 (uapi: 5)` 和 KernelSU BusyBox）。临时 Root 也可用，前提是通过本工具执行软重启后仍可取得 Root。
- **原厂 Mosey 组件来源**：海外同平台机型 `CPH2841`（`MoseyApp 1.0.927074190`）

### 2. 必须先满足的前置条件
运行前请解锁手机并等到桌面完全加载。用户 0（主用户）需要能正常打开 Google Quick Share，且 Google Play 服务主进程正在运行。脚本要求在 GMS 的 `app_phenotype_shared` 目录下找到唯一一份匹配的 Nearby 配置。打开过 Quick Share 仍提示找不到配置时，先检查这项前置条件。

作者的基准环境使用 Coogle 解除国行 GMS 限制。Quick Share 入口是否可用，需要在手机上单独确认。使用已有的 GMS 方案即可，但它占用的挂载点必须与下表兼容。[Coogle 上游说明](https://github.com/zopulus/coogle#readme)

### 3. 加载前的检查

| 检查项 | 默认策略 | 说明 |
| :--- | :--- | :--- |
| **机型与系统固件**（`PMA110` / `PMA110_17.0.0.105(CN01)`） | **默认严格拦截**（可改配置自测） | 跨系统版本可能改变无线驱动（`wonder0`）、系统目录布局或 SELinux 策略。修改 [scripts/config.env](scripts/config.env) 中的 `TARGET_BUILD` 可开启同机型新固件自测，但不能保证自动兼容新固件。 |
| **KernelSU 工具与 Root 独占目录** | **硬要求** | 需存在 `/data/adb/ksud` 与 `/data/adb/ksu/bin/busybox`；全部会话、锁与回滚状态均存放在 Root 独占的 `/data/adb/quickshare-pma110/`（`0700 root:root`），不信任 Shell 可写的 `/data/local/tmp`。暂不支持 Magisk / APatch。 |
| **挂载点与系统更新** | **硬要求** | 准备特权扩展时检查 `/system/priv-app` 和 `/system/etc/permissions` 的挂载冲突，加载服务时检查 VINTF 目录与 APEX 清单的挂载冲突。OTA 状态查询失败或发现已准备待应用的更新时会中止。 |
| **Google Play 服务（GMS）版本** | **弹窗确认并绑定版本号** | 开始改动前，非基准版本需要用户确认当前的精确 `versionCode`。确认后、改动前版本再次变化时会重新询问。点「取消」会保留当前挂载、权限和 GMS 配置。若已经开始撤回旧会话后才检测到版本变化，工具会停止后续步骤并提示查看状态。GMS UID 按用户 0 动态解析。 |
| **Quick Share Extension（`com.google.android.mosey`）** | **核对用户 0 的安装状态** | 用户 0 未安装时可尝试准备特权目录并软重启。已安装时会核对 APK 路径和 SHA-256。包管理器查询失败、不同版本或拆分包更新都会中止操作。 |
| **KernelSU `ksud` 版本** | **检查软重启命令** | 使用 `ksud soft-reboot --help` 检测子命令。使用其他版本会提示版本差异，实际软重启行为取决于所用分支。 |
| **Google Play 商店** | **无版本要求** | 不依赖、不校验 Play 商店版本。 |

### 4. 双向传输测速

作者在国行 PMA110 与 Mac 之间各记录了一次测速。CSV 每秒采样一次。收发方向以 Mac 为参照，Android → Mac 使用 Mac 接收速率 `RX_MB/s`，Mac → Android 使用 Mac 发送速率 `TX_MB/s`。均值取主要方向速率达到 **1 MB/s** 的连续传输区间，峰值取最高单秒采样。

| 方向 | 活跃区间样本数 | 活跃区间均值 | 单秒采样峰值 |
| :--- | ---: | ---: | ---: |
| Android → Mac | 107 | 10.70 MB/s | 11.79 MB/s |
| Mac → Android | 334 | 3.42 MB/s | 3.76 MB/s |

CSV 记录的是收发速率。日志未记录文件大小或传输完成事件，无法据此计算文件端到端速率。脱敏数据将每次记录的第一笔采样设为第 0 秒。 [Android → Mac CSV](docs/benchmarks/android-to-mac.csv) · [Mac → Android CSV](docs/benchmarks/mac-to-android.csv)

---

## 二、工作原理

1. **叶子目录只读叠加 + KernelSU 软重启**（`scripts/prepare-privileged.sh`）
   - 在 PID 1 挂载命名空间内，仅对 `/system/priv-app` 和 `/system/etc/permissions` 两个叶子目录叠加经过解包后成员白名单、非符号链接及 SHA-256 核验的原厂 `MoseyApp.apk` 与权限清单，保护国行 `SystemUI` 与 `liboplus_network_servers.so`。
   - 启动超时/循环重启看门狗后执行 `ksud soft-reboot`（重启 Android 框架而不重启内核），使 `com.google.android.mosey` 获得 `PRIVILEGED` 标志与特权权限。
2. **在线注入 VINTF 服务声明并热刷新缓存**（`scripts/live-vintf.sh`、`native/query_declared.c`）
   - 将经过 SHA-256 校验的原厂 `manifest_mosey.xml` 只读叠加到 `/system_ext/etc/vintf/manifest`。
   - 通过临时 bind-mount 一份仅更新 mtime 的 `/apex/apex-info-list.xml` 副本并调用 `AServiceManager_isDeclared`，触发 `servicemanager` 刷新 VINTF 缓存，生效后立即卸载还原原路径。
3. **无损开启 GMS Nearby 外部提供方开关**（`native/nearby-flag.c`、`scripts/cache-test.sh`）
   - 通过共享逻辑 `resolve_package_uid_u0` 解析用户 0 的 GMS UID 并核对配置属主；经 `nearby-flag` 做逐字节无损往返校验后，仅开启 Flag `45704091`；在同目录保留原文件硬链接备份，临时授予必要位置权限并平滑重启 GMS 主进程。
   - 回滚逻辑对每一步锁获取、卸载与校验均做显式错误判断，任一步失败都会保留 `armed` / `cache-armed` 标记以便后续重试清理。
4. **私有挂载命名空间运行 `mosey_server` 与有限自愈**（`scripts/probe-native.sh`、`native/mosey_lazy_hold.c`）
   - 通过 `unshare -m --propagation private` 隔离私有挂载命名空间，解包核验后叠加 `mosey_server`、`libmosey_daemon_ffi.so` 及 `libmosey_local_binder.so`，不影响全局 `/system_ext/bin` 与 `/system_ext/lib64`。
   - `libmosey_local_binder.so` 让 Binder 服务驻留。监控脚本会记录 `mosey_server` 的退出码和时间，后台意外退出时优先在当前会话内重启。

---

## 三、目录结构

```text
.
├── app/                     # 手机端独立管理 APK（原生 Android Java，minSdk 30，无 Gradle 依赖）
├── scripts/                 # 打包进 APK assets 的手机端 Shell 运行时脚本
│   ├── config.env           # 目标机型/固件/基准版本与原厂组件 SHA-256 集中配置
│   ├── common.sh            # Root 独占目录校验、待应用 OTA 检查、用户 0 UID 解析
│   ├── restore.sh           # 主调度脚本（加载/状态/软重启/撤回/日志）
│   ├── prepare-privileged.sh # 特权目录局部 overlay、解包核验与软重启看门狗
│   ├── live-vintf.sh        # VINTF manifest 注入、APEX 时间戳缓存热刷新与显式回滚
│   ├── cache-test.sh        # GMS Phenotype 开关注入、备份与显式回滚
│   ├── probe.sh             # 桥接脚本
│   └── probe-native.sh      # 私有命名空间启动 mosey_server、解包核验与自动恢复监控
├── native/                  # 3 个原创 arm64 C 工具源码
│   ├── nearby-flag.c        # Phenotype 快照编解码与 --status 只读检查
│   ├── query_declared.c     # 调用 libbinder_ndk.so 查询 VINTF 在线服务声明
│   ├── mosey_lazy_hold.c    # mosey_server 的 LD_PRELOAD 保活垫片
│   └── third_party/
│       └── zlib-LICENSE.txt  # 静态链接 zlib 时的许可声明
├── docs/
│   └── benchmarks/          # 双向测速的脱敏 CSV
├── tools/
│   ├── inspect_ota.py       # 离线/远程 HTTP Range 扫描官方 OTA 中的 EROFS 分区路径
│   ├── extract_vendor.py    # 拒绝符号链接、校验 SHA-256 并打包原厂组件至 vendor/
│   ├── build-native.sh      # 编译 3 个原生 arm64 二进制（支持 Android NDK 或 Zig）
│   ├── build-apk.sh         # 校验 vendor 归档白名单与哈希，编译并签名手机端 APK
│   └── verify-manifest.json # 已验证 CPH2841 原厂组件镜像内路径与 SHA-256 清单
└── vendor/                  # 用户自行提取并生成的闭源组件目录（已被 .gitignore 忽略）
```

---

## 四、从源码本地构建

### 0. 构建依赖

以下命令从仓库根目录运行。完成构建并把 APK 安装到手机后，日常加载和撤回可在手机上独立操作。

- **基础工具**：Bash、支持 `javac --release 8` 的 JDK（含 `keytool`）、Android SDK Build Tools（含 `aapt2`、`d8`、`zipalign`、`apksigner`）与 `platforms/android-35/android.jar`、Python 3、`zip`、`openssl`。
- **原生编译工具链（二选一）**：
  - Android NDK（脚本会尝试 ARM64 API 35、34 和 29 的 clang，也可通过 `NDK_CLANG` 指定）；或
  - Zig（实测 `0.15.2`）+ `zlib` 源码目录 + Android `libc.so`/`libdl.so`。
- **OTA 提取工具**：从官方完整 OTA ZIP 导出 `system_ext.img` 可使用开源 `payload-dumper-go` 等工具；直接从 `system_ext.img`（EROFS）提取组件文件需安装 `erofs-utils`（提供 `dump.erofs`）。

### 1. 编译原生辅助二进制
```bash
# 方式 A：Android NDK
ANDROID_NDK_HOME=/path/to/android-ndk ./tools/build-native.sh

# 方式 B：Zig（若自行再分发静态产物，请同时遵守 musl 与 zlib 许可）
ZIG=/path/to/zig ZLIB_DIR=/path/to/zlib-src BIONIC_LIB_DIR=/path/to/bionic-libs ./tools/build-native.sh
```

编译产物会生成在 `native/bin/`（已被 `.gitignore` 忽略）。

### 2. 提取并校验原厂组件
已核验的下载项是国际版 **`CPH2841_17.0.0.101(EX01)`，印度尼西亚（`ID`），完整 OTA**，大小为 `10,508,029,704` 字节（约 9.79 GiB）。在目录中搜索完整版本号，选中 `ID` 的记录后点击「获取链接」，再从 OPPO CDN 下载。链接过期时回到目录重新获取。此 OTA 只用于在电脑上提取组件。[MyFyFy 固件目录](https://myfyfy.top/)

用 [payload-dumper-go](https://github.com/ssut/payload-dumper-go/releases/tag/2.1.0) 从下载的 ZIP 导出 `system_ext.img`。下列命令已用 2.1.0 验证。

```bash
payload-dumper-go -p system_ext -o /path/to/extracted-ota /path/to/official-ota.zip
```

已核验镜像的内部版本号为 `1792250571287`，`system_ext.img` 的 SHA-256 为 `5fad6016df612752ebe2785c053f5838f412ac9c855b0f2aa22c26ccf527dc63`。同名 OTA 可能有不同地区的包，组件是否匹配以接下来的五项 SHA-256 校验为准。

完成原生编译后，运行 `tools/extract_vendor.py`。它会按 [组件清单](tools/verify-manifest.json) 核对路径和 SHA-256，再将通过校验的组件与本地保活库打包到 `vendor/`。遇到哈希不匹配时先核对 OTA 来源。需要预览 OTA 内目录时，可用 `python3 tools/inspect_ota.py --zip /path/to/official-ota.zip system_ext` 扫描。

```bash
# 方式 A：直接从 system_ext.img 提取（需要 dump.erofs）
python3 tools/extract_vendor.py --system-ext-img /path/to/extracted-ota/system_ext.img

# 方式 B：从已提取好的普通文件目录打包
python3 tools/extract_vendor.py --components-dir /path/to/extracted-components
```

### 3. 构建并签名 APK

```bash
ANDROID_SDK_ROOT=/path/to/android-sdk ./tools/build-apk.sh
```

如需显式指定 SDK 工具，使用：

```bash
BUILD_TOOLS=/path/to/android-sdk/build-tools/35.0.0 \
ANDROID_JAR=/path/to/android-sdk/platforms/android-35/android.jar \
./tools/build-apk.sh
```

构建时会比对 `daemon.tar` 里的保活库与本地编译产物，重新打包通过核验的成员，并将两份归档及保活库的 SHA-256 写入 APK 内的配置副本。手机端在 Root 解包前核验整份归档，并在加载前复核解出的文件。

**关于签名密钥与覆盖升级**：
- 首次构建会在 `build/` 下自动生成本地随机签名密钥（`build/signing.p12` 与 `build/signing.pass`，已被 `.gitignore` 忽略），不同构建目录生成的密钥证书不同，**不能跨密钥直接覆盖安装**（需先卸载旧包或保留并复用同一套 `build/signing.p12` + `build/signing.pass`）。
- v1.0 的内部版本号为 **14**。从内部版本号为 13 的 v1.0.7 测试包升级时，使用原签名密钥重新构建即可保留覆盖安装条件。APK 会按内嵌资源的 SHA-256 指纹选用解包目录。资源缺失或损坏时，会从当前 APK 重建。

---

## 五、手机端使用方法

1. 安装 `build/QuickShare-PMA110.apk`，并在 KernelSU 的「超级用户」中授权 **Quick Share 恢复**。
2. 确保手机已具备 KernelSU Root 且用户 0 已打开过 Quick Share。
3. 打开 **Quick Share 恢复**，点击 **「加载」**：
   - 若 Google Play 服务版本与基准不同，会先弹出确认框，由你决定是否继续。
   - 若提示特权扩展已准备好，点击工具内的 **「软重启」**。
   - 回到桌面并解锁后，再次打开工具点击 **「加载」** 完成加载。
4. 互传时，两端开启 Wi‑Fi 和蓝牙。手机接收时，解锁并进入 Quick Share 的「接收」页。苹果设备接收时，在隔空投送中临时选择允许「所有人」发现，iPhone 或 iPad 上通常显示为「所有人（10 分钟）」。[Google Quick Share 说明](https://support.google.com/googleplay/answer/9286773) · [Apple Mac 隔空投送说明](https://support.apple.com/guide/mac-help/mh35868/mac)
5. 用 **「查看状态」** 检查特权扩展、后台服务、GMS 绑定和 Nearby 开关。点击 **「撤回」** 会停止后台服务并清理本次会话修改的配置和权限。软重启后已生效的特权扩展挂载会在整机重启时消失。

### 兜底方案：若全新手机软重启后特权扩展仍未生效
即使手机原本未装 `com.google.android.mosey`，也可以先走上面的加载流程。如果软重启后再点「加载」或「查看状态」提示**特权扩展挂载仍在但未生效**，按以下步骤处理。
1. 先**整机重启**清除残留的扩展挂载（当前的「撤回」仅清理尚未软重启的准备挂载，不会卸载已软重启的扩展挂载）；若使用临时 Root，重启后先重新取得 Root。
2. 在电脑上从构建时生成的归档取出原厂 `MoseyApp.apk`，核对其 SHA-256 与[组件清单](tools/verify-manifest.json)一致，再手动安装到手机。请保留这个版本，Play 商店更新后的不同版本或拆分包会被拦截。

   ```bash
   tar -xOf vendor/privileged-app.tar ./priv-app/MoseyApp/MoseyApp.apk > MoseyApp.apk
   openssl dgst -sha256 MoseyApp.apk
   ```

3. 重新打开工具执行「加载 → 软重启 → 加载」。

重新加载后，打开「查看状态」，确认显示**「特权扩展 已生效」**和**「Google Play 服务 已连接扩展」**。同版本扩展在特权模式生效后，Android 仍可能保留 `/data/app` 中的副本。

---

## 六、已知限制

- **Apple 设备兼容性**。其他支持 AirDrop 的 Apple 设备理论上也可能与 PMA110 互传，由于作者手头只有 Mac，iPhone、iPad 等设备的兼容性仍待实测。
- **整机重启**会清除内存挂载。临时 Root 失效时需先重新取得 Root，再走「加载 → 软重启 → 加载」。永久 Root 也需重新走加载流程。异常退出留下的状态将在下一次「加载」或「撤回」时尝试清理。
- **后台异常退出**时，工具先在当前会话内尝试重启。会话退出后，如果 Root 仍有效、Android 框架恢复稳定、同一 GMS 版本和特权扩展仍可用，工具可以完整重建会话。后台成功恢复并运行至少 10 分钟后，下一次独立故障可再次触发恢复。自动重建后若在 10 分钟内反复退出，工具会限制继续重建。手动「撤回」会取消自动重建。完整重建会打开 Quick Share，并核对后台、扩展连接和 Nearby 开关。
- **GMS 配置刷新**可能让本地 Nearby 开关失效。如果后台仍在运行但双方不可见，先点「查看状态」。发现开关关闭或配置中已找不到该开关时，再点「加载」可尝试重建会话。
- **传输卡在 97%–99%**是 PMA110 基准测试中观察到的现象，有时文件已经落盘。可保持手机 Wi‑Fi 开启，临时关闭当前路由器的「自动连接」后重试。需要确认文件完整时，比较两端的 SHA-256。
- **反馈问题**时，请提供机型、固件、GMS 和 KernelSU 版本、操作步骤及相关错误。贴日志前请删去账号标识、设备名、MAC 地址和带签名参数的 OTA 链接。作者目前只能在上面列出的基准环境中复测。欢迎提交其他环境的兼容性反馈，能否定位和修复取决于日志和复现条件。
- **第三方许可**：`native/nearby-flag.c` 依赖 `zlib`，其许可证见 [native/third_party/zlib-LICENSE.txt](native/third_party/zlib-LICENSE.txt)。

---

## 七、AI 辅助开发说明与免责声明

### AI 辅助开发说明
本项目的脚本与源码编写、构建工具整理、安全审计及文档撰写过程均借助 AI 工具辅助完成。尽管已进行主机端真实镜像提取、编译签名、静态检查与模拟回归，仍可能存在未覆盖的系统差异或边界缺陷；建议在理解其原理与风险后再自行构建使用。

### 免责声明
- 本项目为个人非官方开源工具与技术研究，与 **OPPO、Google、Apple 或 KernelSU** 均无任何隶属、合作或官方背书关系。
- 本工具需要 **Root 权限**，会执行系统目录内存叠加挂载、Android 框架软重启以及 Google Play 服务本地配置文件修改，存在导致设备重启循环、系统或网络功能异常、数据丢失、保修失效或相关服务异常的潜在风险。
- 本项目按“现状（AS IS）”提供，不作任何明示或暗示的适用性或可靠性担保。**请务必在操作前备份重要数据；因使用、修改或二次分发本工具产生的一切后果与损失均由使用者自行承担，作者不承担任何法律或赔偿责任。**

---

## License

本仓库原创代码采用 [MIT License](LICENSE) 开源。
