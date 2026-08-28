# kacc_crypto 鲲鹏密码算法优化介绍

## 最新消息

- [2026.08.28]：发布 kacc_crypto 1.0，新增 AES-XTS SVE2 优化、AES-GCM SVE2 优化和 RSA multi-buffer 优化。

## 项目简介

### 简介

`kacc_crypto` 是面向 Kunpeng 950 AArch64 平台的 OpenSSL 密码算法优化源码仓库，当前包含 AES-XTS、AES-GCM 和 RSA 三类优化代码、源码接入脚本以及功能/性能验证脚本。

本仓库当前不提供独立运行时库。AES-XTS 和 AES-GCM 优化通过源码接入方式集成到目标 OpenSSL 源码树，重新编译 OpenSSL 后，业务应用仍通过 OpenSSL EVP/provider 接口调用对应算法；RSA 优化当前通过独立 benchmark 可执行文件验证 8 路多缓冲 private CRT 路径。

`kacc_crypto` 适用于 OpenSSL 密码算法优化验证、SVE2 指令路径评估、上游化补丁开发和性能基线对比等场景。

### 软件架构

`kacc_crypto` 以 OpenSSL 源码树为集成目标，通过接入脚本把优化源码、构建规则和分发逻辑写入 OpenSSL 对应模块。整体架构如[**图 1** 软件架构](#软件架构)所示。

**图 1** 软件架构<a id="软件架构"></a>

```text
应用程序
   |
   | OpenSSL EVP/provider 接口
   v
OpenSSL AES-XTS / AES-GCM / RSA 入口
   |
   | 平台能力判断、长度阈值判断、key size 判断
   v
+-----------------------------+-----------------------------+
| OpenSSL 原生路径            | kacc_crypto 优化路径        |
| ARMv8/NEON/BN 实现          | SVE2 AES/GHASH/RSA x8 实现  |
+-----------------------------+-----------------------------+
```

软件架构中各模块功能如[**表 1** 模块功能描述](#模块功能描述)所示。

**表 1** 模块功能描述<a id="模块功能描述"></a>

| 模块名称 | 功能描述 |
| --- | --- |
| 应用程序 | 使用 OpenSSL 标准接口调用 AES-XTS、AES-GCM 或 RSA 能力。 |
| OpenSSL EVP/provider | 提供算法入口、上下文管理和硬件能力分发。 |
| OpenSSL 原生路径 | 保留 OpenSSL 已有 ARMv8/NEON/BN 实现，作为不满足优化条件时的回退路径。 |
| AES-XTS SVE2 优化 | 新增 AArch64 SVE2 AES-XTS stream 实现，支持 AES-128/192/256 XTS 加解密。 |
| AES-GCM SVE2 优化 | 新增 SVE2 AES-CTR 与 GHASH 大窗口融合路径，支持 AES-128/192/256 GCM 加解密。 |
| RSA SVE2 x8 优化 | 新增 8 路多缓冲 Montgomery 计算内核，通过 benchmark 验证 RSA2048/RSA4096 private CRT 性能。 |
| 接入脚本 | 把优化源码复制到目标 OpenSSL 源码树，并修改构建规则和分发锚点。 |
| 测试脚本 | 提供正确性验证、性能矩阵测试和 benchmark 可执行文件生成入口。 |

### 算法支持与规格

当前支持的算法和调用方式如[**表 2** 算法支持与规格](#算法支持与规格表)所示。

**表 2** 算法支持与规格<a id="算法支持与规格表"></a>

| 算法 | 支持规格 | 优化方式 | 调用方式 | 说明 |
| --- | --- | --- | --- | --- |
| AES-XTS | AES-128-XTS、AES-192-XTS、AES-256-XTS 加密和解密 | SVE2 AES 指令实现 XTS stream 热路径 | OpenSSL EVP/provider AES-XTS | 不满足能力条件或不适合 SVE2 的输入继续走 OpenSSL 原生路径。 |
| AES-GCM | AES-128-GCM、AES-192-GCM、AES-256-GCM 加密和解密 | SVE2 AES-CTR 与 GHASH 大窗口融合 | OpenSSL EVP/provider AES-GCM | 默认 8192B 及以上进入 SVE2 路径，小包和尾部保留 ARMv8/NEON 路径。 |
| RSA | RSA2048、RSA4096 private CRT benchmark | SVE2 x8 Montgomery 多缓冲计算 | 独立 benchmark 可执行文件 | 当前不是 OpenSSL 对外 RSA API 的透明分发。 |

>![](./docs/zh/public_sys-resources/icon-note.gif) **说明：**
>
>- AES-XTS 当前热路径按 SVE vector length 为 256 bit 的机器调优，其他 VL 需要单独验证。
>- AES-GCM 需要目标机器支持 ARMv8 AES、PMULL 和 SVE2。
>- RSA benchmark 输出 `correctness=PASS` 表示功能校验通过。

## 目录结构

项目目录层级介绍如下：

```text
├── docs                                      # 项目文档目录
│   ├── LICENSE                               # 文档许可证
│   └── zh                                    # 中文文档目录
│       ├── installation_guide.md             # 安装指南
│       ├── menu_kacc_crypto.md               # 文档菜单
│       ├── quick_start.md                    # 快速入门
│       ├── release_notes.md                  # 版本说明书
│       ├── user_guide.md                     # 用户指南
│       └── public_sys-resources              # 文档图标资源
├── openssl
│   ├── crypto
│   │   ├── aes/asm                           # AES-XTS SVE2 源码和测试
│   │   ├── bn/asm                            # RSA SVE2 x8 汇编内核
│   │   └── modes                             # AES-GCM SVE2 源码和测试
│   └── test                                  # RSA benchmark 源码
├── scripts                                   # OpenSSL 源码接入和测试脚本
└── README.md                                 # 项目说明文档
```

## 版本说明

当前版本信息如[**表 3** 版本信息](#版本信息)所示。

**表 3** 版本信息<a id="版本信息"></a>

| 项目 | 说明 |
| --- | --- |
| 产品名称 | kacc_crypto |
| 分支 | `dev` |
| 软件形态 | OpenSSL 密码算法优化源码、接入脚本和测试脚本 |
| 覆盖算法 | AES-XTS、AES-GCM、RSA |
| 目标平台 | Kunpeng 950 AArch64 Linux |
| OpenSSL 版本 | 建议 OpenSSL 3.0 系列或与接入脚本锚点匹配的源码树 |

详细版本能力、注意事项和遗留问题请参见《[版本说明书](./docs/zh/release_notes.md)》。

## 环境部署

### 环境要求

部署前请确保环境满足[**表 4** 环境要求](#环境要求表)。

**表 4** 环境要求<a id="环境要求表"></a>

| 项目 | 要求 |
| --- | --- |
| 服务器和处理器 | Kunpeng 950 |
| 架构 | AArch64 |
| 操作系统 | AArch64 Linux |
| 指令能力 | ARMv8 AES、PMULL、SVE2 |
| 编译器 | 支持 AArch64 SVE2 相关 `-march` 选项的 GCC 或 Clang |
| 构建工具 | `git`、`gcc` 或 `clang`、`make`、`perl` |

### 安装基础软件

以 yum 系发行版为例：

```shell
sudo yum install -y git gcc make perl
```

以 apt 系发行版为例：

```shell
sudo apt-get update
sudo apt-get install -y git gcc make perl
```

### 准备 OpenSSL

```shell
git clone https://github.com/openssl/openssl.git -b openssl-3.0
cd openssl
./Configure linux-aarch64
make -j$(nproc)
```

更详细的环境部署、源码接入和安装后检查步骤请参见《[安装指南](./docs/zh/installation_guide.md)》。

## 快速入门

1. 获取 `kacc_crypto` 源码。

    ```shell
    git clone https://gitcode.com/weiaq/kacc_crypto.git -b dev
    cd kacc_crypto
    export OPENSSL_DIR=/path/to/openssl
    ```

2. 接入 AES-XTS 优化。

    ```shell
    ./scripts/install_sve2_xts_dispatch.sh "${OPENSSL_DIR}"
    cd "${OPENSSL_DIR}"
    make -j$(nproc)
    ```

3. 接入 AES-GCM 优化。

    ```shell
    cd /path/to/kacc_crypto
    ./scripts/install_sve2_gcm_dispatch.sh "${OPENSSL_DIR}"
    cd "${OPENSSL_DIR}"
    make -j$(nproc)
    ```

4. 生成 RSA benchmark 可执行文件。

    ```shell
    cd /path/to/kacc_crypto
    OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
    ```

5. 执行基础验证。

    ```shell
    cd /path/to/kacc_crypto
    OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
    OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_gcm.sh

    cd /path/to/openssl
    taskset -c 10 test/rsa2048_private_rsaz29_x8_bench 1000 all
    taskset -c 10 test/rsa4096_private_rsaz29_x8_bench 200 all
    ```

## 使用说明

### AES-XTS

AES-XTS 优化接入 OpenSSL provider AES-XTS 分发层。重新编译 OpenSSL 后，应用无需调用新的外部接口，仍通过 OpenSSL EVP/provider 使用 AES-XTS。

可使用 OpenSSL speed 验证 EVP 路径：

```shell
cd /path/to/openssl
./apps/openssl speed -elapsed -seconds 10 -evp aes-128-xts aes-192-xts aes-256-xts
```

### AES-GCM

AES-GCM 优化接入 OpenSSL provider AES-GCM 大块 update 路径。默认 8192B 及以上进入 SVE2 路径，小包、尾部和不满足能力条件的场景继续使用 ARMv8/NEON 路径。

可使用 OpenSSL speed 验证 EVP 路径：

```shell
cd /path/to/openssl
./apps/openssl speed -elapsed -seconds 10 -evp aes-128-gcm aes-192-gcm aes-256-gcm
```

### RSA

RSA 当前通过独立 benchmark 验证 8 路多缓冲 private CRT 路径。默认脚本只生成 RSA2048 和 RSA4096 benchmark 可执行文件，不自动执行长时间性能测试。

```shell
cd /path/to/openssl
taskset -c 10 test/rsa2048_private_rsaz29_x8_bench 1000 all
taskset -c 10 test/rsa4096_private_rsaz29_x8_bench 200 all
```

输出中包含 `correctness=PASS` 表示功能校验通过。性能结果重点关注 `blinded_speedup_vs_native_default`；分析纯数学内核时可参考 `math_speedup_vs_native_no_blind`。

## 文档

`kacc_crypto` 文档说明如[**表 5** 文档清单](#文档清单)所示。

**表 5** 文档清单<a id="文档清单"></a>

| 文档名称 | 说明 |
| --- | --- |
| [快速入门](./docs/zh/quick_start.md) | 快速完成源码获取、OpenSSL 构建、优化代码接入和基础验证。 |
| [安装指南](./docs/zh/installation_guide.md) | 描述环境要求、三算法接入步骤、编译步骤和测试步骤。 |
| [用户指南](./docs/zh/user_guide.md) | 描述 AES-XTS、AES-GCM 和 RSA 优化的使用入口、参数和验证方法。 |
| [版本说明书](./docs/zh/release_notes.md) | 描述版本配套、能力范围、注意事项和遗留问题。 |
| [文档许可证](./docs/LICENSE) | 说明文档许可证。 |

## 许可证

文档许可证见 [docs/LICENSE](./docs/LICENSE)。源码许可证如需单独声明，请以后续新增的仓库根目录许可证文件为准。
