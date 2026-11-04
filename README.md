# IINA Dell Display Color Preset

IINA 插件与原生 helper，用于在 IINA 窗口跨显示器移动时自动管理 Dell 显示器 Color Preset。

## 当前阶段

当前仓库实现设计方案 Phase 1 的显示器发现 CLI。它动态枚举在线屏幕，并输出厂商、产品、型号、序列号和运行时 Display ID。能拿到 EDID UUID 时优先使用；否则身份由 vendor/product 与序列号组成。缺少可靠序列号的显示器会输出空身份，后续写操作必须跳过。

DDC 读写、已验证型号 Profile、状态管理、Socket daemon 和 IINA 插件尚未实现。当前 helper 不会修改任何显示器设置。

## 构建与使用

需要 macOS、Apple Clang 和 Command Line Tools：

```sh
make -C native
native/build/display-helper list
```

输出为 JSON 数组。`displayID` 只供本次运行诊断使用，不能用作持久身份。

## 设计约束

- 自动写入范围仅计划支持经过实测确认的 Dell U2723QE（Vendor `0x10AC`、Product `0x426D`、VCP `0xDC`、Movie `0x03`）。
- U2725QE 和未识别型号不得自动写入。
- 恢复值必须从每台显示器读取，不能假设 Standard 固定为 `0x00`。
- 在完成 DDC 响应校验与写后回读前，不会启用写操作。
