# IINA Dell Display Color Preset

IINA 插件与原生 helper，用于在 IINA 窗口跨显示器移动时自动管理 Dell 显示器 Color Preset。

## 当前阶段

当前仓库包含显示器发现、DDC Backend、Profile 配置、状态管理、Socket daemon 和 IINA 插件。Profile 位于独立的 `native/Profile/profiles.json`，helper 从可执行文件旁加载 `profiles.json`；文件缺失或无效时，Color Preset 写入关闭。显示器身份使用 EDID UUID（如果系统提供）加厂商、产品和序列号的组合；如果没有 EDID UUID，则使用厂商、产品和序列号。两台 U2725QE 即使共用 EDID UUID，也会按不同序列号区分。缺少可靠序列号时输出空身份，后续写操作必须跳过。`systemUUID` 和 `displayID` 仅作辅助信息。

DDC Set 会先读取原始值，写入后回读验证；验证失败时尝试恢复原值。U2723QE 与 U2725QE 的 Color Preset Movie 编码为 `0x03`，且 `0xDC` 写入只允许已验证 Profile。状态管理器会记住每台屏幕接管前的值、在目标切换时恢复旧屏、避免重复接管覆盖原值，并保留失败/断连的恢复记录。daemon 通过 JSON Lines Unix Socket 接受一个插件会话；客户端断开后会恢复接管屏幕，恢复失败时以 1 到 30 秒退避重试。U2725QE Product ID `0x436B` 取自用户提供的实机枚举信息。

## 构建

维护和发布需要 Apple Silicon Mac、macOS、Apple Clang 和 Command Line Tools。执行：

```sh
make -C native clean plugin
```

此命令会：

1. 编译 `native/` 中的 Objective-C 源码，生成 `native/build/display-helper`。
2. 从 `native/Profile/profiles.json` 读取 Profile 配置。
3. 将 helper 分块编码为仓库根目录的 `helperPayload.js`，并将 Profile 编码为 `profilesPayload.js`。helper 分块避免 JavaScriptCore 解析单个超大数组字面量时失败。
4. 组装 `native/build/DellColorPreset.iinaplugin/`，供本机开发或用 IINA CLI 打包。

IINA 不会替插件编译 `native/` 源码。**每次修改 native 代码或 Profile 后，都要重新执行构建，并将生成的两个 payload 和源码一起提交**；否则从 GitHub 安装的用户会得到旧的 helper 或 Profile。`native/build/` 属于本地构建目录，不需要提交。

构建后可检查 helper 架构和文件：

```sh
file native/build/display-helper
ls -lh helperPayload.js profilesPayload.js
```

当前发布产物为 Apple Silicon `arm64`，暂不支持 Intel Mac。

## 从 GitHub 安装

仓库根目录包含 IINA 的 `Info.json`、`entry.js`、`main.js` 和生成的 payload。仓库公开后，用户在 IINA 的 **Settings → Plugins → Install from GitHub** 输入：

`https://github.com/adowls/iinaplugin-dell-color-preset`

IINA 会下载仓库内容，但不会执行 `make`。首次启动时，插件自行将内嵌 helper 和 Profile 安装到 IINA 的 `@data/bin`，并设置 helper 可执行权限；用户无需单独安装编译工具或手动复制 `bin`。`native/` 源码会随仓库一起下载，但运行时不使用这些源码文件。

`Info.json` 的 `ghRepo` 应保持为 `adowls/iinaplugin-dell-color-preset`。每次发布可用更新时，同时递增 `version` 和 `ghVersion`；IINA 用 `ghVersion` 检查 GitHub 更新并提示用户更新。仓库必须公开可访问，普通用户才能通过 IINA 安装。

## 运行与卸载

插件启动一个全局 watcher，每 500 ms 检查 IINA 窗口所在显示器，并在目标变化时通知 daemon。插件启动 IINA WebSocket API 的本机服务，Native Helper 每秒发送一条带序号和临时令牌的 `PING`，插件回复对应的 `PONG`。Helper 接受文本或二进制 WebSocket 数据帧（IINA 的 `sendText` 会以 UTF-8 二进制帧传输），最多等待 3 秒；超时或断连后关闭 daemon 的 Unix Socket 会话，由 daemon 恢复接管的显示器。插件从本地端口 `43120–43151` 中选择可用端口。心跳不再周期性写入磁盘；升级到此版本后，插件启动时会删除旧版遗留的 `@data/watcher.heartbeat`。标题栏归属使用窗口顶部 32 pt 区域判定。日志可在 IINA 的 **Window → Log Viewer** 查看。

卸载时，在 IINA 的插件设置中移除 **Dell Display Color Preset**。IINA 结束插件会话后 daemon 会恢复其接管的显示器。插件数据目录 `@data` 中的 helper 和 Profile 文件可随插件一并删除；daemon 运行目录位于 `~/Library/Application Support/IINA/plugins/dell-color-preset/run/`。

### 编辑 Display Profiles

在 IINA 的 **Settings → Plugins → Dell Display Color Preset → Preferences** 中查看和编辑 `profiles.json` 内容。**Restore bundled defaults** 会将 U2723QE 和 U2725QE 的内置配置载入编辑框；点击 **Save** 后保存。设置页会校验 JSON 结构、字段类型、数值范围和重复 Profile。Profile 在 helper 启动时加载，所以保存或恢复默认值后都要完全退出并重新启动 IINA 才会生效。若配置无效，插件会回退到内置默认 Profile 并在 IINA 日志中报告错误。

## Native Helper 手动调试

构建完成后可使用以下命令检查显示器、Profile 和 DDC：

```sh
native/build/display-helper list
native/build/display-helper profiles
native/build/display-helper get '10AC-436B-4247574C' 0xDC
native/build/display-helper set '10AC-436B-4247574C' 0xDC 3
native/build/display-helper daemon
native/build/display-helper client
```

默认 Socket 位于 `~/Library/Application Support/IINA/plugins/dell-color-preset/run/helper.sock`。daemon 创建权限为 `0700` 的运行目录、`0600` 的 Socket，并用相邻 lock 文件的 `flock` 阻止重复实例。client 自动发送 HELLO，然后把标准输入中的 JSON Lines 转发给 daemon；EOF 会断开会话并触发恢复。发送 QUIT 也会关闭会话并触发恢复。

协议消息示例：

```json
{"type":"SET_TARGET","requestId":2,"identity":"10AC-436B-4247574C"}
{"type":"STATUS","requestId":3}
{"type":"QUIT","requestId":4}
```

输出为 JSON 数组。`displayID` 只供本次运行诊断使用，不能用作持久身份。

## 设计约束

- 已验证 Profile：Dell U2723QE（Vendor `0x10AC`、Product `0x426D`）与 U2725QE（Vendor `0x10AC`、Product `0x436B`），均使用 VCP `0xDC`、Movie `0x03`。
- 未识别型号不得自动写入；Profile 必须匹配准确 Vendor ID、Product ID、型号和验证状态。
- 恢复值必须从每台显示器读取，不能假设 Standard 固定为 `0x00`。
- 写操作必须通过 DDC 响应校验和写后回读验证。
- Profile 必须精确匹配厂商 ID、产品 ID 和型号 token，且 `verified` 为 `true`。

`set` 在写入前必须能读取当前 VCP 值；写入成功以相同 Feature 的回读值匹配为准。Apple Silicon DDC 使用 CoreDisplay 私有 IOAVService API，并需要进程能访问图形会话和 IOKit。DDC 后端参考 m1ddc，MIT 许可证见 [native/DDC/LICENSE-m1ddc](native/DDC/LICENSE-m1ddc)。
