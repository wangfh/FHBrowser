# 第三方组件与许可声明

本项目源码采用 MIT 许可证（见 `LICENSE`）。下列第三方组件**不包含在本仓库中**
（或仅以源码引用的方式使用），使用与分发时须遵守各自的许可条款。

## 1. CEF（Chromium Embedded Framework）

- 用途：浏览器内核，运行时以二进制形式随 Release 附件分发。
- 版本：109.0.5414.176（Win32）。
- 许可：BSD 3-Clause（CEF 自身）；Chromium 使用 BSD 许可及大量第三方组件许可。
- 要求：分发 `libcef.dll` 等二进制时，必须一并提供 CEF 发行包内的
  `LICENSE.txt`、`credits.html`（或等价的第三方许可清单），不得移除版权声明。
- 说明：Chromium 109 已停止安全更新，仅建议用于学习/演示。

## 2. CEF4Delphi / CEF4Win7（Delphi 绑定）

- 源码：<https://github.com/salvadordf/CEF4Delphi/tree/109.0.5414.120>
- 用途：Delphi 侧的 CEF 封装（`uCEF*.pas`），编译时通过 `CEF4WIN7` 环境变量引用
  使用者本机的源码目录，**不随本仓库分发**。
- 仓库内附带文件：`src/cef.inc`（CEF 版本判定包含文件），拷自 CEF4Delphi，
  版权归 Salvador Diaz Fau / Henri Gourvest。
- 许可：DCEF3 原始许可仍然适用 —— **LGPL 或 MPL 1.1 双选**，
  **不适用本项目的 MIT 许可证**。该文件保留原始版权头，分发时不得移除；
  修改该文件需按 LGPL/MPL 条款公开修改后的源码。
- 说明：如需完全避免该许可约束，可在构建时改从 `$(CEF4WIN7)\source\cef.inc`
  引用同名文件，并删除仓库内的副本（工程需保证 `{$I cef.inc}` 能解析到它）。

## 3. SQLite（sqlite3.dll）

- 用途：书签、历史记录的本地存储。
- 许可：Public Domain。
- 说明：`sqlite3.dll` 随 Release 运行时附件提供。

## 4. madExcept

- 用途：可选的崩溃报告（默认关闭，通过 `MADEXCEPT` 编译定义启用）。
- 许可：**商业软件**，需单独购买授权；不得随本仓库或二进制分发其源码/组件。
- 说明：未安装 madExcept 时本项目可正常编译与运行。

## 5. Delphi / VCL

- 用途：编译器与 UI 框架。
- 许可：Embarcadero 商业许可。本仓库不包含 Delphi 运行时源码或再分发组件；
  构建者需自行安装合法授权的 Delphi 11。

## 6. 字体与图标

- 界面使用系统字体（Segoe UI 等）；图标为项目内 GDI/GDI+ 代码自绘，
  未嵌入第三方图标库资源。