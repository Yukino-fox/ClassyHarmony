# 签名与构建

本文件记录 ClassyHarmony 在「本地构建 → 真机安装」这条链路上的实测结论。
每一条都是在本机（DevEco Studio 26.0.0.621 / SDK API 26）跑出来的，不是推断。

## 一、构建侧不验签，装机侧才验签

这是最关键的一条，它决定了离线签名的天花板在哪。

| 环节 | 是否校验 p7b 的 CMS 签名链 | 自签 profile 的结果 |
| --- | --- | --- |
| `hvigor` 的 `SignHap`（`hap-sign-tool.jar`） | **否**，只解析 JSON 取字段 | 构建成功，产出可用的 signed HAP |
| 设备 `bm` 安装（`hdc install`） | **是** | `code:9568257 fail to verify pkcs7 file` |

所以：**自签材料能让工程完整构建出签名包，但装不进真机。**
装机要用的 profile 必须由华为 CA 签发，只能来自 AGC。

AGC 下发的调试 profile 签名链是：

```
Huawei CBG Root CA G20
  └─ Huawei CBG Software Signing Service CA
       └─ HOS Profile Management Debug        <- profile 的实际签名者
```

## 二、四个必须遵守的格式约束

以下每条都是踩过的坑，改配置时不要退化。

1. **`cert.cer` 必须是证书链，不能是单张证书。**
   报 `ERROR: 11013004 Profile cert must a cert chain`。
   原厂 `.cer` 是 3 张：`Root -> Intermediate -> 开发证书`（叶子 CN 形如 `某某(1942964305372703617)\Development`）。
   而 profile JSON 里的 `development-certificate` 字段只放**叶子**那一张。

2. **`storePassword` / `keyPassword` 必须是加密态，且长度 ≥ 32。**
   报 `The length of the storePassword or keyPassword field ... is less than 32`。
   用 AGC CLI 加密（依赖 `~/.ohos/config/material/` 密钥目录）：

   ```bash
   connect-api-cli provision encrypt-pwd --config-dir ~/.ohos/config --pwd <明文>
   ```

3. **`material/` 密钥目录必须与 `storeFile` 同级。**
   缺了会在 `DecipherUtil.getKey` 抛 `ENOENT ... stat '.../material'`，
   但外层只显示 `Error Code: 00308018 Unknown Error`（极具误导性，真因在 `.hvigor/outputs/build-logs/build.log`）。
   解密发生在 `HapSignCommandBuilder.getKeyStorePwd`，所以目录要跟着 `storeFile` 放。

4. **`signAlg` 用 `SHA256withECDSA`**（密钥是 EC P-256 时）。

## 三、两条签名路径

工程默认 `signingConfigs: []`，此时能构建但只产出 `entry-default-unsigned.hap`。
要出签名包，二选一：

### A. AGC 正式调试签名（唯一能装真机的路径）

前提：`com.yukinofox.classyharmony` 的 p7b/cer/p12 已由 AGC 签发。两种获取方式：

- **IDE 自动签名**：DevEco Studio 打开工程 →
  `File → Project Structure → Signing Configs` → 勾「自动签名」→ 登录 AGC 账号 →
  **在设备下拉里选中目标真机**（调试 profile 的 `device-ids` 必须含该设备，否则装不上）→ Apply。
  材料会落到 `~/.ohos/config/default_*_{p12,cer,p7b}`，然后：

  ```bash
  ./tools/apply-signing.sh
  ```

  该脚本按 **p7b 内文里的 `bundle-name`** 定位材料，不靠文件名猜 ——
  DevEco 的文件名用的是工程名/应用名（如 `default_Solliana_*.p7b` 实际绑的是
  `com.yukinofox.solliana`），与 `bundleName` 无关。同时校验 `type` 必须是 `debug`，
  并可用 `DEVICE_UDID=<udid>` 校验目标设备在不在授权列表里。

- **AGC API 全自动**：给 `AGC_CLIENT_ID` / `AGC_CLIENT_SECRET`（写进工程 `.env`，已 gitignore），
  走 `csr-generate -> cert-create -> device-add -> profile-create -> encrypt-pwd`。

### B. 自签材料（只用于验证构建链路完整，装不上真机）

```bash
./tools/selftest-signing.sh gen      # 造三级链 + 自签 p7b
./tools/selftest-signing.sh wire     # 接进 build-profile.json5
# ... assembleHap 会在此产出 signed HAP ...
./tools/selftest-signing.sh unwire   # 复位（往返无损）
```

`gen` 会生成：根 CA、中间 CA、开发证书叶子（`cert.cer` = 三者拼接）、
只含叶子密钥的 `key.p12`、`storeFile` 同级的 `material` 软链，
以及由自签「HOS Profile Management Debug」签的 `profile.p7b`。

> `wire` / `unwire` 改 `build-profile.json5` 时有两个易错点，脚本里已处理：
> 判定「空数组」必须**先于**宽模式（否则 `\[...\]` 会跨过 `[]` 吃掉 `products` 的收尾），
> 且 `cfg` 首行不能带前导缩进（会与原文叠加成 8 空格，且 `unwire` 补不回来）。

## 四、模块类型与工程配置

踩过两个致命错配，都会让 hvigor 任务图建不起来（IDE 表现为「找不到 assembleHap 任务」）：

1. **HAR 模块的 `module.json5` 写 `"type": "har"`，不是 `"shared"`。**
   `type` 与 `hvigorfile.ts` 导出的 `system` 必须配套：
   `har`↔`harTasks`、`shared`↔`hspTasks`、`entry`/`feature`↔`hapTasks`。
   写成 `shared` + `harTasks` 会报 `Unable to get plugin in hvigorfile.ts of module 'common_shared'`。

2. **HAR 的 `module.json5` 字段集比 HAP 严格得多**，多写会被 schema 直接拒。
   HAR 只保留 `name` / `type` / `description` / `deviceTypes`；
   `deliveryWithInstall`、`installationFree` 等都不允许。
   另外各模块的 `string.json` 别都用 `module_desc` 这个名字，会撞名告警。

`assembleHap` 是**模块级**任务，必须带 `-p module=<mod>@<target>`：

```bash
hvigorw --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap
```

工程级只有 `init`（同步，IDE 打开工程时跑的就是它）、`assembleApp`、`clean` 等，
**没有 `assembleHap`** —— 在工程级调它会报
`Task [ 'assembleHap' ] was not found in the project`，这属于正常现象，不是配置错误。
另外 `hvigorw tasks` 只列「公开任务」，内部构建任务不会出现在列表里，
所以「任务列表里没有 assembleHap」也不能当作它不存在的证据。

## 五、真机信息

- 设备：MLN-AL00，HarmonyOS 7.0.0.107，API 26（与工程 `targetSdkVersion` 一致）
- udid：`110141E5A2094FA4195B16B074A0AB5F2CC37D75B7E5957578A73FEA6BF5E935`
- 连接：`hdc tconn 192.168.3.2:33765`（掉线后要重连，否则报 `Not match target founded`）
- 模拟器 `127.0.0.1:5555` 是 API 24，装不上本工程（目标 API 26）
