---
created: 2026-11-04T18:29:19+08:00
updated: 2026-11-04T18:29:46+08:00
---

# 1. IINA Dell Display Color Preset Automation

## 1.1. 技术设计方案（Technical Design Specification）

版本：1.0
目标平台：macOS 27.x / Apple Silicon
开发语言：Objective-C、JavaScript
构建工具：Apple Clang / macOS Command Line Tools
底层参考项目：[m1ddc](https://github.com/waydabber/m1ddc)

---

# 2. 项目目标

开发一个 IINA 插件，在 IINA 窗口所在的显示器发生变化时，自动调整 Dell 外接显示器的 OSD Color Preset。

核心行为：

1. IINA 窗口位于已支持的 Dell 显示器时，将该显示器的 Color Preset 切换为 Movie。

2. IINA 窗口离开该显示器时，恢复该显示器进入 IINA 前的原始 Color Preset。

3. IINA 窗口从一台 Dell 显示器移动到另一台 Dell 显示器时：

	- 恢复旧显示器的原始状态。

	- 将新显示器切换为 Movie。

4. IINA 窗口位于 Mac 内置屏幕或非 Dell 显示器时，恢复此前接管的 Dell 显示器。

5. IINA 退出、插件异常退出或 Unix Socket 连接断开时，daemon 尝试恢复所有被接管显示器。

6. 如果显示器原本已经是 Movie，则不需要修改，退出时也不需要恢复。

7. 不依赖播放、暂停、停止等播放状态，仅根据 IINA 窗口所在的显示器决定。

## 2.1. 非目标

- 不控制亮度、对比度等其他 VCP 参数。

- 不修改 macOS 显示器配置。

- 不要求 BetterDisplay 常驻。

- 不依赖 m1ddc 命令行程序。

- 不要求用户手动选择显示器。

- 不支持未经验证的显示器型号。

- 不将显示器状态持久化到磁盘。


---

# 3. 已验证的硬件与 DDC 行为

## 3.1. 测试环境

- MacBook Pro，Apple M5 Max。

- macOS 27.2，Build 26B123。

- Dell U2723QE。

- Dell U2725QE。

- m1ddc 1.3.1。


已测试的连接拓扑包括：

**拓扑 A：**

MacBook Pro 分别通过两根 USB-C 线直连两台 U2723QE。

**拓扑 B：**

MacBook Pro Thunderbolt 连接一台 U2725QE，再由该显示器 Thunderbolt 下游菊花链连接另一台 U2725QE。

程序不得依赖上述固定拓扑，应动态发现显示器。

## 3.2. 已验证的 VCP 编码

Dell U2723QE：

|VCP Feature|Value|含义|
|---|---|---|
|0xDC|0x00|Standard|
|0xDC|0x03|Movie|

已确认通过 DDC/CI 写入 VCP `0xDC=0x03` 可以切换到 Movie，写入 `0xDC=0x00` 可以恢复 Standard。

注意：

- 不能将 `0x00` 视为所有显示器的默认值。

- 必须读取每台显示器自己的原始值。

- 不得假设其他 Dell 型号使用相同编码。

- U2725QE 尚未完成验证，暂不允许自动修改。

## 3.3. 显示器身份识别

同型号显示器必须能够区分。

已获取的 U2723QE 信息：

|属性|显示器 A|显示器 B|
|---|---|---|
|Model|U2723QE|U2723QE|
|Vendor|10AC|10AC|
|Product|426D|426D|
|Alphanumeric Serial|29X08P3|71Z19P3|
|macOS Display ID|4|5|
|System UUID|8178B113-0B15-4A6C-845A-6CC72EBF48F1|656B99C3-C5F4-4BA1-9F9B-3AF0620BB514|
|EDID UUID|10AC6D42-0000-0000-2521-0104B53C2278|10AC6D42-0000-0000-2821-0104B53C2278|

以上信息仅用于说明身份识别需求，禁止硬编码这些值。

身份识别原则：

- macOS Display ID 是临时标识，不得作为持久身份。

- m1ddc display index 是动态索引，不得作为持久身份。

- 优先使用 EDID UUID。

- 同时保存厂商、产品 ID、序列号、型号等辅助信息。

- 当 EDID UUID 不可用时，使用经过验证的替代身份组合。

- 如果无法可靠区分两个物理显示器，禁止执行写操作。


建议生成：

`DisplayIdentity`

其逻辑组成：

- vendorID

- productID

- edidUUID

- manufacturer

- model

- alphanumericSerial

- serialNumber


其中 `edidUUID` 为首选唯一标识。

---

# 4. 总体架构

采用三个逻辑模块：

1. IINA JavaScript Plugin

2. Native Helper / Daemon

3. DDC Backend


整体结构：

```
+--------------------------------------+
|              IINA                    |
|                                      |
|  +--------------------------------+  |
|  |       JavaScript Plugin        |  |
|  |                                |  |
|  |  Window Monitor                |  |
|  |  Display Resolver              |  |
|  |  Socket Client                 |  |
|  +---------------+----------------+  |
+------------------|-------------------+
                   |
                   | Unix Domain Socket
                   |
+------------------v-------------------+
|          Native Helper               |
|                                      |
|  +--------------------------------+  |
|  |           Daemon               |  |
|  |                                |  |
|  |  Socket Server                 |  |
|  |  Session Manager               |  |
|  |  State Manager                  |  |
|  |  Display Manager                |  |
|  |  Profile Manager                |  |
|  +---------------+----------------+  |
|                  |                   |
|  +---------------v----------------+  |
|  |          DDC Backend           |  |
|  |                                |  |
|  |  Display Discovery              |  |
|  |  DDC Read                       |  |
|  |  DDC Write                      |  |
|  +---------------+----------------+  |
+------------------|-------------------+
                   |
                   | IOKit / IOAVService / I2C
                   |
+------------------v-------------------+
|       Dell External Displays         |
+--------------------------------------+
```

## 4.1. Native Helper

最终交付一个独立 Mach-O 可执行文件。

同一个二进制支持：

- CLI 模式

- Daemon 模式


建议命令：

```
display-helper list
display-helper info <identity>
display-helper get <identity> 0xDC
display-helper set <identity> 0xDC <value>
display-helper daemon
```

CLI 和 daemon 必须共用相同的底层 DDC 实现。

CLI 主要用于开发、测试和诊断。

Daemon 是插件实际使用的运行模式。

## 4.2. 技术约束

- Objective-C。

- Apple Clang。

- Foundation。

- IOKit。

- CoreGraphics。

- CoreDisplay（如需要）。

- 使用系统提供的 C/C++ 运行库。

- 不使用 Swift。

- 不使用 Swift Package Manager。

- 不依赖 Homebrew。

- 不依赖外部 m1ddc 可执行文件。

- 不依赖 BetterDisplay。

- 不引入不必要的第三方运行时库。


复用 m1ddc 源码时保留 MIT License 和原始版权声明。

---

# 5. DDC Backend 设计

## 5.1. 设计原则

DDC Backend 应从 m1ddc 源码中提取必要的显示器发现、I2C 通信和 DDC 编解码能力。

不要直接将 m1ddc 的命令行程序整体嵌入 daemon。

建议将其重构为独立模块：

```
DDCBackend/
    DisplayDiscovery.h
    DisplayDiscovery.m

    DDCTransport.h
    DDCTransport.m

    DDCProtocol.h
    DDCProtocol.m

    DDCFeature.h
    DDCFeature.m

    DisplayIdentity.h
    DisplayIdentity.m
```

## 5.2. 显示器发现

参考 m1ddc：

- `getOnlineDisplayInfos()`

- `getDisplayDDCTransport()`


利用：

- `CGGetOnlineDisplayList`

- `CoreDisplay_DisplayCreateInfoDictionary`

- IOKit Registry

- EDID 信息

- IO Display Location

- DCPAVServiceProxy

- IOMobileFramebuffer


需要动态枚举所有在线显示器。

不能假定最多只有 4 台显示器。

原始 m1ddc 中 `MAX_DISPLAYS` 的固定容量设计应改为动态分配，或者实现有边界保护的动态扩容机制。

每次发现显示器时，生成完整的 DisplayInfo。

建议结构：

```
@interface DisplayInfo : NSObject

@property(nonatomic, copy) NSString *identity;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy) NSString *manufacturer;
@property(nonatomic, copy) NSString *edidUUID;
@property(nonatomic, copy) NSString *alphanumericSerial;

@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, assign) uint32_t productID;

@property(nonatomic, assign) CGDirectDisplayID displayID;

@property(nonatomic, assign) uint64_t adapterRegistryID;
@property(nonatomic, copy) NSString *ioLocation;

@end
```

Display ID、adapter registry ID 等运行时信息不能代替物理显示器身份。

## 5.3. DDC Transport

参考 m1ddc 的：

- `getDisplayDDCTransport()`

- `IOAVServiceCreateWithService`

- `IOAVServiceReadI2C`

- `IOAVServiceWriteI2C`


继续复用 Apple Silicon DCP 架构所需的 I2C 通信流程。

注意：

- 根据显示器 adapter 定位正确的 IOMobileFramebuffer。

- 根据 DCPAVServiceProxy 创建对应 IOAVService。

- 保留 m1ddc 针对不同芯片选择 I2C chip address 的逻辑。

- 不允许把某个显示器的 transport 错误地用于另一台显示器。

- 资源使用完成后正确释放 IOKit 对象和 IOAVService。


m1ddc 当前通过 extern 声明使用部分私有 API。

需要评估使用 `dlsym` 动态解析这些 API 的可行性，以便在符号不存在时明确报告不支持，而不是直接导致启动失败。

私有 API 的 macOS 版本兼容性需要作为独立风险处理。

## 5.4. DDC Get

实现通用 VCP Get：

```
get(displayIdentity, featureCode)
```

至少支持：

- 0xDC：Color Preset

- 其他 VCP Feature：通用查询接口


Get 操作应返回：

```
{
  "success": true,
  "feature": 220,
  "currentValue": 3,
  "maximumValue": 17
}
```

具体字段可以按实际 DDC 响应能力调整。

必须增强 m1ddc 原有响应解析逻辑。

不能仅提取 current/max 两个数值就认为读取成功。

需要校验：

- DDC 响应类型。

- 响应长度。

- checksum。

- Feature Code 是否匹配。

- 响应格式是否符合预期。

- 传输层是否成功。

- 超时和异常响应。


任何校验失败，都应返回明确错误，不得将无效数据当成有效 VCP 值。

## 5.5. DDC Set

实现：

```
set(displayIdentity, featureCode, value)
```

写入成功不能仅凭 I2C 写函数返回成功判断。

建议：

1. 执行 DDC Set。

2. 检查传输结果。

3. 等待显示器完成操作。

4. 必要时重新读取 VCP，验证最终状态。


对于 `0xDC`，应尽可能通过 Get 验证设置结果。

如果显示器不支持读取或验证失败，不能将未经验证的状态宣称为成功。

---

# 6. Display Profile

不同型号的 Dell 显示器可能使用不同的 VCP 编码。

因此必须采用 Profile 机制。

## 6.1. Profile 结构

```
@interface DisplayProfile : NSObject

@property(nonatomic, copy) NSString *model;

@property(nonatomic, assign) uint32_t vendorID;
@property(nonatomic, assign) uint32_t productID;

@property(nonatomic, assign) uint8_t featureCode;
@property(nonatomic, assign) uint16_t movieValue;

@property(nonatomic, assign) BOOL verified;

@end
```

## 6.2. 初始配置

当前仅配置已经实测确认的 U2723QE：

```
Model: U2723QE
Vendor: 0x10AC
Product: 0x426D
Feature: 0xDC
Movie Value: 0x03
Verified: YES
```

Standard 的值不作为固定恢复值，而是从显示器实际读取。

U2725QE：

```
Verified: NO
```

不执行自动写入。

## 6.3. Profile 匹配规则

必须同时满足：

1. Vendor ID 匹配。

2. Product ID 匹配。

3. Model 匹配。

4. Profile 标记为 Verified。


如果型号识别结果存在冲突，禁止执行写操作。

将 Profile 配置与 DDC Backend 分离。

以后增加显示器型号时，只需增加配置，不修改核心状态管理逻辑。

---

# 7. Daemon 设计

## 7.1. Daemon 职责

Daemon 是整个系统的状态管理核心。

职责：

- 接收插件命令。

- 管理 Unix Domain Socket。

- 发现和识别显示器。

- 读取原始 VCP 状态。

- 切换 Movie。

- 恢复原始 VCP 状态。

- 管理显示器接管状态。

- 处理插件断开连接。

- 在恢复完成后退出。


Daemon 不负责判断 IINA 窗口在哪台显示器上。

这一职责属于 JavaScript Plugin。

## 7.2. 运行方式

IINA 插件启动时：

1. 检查 daemon 是否已经运行。

2. 如果没有运行，启动 daemon。

3. 连接 Unix Domain Socket。

4. 建立 IINA Session。

5. 开始发送窗口所在显示器信息。


Daemon 不使用 LaunchAgent，不要求长期驻留。

## 7.3. Socket 路径

建议：

```
~/Library/Application Support/IINA/plugins/dell-color-preset/run/helper.sock
```

实际运行时需要注意：

- 确保目录权限为当前用户独占。

- Socket 文件不能被其他用户替换。

- 启动时检查残留 Socket。

- 不允许未经验证就删除已有 Socket。

- 防止多个 daemon 实例竞争同一 Socket。

- 使用合理的文件权限，例如目录 0700、Socket 0600。


建议使用 `flock` 或其他可靠机制实现单实例保护。

## 7.4. 连接管理

Daemon 运行期间保持 Socket 连接。

连接断开时：

1. 判定当前 IINA Session 已结束。

2. 停止接受该 Session 的显示器切换请求。

3. 恢复所有已接管显示器。

4. 如果恢复失败，继续重试。

5. 恢复完成后关闭 Socket Server。

6. 删除自己的 Socket 文件。

7. 退出进程。


恢复失败时不能立即退出并丢弃内存状态。

建议采用有限频率的后台重试，例如逐步增加重试间隔，并设置合理上限，避免持续高频 DDC 请求。

如果显示器已经物理断开，记录错误并继续等待其重新出现，在 daemon 仍然运行时尝试恢复。

纯内存状态不保证 daemon 崩溃或 Mac 重启后的恢复能力。

---

# 8. 状态管理

## 8.1. 状态记录

每台被接管的显示器维护一条记录。

```
@interface DisplayState : NSObject

@property(nonatomic, copy) NSString *identity;

@property(nonatomic, assign) uint8_t originalValue;
@property(nonatomic, assign) uint8_t movieValue;

@property(nonatomic, assign) BOOL originallyMovie;

@property(nonatomic, assign) BOOL changedByPlugin;

@property(nonatomic, assign) BOOL restorePending;

@end
```

内存状态字典：

```
Dictionary<DisplayIdentity, DisplayState>
```

不写入磁盘。

## 8.2. 核心原则

**第一次接管时读取原始值，之后无论窗口如何移动，都不能覆盖这份原始值。**

同一台显示器在一个 IINA Session 内只能有一份原始状态记录。

## 8.3. 接管流程

```
AcquireDisplay(display)
        |
        v
检查是否已经存在状态记录
        |
        +---- 是 ----> 不重新读取、不覆盖原始值
        |              确保目标仍为 Movie
        |
        +---- 否
               |
               v
       匹配 Display Profile
               |
               +---- 不支持 ----> 跳过
               |
               v
       读取 VCP 0xDC 原始值
               |
               +---- 失败 ----> 记录错误，跳过
               |
               v
       保存原始值到内存
               |
               v
       原始值是否已经是 Movie？
               |
          +----+----+
          |         |
         是         否
          |         |
          v         v
      不写入     Set Movie
          |         |
          |         v
          |      验证写入结果
          |         |
          |      +--+--+
          |      |     |
          |     成功   失败
          |      |     |
          |      |   清理状态
          |      |   （仅在确认未修改时）
          +------+-----+
                 |
                 v
             接管成功
```

重要要求：

- 原始值读取失败时，绝不写入 Movie。

- 未知型号不执行写入。

- 原始值已经是 Movie 时，不执行 Set。

- Set 失败时，不能误认为显示器已经被成功接管。

- 如果 Set 已经发生但结果验证失败，必须先尝试恢复原始值；无法确认状态时保留恢复记录并进入恢复重试流程。

## 8.4. 释放流程

```
ReleaseDisplay(display)
        |
        v
检查是否存在状态记录
        |
        +---- 否 ----> 无操作
        |
        v
originallyMovie ?
        |
        +---- 是 ----> 清除记录
        |
        v
changedByPlugin ?
        |
        +---- 否 ----> 清除记录
        |
        v
Set originalValue
        |
        v
验证恢复结果
        |
        +---- 成功 ----> 清除记录
        |
        +---- 失败 ----> 保留记录，稍后重试
```

不得简单地把恢复值写成 Standard。

必须恢复最初读取到的真实值。

## 8.5. 多显示器切换

例如：

初始状态：

```
Display A = Standard
Display B = Standard
```

IINA 位于 A：

```
Display A = Movie
Display B = Standard
```

状态记录：

```
A.originalValue = Standard
```

IINA 移动到 B：

```
Display A = Standard
Display B = Movie
```

状态记录：

```
B.originalValue = Standard
```

IINA 再次移动回 A：

```
Display A = Movie
Display B = Standard
```

A 的原始状态不能重新读取为 Movie。

否则会导致最终恢复错误。

## 8.6. 原始状态已经是 Movie

如果某显示器第一次接管时读取到：

```
0xDC = 0x03
```

则：

- 不执行 DDC Set。

- 记录原始状态。

- 释放时不执行 DDC Set。

- 清除内存记录。


保证用户原本的 Movie 状态不被破坏。

---

# 9. IINA JavaScript Plugin

## 9.1. 职责

插件负责：

1. 启动 Native Helper。

2. 建立 Unix Domain Socket。

3. 监控 IINA 窗口所在显示器。

4. 将显示器身份发送给 daemon。

5. 处理连接和错误。

6. 在插件退出时关闭连接。


插件不直接执行 DDC 操作。

## 9.2. 窗口检测

检测间隔：

```
500 ms
```

每次检测获取：

- IINA 窗口位置。

- IINA 窗口所属显示器。

- 显示器身份。


跨屏时，以窗口标题栏所在屏幕为准。

不要使用窗口面积占比判断。

如果 IINA 插件 API 无法可靠获得标题栏所在屏幕，需要评估通过 macOS 原生辅助代码实现窗口归属检测。

不得简单使用窗口中心点代替标题栏规则，除非已经验证二者在目标环境下等价。

## 9.3. 显示器识别

插件应将窗口所在显示器转换为稳定身份标识。

不发送临时 Display ID 作为唯一身份。

建议发送：

```
{
  "type": "SET_TARGET",
  "identity": "10AC6D42-0000-0000-2521-0104B53C2278"
}
```

如果目标是内置屏幕、非 Dell 显示器或者无法识别的显示器：

```
{
  "type": "SET_TARGET",
  "identity": null
}
```

Daemon 收到 null 后释放此前接管的显示器。

## 9.4. 去重

500 ms 检查不代表每 500 ms 都发送 Socket 消息。

只有目标显示器身份发生变化时才发送 `SET_TARGET`。

例如：

```
A -> A -> A -> B -> B -> null
```

实际发送：

```
SET_TARGET(A)
SET_TARGET(B)
SET_TARGET(null)
```

如果显示器拓扑发生变化，应重新解析身份，并处理已断开显示器的状态记录。

---

# 10. Unix Domain Socket 协议

建议采用 JSON Lines：

- 一条消息一行。

- UTF-8 编码。

- 每条消息以 `\n` 结束。

- 每条消息包含唯一 request ID。

- 限制单条消息最大长度。

- 对非法 JSON 和未知消息类型返回错误。

## 10.1. 插件到 Daemon

### 10.1.1. HELLO

```
{
  "type": "HELLO",
  "requestId": 1,
  "client": "IINA-Dell-Preset-Plugin",
  "version": "1.0"
}
```

### 10.1.2. SET_TARGET

```
{
  "type": "SET_TARGET",
  "requestId": 2,
  "identity": "10AC6D42-0000-0000-2521-0104B53C2278"
}
```

### 10.1.3. SET_TARGET_NULL

```
{
  "type": "SET_TARGET",
  "requestId": 3,
  "identity": null
}
```

### 10.1.4. STATUS

```
{
  "type": "STATUS",
  "requestId": 4
}
```

### 10.1.5. QUIT

正常情况下，IINA 退出时关闭 Socket 即可触发恢复。

QUIT 可作为显式退出协议，但不能替代连接断开检测。

## 10.2. Daemon 到插件

### 10.2.1. HELLO_ACK

```
{
  "type": "HELLO_ACK",
  "requestId": 1,
  "success": true,
  "daemonVersion": "1.0"
}
```

### 10.2.2. RESULT

```
{
  "type": "RESULT",
  "requestId": 2,
  "success": true,
  "identity": "10AC6D42-0000-0000-2521-0104B53C2278",
  "state": "movie"
}
```

### 10.2.3. ERROR

```
{
  "type": "ERROR",
  "requestId": 2,
  "code": "DDC_READ_FAILED",
  "message": "Unable to read VCP 0xDC"
}
```

### 10.2.4. STATUS_RESULT

返回：

- 当前目标显示器。

- 已接管显示器。

- 原始 VCP 值。

- 当前管理状态。

- 待恢复状态。

- 最近错误。


不要返回不必要的底层 IOKit 对象信息。

---

# 11. Daemon 状态机

建议将 Session 和单显示器状态分开管理。

## 11.1. Session 状态

```
STARTING
   |
   v
CONNECTED
   |
   v
ACTIVE
   |
   v
DISCONNECTING
   |
   v
RESTORING
   |
   +---- 恢复完成 ----> STOPPED
   |
   +---- 恢复失败 ----> RETRYING
                           |
                           +---- 恢复完成 ----> STOPPED
```

## 11.2. 单显示器状态

建议定义：

```
UNMANAGED
READING_ORIGINAL
ORIGINAL_MOVIE
SETTING_MOVIE
MANAGED_MOVIE
RESTORING
RESTORE_PENDING
```

必须避免多个异步任务同时对同一显示器执行 Set。

建议对每台显示器使用串行操作队列，或者由一个统一状态管理队列串行执行所有状态变更。

---

# 12. 异常处理

## 12.1. DDC Get 失败

- 跳过该显示器。

- 不执行 Set。

- 记录错误。

- 不影响 IINA 正常播放。

## 12.2. DDC Set Movie 失败

- 不宣称接管成功。

- 如果不能确认是否已写入，尝试恢复原始值。

- 恢复失败时保留记录并重试。

- 不影响 IINA 正常使用。

## 12.3. 恢复失败

- 保留内存状态。

- 不清除原始值。

- 进入重试队列。

- 避免高频重试。

## 12.4. 显示器拔出

- 暂时保留其原始状态记录。

- 不将断开的显示器视为已成功恢复。

- 如果仍有其他目标显示器，继续正常工作。

- 在 daemon 仍运行且设备重新出现时，尝试恢复。

- 如果 Session 已结束，daemon 在恢复完成前保持运行。

## 12.5. IINA 插件崩溃

Socket 断开后由 daemon 自动恢复。

不能依赖 JavaScript 的退出回调作为唯一恢复机制。

## 12.6. Daemon 崩溃或系统重启

状态只保存在内存中。

因此 daemon 崩溃或系统重启后：

- 内存记录丢失。

- 不保证自动恢复原始色彩模式。


这是本项目接受的设计限制。

---

# 13. 日志设计

建议使用统一日志格式。

```
[INFO] Daemon started
[INFO] Display discovered: U2723QE / 29X08P3
[INFO] Original VCP 0xDC: 0x00
[INFO] Set VCP 0xDC: 0x03
[INFO] Display acquired
[INFO] Display released
[INFO] Original VCP restored: 0x00
[WARN] Unsupported display profile: U2725QE
[ERROR] DDC read failed
[ERROR] DDC restore failed
```

日志应包含：

- 时间戳。

- 日志级别。

- 显示器身份。

- 操作类型。

- VCP Feature。

- 原始值和目标值。

- 错误代码。


不得在日志中使用临时 Display ID 作为显示器的唯一身份。

建议提供：

```
display-helper list
display-helper info <identity>
display-helper get <identity> 0xDC
display-helper status
```

方便排查问题。

---

# 14. 项目目录建议

```
IINA-Dell-Color-Preset/
│
├── README.md
├── LICENSE
│
├── plugin/
│   ├── Info.json
│   ├── main.js
│   ├── WindowMonitor.js
│   ├── DisplayResolver.js
│   └── NativeHelperManager.js
│
├── native/
│   ├── Makefile
│   │
│   ├── main.m
│   │
│   ├── CLI/
│   │   ├── CommandParser.h
│   │   └── CommandParser.m
│   │
│   ├── Daemon/
│   │   ├── Daemon.h
│   │   ├── Daemon.m
│   │   ├── SocketServer.h
│   │   ├── SocketServer.m
│   │   ├── SessionManager.h
│   │   ├── SessionManager.m
│   │   ├── StateManager.h
│   │   └── StateManager.m
│   │
│   ├── Display/
│   │   ├── DisplayInfo.h
│   │   ├── DisplayInfo.m
│   │   ├── DisplayIdentity.h
│   │   ├── DisplayIdentity.m
│   │   ├── DisplayDiscovery.h
│   │   └── DisplayDiscovery.m
│   │
│   ├── DDC/
│   │   ├── DDCBackend.h
│   │   ├── DDCBackend.m
│   │   ├── DDCTransport.h
│   │   ├── DDCTransport.m
│   │   ├── DDCProtocol.h
│   │   └── DDCProtocol.m
│   │
│   └── Profile/
│       ├── DisplayProfile.h
│       ├── DisplayProfile.m
│       └── profiles.json
│
└── tests/
    ├── test_ddc_protocol.m
    ├── test_display_identity.m
    ├── test_state_manager.m
    ├── test_socket_protocol.m
    └── test_profile.m
```

以上是逻辑模块划分，不要求机械地为每个类建立独立文件。Coding LLM 可以根据实际实现复杂度合并文件。

---

# 15. 构建要求

使用 Apple Clang。

不使用 Swift 或 SwiftPM。

Makefile 示例：

```
CC = clang

CFLAGS = -Wall -Wextra -O2 \
         -fobjc-arc \
         -mmacosx-version-min=13.0

FRAMEWORKS = \
    -framework Foundation \
    -framework IOKit \
    -framework CoreGraphics \
    -framework CoreDisplay

SOURCES = $(shell find . -name '*.m')

TARGET = display-helper

all:
	$(CC) $(CFLAGS) $(SOURCES) \
	    $(FRAMEWORKS) \
	    -o $(TARGET)

clean:
	rm -f $(TARGET)
```

这是初始示意，实际链接参数应根据复用的 m1ddc 源码和私有 API 符号解析方式调整。

注意：

- 不要未经验证就加入不必要的 framework。

- 处理 macOS 私有 API 的链接兼容性。

- 确保最终 helper 为原生 Apple Silicon Mach-O。

- 检查插件打包后的可执行权限。

- 检查 Gatekeeper、签名及 Hardened Runtime 对 IOKit 和私有 API 的影响。


---

# 16. 开发实施顺序

不要一次性完成整个项目。

建议分阶段实现，每个阶段都有可验证的结果。

## 16.1. Phase 1：显示器发现

目标：

- 从 m1ddc 提取显示器发现代码。

- 实现动态显示器枚举。

- 获取完整 DisplayInfo。

- 区分两台同型号显示器。

- 支持动态拓扑。


验收：

```
display-helper list
```

能够正确列出所有在线显示器，并且每台显示器都有稳定身份。

## 16.2. Phase 2：DDC Backend

目标：

- 提取 DDC Transport。

- 实现通用 VCP Get。

- 实现通用 VCP Set。

- 完善 DDC 响应校验。

- 实现超时和错误处理。


验收：

```
display-helper get <identity> 0xDC
```

能够读取两台 U2723QE 的实际值。

然后进行单台显示器测试：

```
display-helper set <identity> 0xDC 3
display-helper get <identity> 0xDC
display-helper set <identity> 0xDC <original-value>
```

必须确认最终状态正确。

注意：不要默认原始值是 0。

## 16.3. Phase 3：Display Profile

目标：

- 实现 Profile 加载和匹配。

- 加入 U2723QE 已验证配置。

- 将 U2725QE 标记为未验证。

- 未知型号禁止写入。


验收：

- U2723QE 能正确匹配。

- U2725QE 不执行自动切换。

- 未知显示器不执行写操作。

## 16.4. Phase 4：State Manager

目标：

- 实现接管。

- 实现释放。

- 实现原始值保存。

- 实现原始 Movie 状态处理。

- 实现失败重试。

- 防止重复接管覆盖原始值。


这一阶段应使用 Mock DDC Backend 编写自动化测试。

重点测试：

1. Standard → Movie → Standard。

2. 原始 Movie → 不写入 → 保持 Movie。

3. A → B → A → 最终全部恢复。

4. Set 失败。

5. Restore 失败。

6. 显示器断开后重新连接。

7. 同一显示器重复发送 SET_TARGET。

8. 原始值不能被后续 Movie 状态覆盖。

## 16.5. Phase 5：Socket Server

目标：

- 实现 Unix Domain Socket。

- 实现 JSON Lines 协议。

- 实现连接断开检测。

- 实现单实例保护。

- 实现异常退出恢复。


验收：

- CLI 客户端可以连接 daemon。

- 可以发送 SET_TARGET。

- 可以获取 STATUS。

- 客户端断开后 daemon 恢复显示器。

- 恢复成功后 daemon 自动退出。

## 16.6. Phase 6：IINA Plugin

目标：

- 实现 Native Helper 自动启动。

- 实现 Socket Client。

- 实现窗口检测。

- 实现 500 ms 轮询。

- 实现窗口所属显示器识别。

- 实现目标显示器变化去重。


验收：

- IINA 窗口位于 U2723QE 时切换 Movie。

- 移动到另一台 U2723QE 时，旧屏恢复，新屏切 Movie。

- 移动到 MacBook 内置屏幕时，外接屏恢复。

- 移动到未知 Dell 型号时，不执行写入。

- 关闭 IINA 后自动恢复。

- 插件异常退出后自动恢复。

## 16.7. Phase 7：集成测试

至少测试：

|场景|预期行为|
|---|---|
|IINA 位于 U2723QE|切换 Movie|
|IINA 从 A 移到 B|A 恢复，B 切 Movie|
|IINA 从 B 移回 A|B 恢复，A 切 Movie|
|IINA 位于内置屏幕|所有接管屏恢复|
|IINA 位于 U2725QE|不操作未验证型号|
|原始模式已经是 Movie|不修改|
|原始模式为 Standard|退出时恢复 Standard|
|原始模式为其他 Preset|退出时恢复原始值|
|DDC Get 失败|跳过，不写入|
|DDC Set 失败|记录错误，不影响 IINA|
|显示器拔出|保留状态，等待重新出现|
|IINA 退出|恢复全部接管屏|
|Socket 意外断开|恢复全部接管屏|
|daemon 意外崩溃|不保证恢复，符合纯内存设计|

---

# 17. 关键实现原则

Coding LLM 必须遵守以下原则：

1. 不要硬编码 Display ID、m1ddc index 或显示器数量。

2. 不要用显示器型号作为唯一身份，同型号设备必须区分。

3. 不要将 BetterDisplay 或 m1ddc CLI 作为运行时依赖。

4. 不要把原始 VCP 值写成固定 Standard。

5. 不要在每次窗口检测时重复读取并覆盖原始值。

6. 不要对未经验证的显示器型号执行 DDC 写入。

7. 不要把 DDC 写函数返回成功直接视为状态切换成功。

8. 不要因为某台显示器 DDC 操作失败而影响 IINA。

9. 不要依赖插件退出回调作为唯一恢复保障。

10. 不要将状态持久化到磁盘。

11. 不要让多个异步任务同时修改同一台显示器。

12. 不要在恢复失败时清除原始状态记录。

13. 不要在显示器已经物理断开时错误地宣称恢复成功。

14. 保留 m1ddc 的 MIT License 和版权声明。


---

# 18. 当前已知风险和待验证事项

|项目|当前状态|处理方式|
|---|---|---|
|U2723QE Movie 编码|已验证|使用 0xDC=0x03|
|U2723QE Standard 编码|已验证|仅作为测试参考|
|U2725QE Movie 编码|未验证|暂不启用|
|DDC 通用 Get|源码已有实现，尚需增强验证|Phase 2 实测|
|DCPAVServiceProxy|m1ddc 已有实现|复用并验证|
|私有 API 兼容性|存在系统版本风险|动态解析并检测|
|窗口标题栏归属检测|需要确认 IINA API 能力|Phase 6 验证|
|插件与 helper 生命周期|需要集成测试|Phase 5/6|
|daemon 崩溃恢复|不保证|纯内存方案的已知限制|

---

# 19. 最终交付物

1. IINA 插件安装包。

2. 独立 Mach-O Native Helper。

3. Native Helper CLI。

4. Daemon。

5. U2723QE Display Profile。

6. DDC Backend。

7. 自动化测试。

8. Makefile。

9. README。

10. m1ddc MIT License 及必要版权声明。


README 应包含：

- 安装方法。

- 卸载方法。

- 构建方法。

- 支持型号。

- DDC/CI 开启要求。

- 日志查看方法。

- 故障排查方法。

- 已知限制。


**项目完成标准：** 在两台同型号 Dell 显示器之间移动 IINA 窗口时，能够准确切换 Movie，并在窗口离开或 IINA 退出后准确恢复每台显示器各自原始的 Color Preset；整个过程不依赖外部 DDC 软件，也不需要用户手动干预。