# NodShot · 点头快门

手机挂在脖子上、双手拿产品时，**点一下头就拍一张**的 iPhone 相机 App。

没有 Mac 也能装 —— 用 GitHub 的免费 macOS 服务器编译，再在 Windows 上侧载到手机（第 3 节）。

---

## 1. 为什么必须自己写一个 App

| 方案 | 能不能用你现在的姿势 | 原因 |
|---|---|---|
| 相机 App + 音量键 | ❌ | 需要手按 |
| Apple Watch 遥控快门 | ❌ | 需要另一只手去点表盘 |
| 蓝牙 / 脚踏快门 | 勉强 | 要买硬件，还得站着踩，不能走动 |
| 系统「头部跟踪」(iOS 26) | 勉强 | 靠头部指针去点屏幕上的快门，抖一下就点偏，实测很难用 |
| **NodShot（本方案）** | ✅ | 前置摄像头看你的脸 → 点头 → 后置摄像头拍照 |

核心机制：iPhone 允许多个摄像头同时工作（`AVCaptureMultiCamSession`），所以可以一路用前置盯你的头、另一路用后置拍产品，互不干扰。

```
            ┌──────────── iPhone（磁吸挂脖支架，上仰）────────────┐
 你的脸 ───▶│ 前置摄像头 → Vision 人脸关键点 → 点头/张嘴判定        │
            │                                        │            │
            │                                        ▼ 触发        │
 产品  ◀────│ 后置摄像头 ←────────── 拍照（12MP）←─── 快门        │
            └────────────────────────────────────────┬────────────┘
                                                     ▼
                                            相册「最近项目」
```

因为屏幕朝着你的胸口上方、你正在看产品，**所有反馈都靠声音 + 震动**，屏幕只在开拍前用来调参数。

### 你的磁吸挂脖支架需要注意两点

1. **前置摄像头离脸很近**（通常 20~35cm）。Vision 只看到半张脸时判定会飘，所以开拍前先用「测试模式」确认「已锁定人脸」是绿的。
2. **后置摄像头朝下前方**，所以产品要拿在**腰腹高度、身前 30~50cm**，别举到胸口——举太高就出画了。

---

## 2. 文件说明

```
NodShot/
├── project.yml                       Xcode 工程描述（XcodeGen 用，云端编译靠它）
├── Support/Info.plist                权限声明（相机、相册）
├── Sources/
│   ├── ContentView.swift             界面：启动/停止、灵敏度、触发方式、实时幅度条
│   └── CameraEngine.swift            核心：双摄会话、Vision 点头检测、快门、存相册
└── .github/workflows/build-ipa.yml   GitHub Actions：自动编译出 NodShot.ipa
```

---

## 3. 没有 Mac 怎么装（推荐路线）

原理：GitHub 给每个仓库提供免费的 macOS 服务器 → 在那边编译 → 下载未签名的 `NodShot.ipa` → 用 **Sideloadly**（有 Windows 版）以你自己的 Apple ID 签名并装进手机。

> ⚠️ **实测提醒**：本机网络下 `github.com` 不通（`api.github.com` 通，`github.com` 返回 000/504），
> 因此 `gh auth login` 在换取 token 那一步会断（`unexpected EOF`），`git push` 也会失败。
> 这条路需要**能正常访问 github.com 的网络**。如果暂时没有，先用仓库外的
> `../语音拍照-两分钟设置卡.md`（系统自带语音控制，说一声"拍"就拍），零安装。

> 前置条件：一个免费 GitHub 账号 + 一根数据线 + 你这台 Windows。全过程约 40 分钟，其中 35 分钟在等下载。

### 3.1 把代码推到 GitHub（10 分钟）

1. 注册 / 登录 [github.com](https://github.com)
2. 右上角 **+ → New repository** → Repository name 填 `nodshot` → 选 **Public**（Public 仓库跑 macOS 服务器完全免费）→ Create repository
3. 装 **GitHub Desktop**（desktop.github.com，比命令行省事），登录账号 → **File → Clone repository** → 选刚建的 `nodshot` → 选一个本地目录
4. 把本目录 `NodShot/` 里的**全部内容**（`project.yml`、`Support/`、`Sources/`、`.github/`、`.gitignore`）拷进刚克隆下来的文件夹
5. 回 GitHub Desktop → 左下填一句 Summary（比如 `init`）→ **Commit to main** → **Push origin**

> `.github` 是隐藏文件夹，Windows 资源管理器要先勾「显示隐藏项目」才看得见。
> 万一拷丢了，就在 GitHub 网页上仓库首页 → **Add file → Create new file** → 文件名直接输入 `.github/workflows/build-ipa.yml` → 粘贴内容 → Commit。

### 3.2 云端编译（5 分钟）

1. 打开 `https://github.com/你的用户名/nodshot/actions`
2. 左边选 **build-ipa** → 右边 **Run workflow → Run workflow**
3. 等 3~5 分钟，出现绿色的 ✅
4. 点进这次运行 → 页面最下面 **Artifacts** → 下载 **NodShot-ipa**（是个 zip，解压得到 `NodShot.ipa`）

如果红了 ❌：同样在 Artifacts 里下载 **xcodebuild-log**，把报错发我。

### 3.3 用 Windows 侧载进手机（15 分钟）

1. 电脑装两个东西：
   - **iTunes**（apple.com/itunes 官网版，**不要**微软商店版，驱动不全）
   - **Sideloadly**（sideloadly.io）
2. iPhone 用数据线连电脑 → 手机上点「信任此电脑」→ 输入锁屏密码
3. 打开 Sideloadly：
   - `iDevice` 选你的 iPhone
   - 把 `NodShot.ipa` 拖进 **IPA** 框
   - **Apple Account** 填你的 Apple ID（普通 iCloud 账号即可，免费）
   - 点 **Start**，按提示输入 Apple ID 密码
     - 开了双重认证的，一般输正常密码就行；若提示密码错误，去 appleid.apple.com → 登录与安全 → **App 专用密码** 生成一个填进去
4. 手机上：
   - 设置 → 通用 → **VPN与设备管理** → 点你的 Apple ID → **信任**
   - 设置 → 隐私与安全性 → **开发者模式** → 打开 → 重启手机
5. 桌面出现「点头快门」，打开，允许相机和相册权限

**会踩的坑**

| 现象 | 原因 / 解决 |
|---|---|
| `Unable to install` / bundle id 冲突 | 这个 id 被别人占了。Sideloadly 里把 **Bundle ID** 改成 `com.你的名字.nodshot` 再装 |
| 装完闪退、打不开 | 描述文件没信任（回第 4 步），或签名已过期（见 3.4） |
| 一直转圈/识别不到设备 | 装的是微软商店版 iTunes，卸了换官网版 |
| 提示超过 3 个 App | 免费账号同时最多 3 个自签 App，先删一个不用的 |

### 3.4 关于「7 天过期」

免费 Apple ID 签的 App **7 天后会闪退**（图标还在，点开就退）。到期后：手机连电脑，重复 3.3 的第 3~4 步，用同一个 ipa 重签一次（不用重新编译）。

想彻底免掉：**$99/年 苹果开发者账号** → 签一次管 1 年；有付费账号还能走 **TestFlight**（GitHub Actions 加一步上传，手机扫码装，90 天一次，连数据线都省）。要的话我给你加进 workflow。

### 3.5 备选：借一台 Mac（20 分钟）

借到 Mac 就走这条路，装完手机就不需要 Mac 了（7 天后可以在 Windows 上用 Sideloadly 续签）。

1. Xcode → `File > New > Project` → **iOS** → **App** → Product Name `NodShot`，Interface **SwiftUI**，Language **Swift**
2. 删掉自动生成的 `ContentView.swift`
3. 把 `Sources/ContentView.swift`、`Sources/CameraEngine.swift` 拖进工程（勾 *Copy items if needed*）
4. target → **General** → Minimum Deployments 改成 **iOS 17.0**（代码用了 iOS 17 的接口）
5. target → **Info** → 加两行：`Privacy - Camera Usage Description`、`Privacy - Photo Library Additions Usage Description`
6. target → **Signing & Capabilities** → 勾 *Automatically manage signing* → Team 选你的 Apple ID → Bundle Identifier 改成 `com.你的名字.nodshot`
7. 手机连上 → 顶部选你的 iPhone → **⌘R**

---

## 4. 现场调参流程（重要，5 分钟）

你挂到脖子上以后看不到屏幕，所以一定按这个顺序：

1. **先拿在手里**，屏幕对着自己，点「启动」。
2. 看「已锁定人脸」是否变绿。一直是橙色 → 调支架角度，让前置能看到**整张脸**（额头到下巴）。
3. 打开 **测试模式**（只震动不拍照），正常点 3 次头，看「点头幅度」条能不能稳定冲过 100%。
   - 冲不过去 → 灵敏度往右拉；
   - 没点头就乱跳 → 灵敏度往左拉。
4. 「两次拍摄最小间隔」建议 **1.5~2.0 秒**，否则一次点头会连拍三四张。
5. 关掉测试模式，正式拍一张，确认相册里有图、构图正常。
6. **照片转了 90°**？把「竖屏挂法」开关切一下（对应 `CameraEngine.buildSession()` 里的 `videoRotationAngle`，可改 0 / 90 / 180 / 270）。
7. 挂到脖子上，点一下头，听到快门声 + 震一下就成了。

**调不出来**

- **点头不灵** → 切「张嘴」模式。前置离脸很近时张嘴比点头稳得多（不受支架/身体晃动影响），你在画面外，表情无所谓。
- **总是连拍** → 灵敏度降、间隔拉长。
- **误触发**（没点头也拍）→ 通常是低头看产品时整张脸下移被当成点头。把支架角度再抬高一点，让中性姿态下脸在画面偏上，留出下移余量；或直接用「张嘴」。

---

## 5. 已知限制

- **画质** 默认 12MP（4032×3024），产品图够用。想上 48MP：`buildSession()` 里给 `photoOutput.maxPhotoDimensions` 设 `supportedMaxPhotoDimensions.last`，但双摄同开时内存吃紧，可能被系统降级。
- **发热/耗电**：双摄 + 25fps 分析，连续拍 30 分钟以上会明显温热，建议接充电宝。
- 不支持双摄的老机型（iPhone X 及更早）自动进单摄模式，只能测试触发、不存图。
- 想加「拍完 0.5 秒再来一张」的包围曝光，或语音报数（"第 5 张"），在 `fire()` 里加 TTS 即可。
