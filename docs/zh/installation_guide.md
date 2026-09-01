# 安装指南

## 环境部署

### 环境要求

安装前请确保环境满足KACC_Crypto当前支持范围。

**表 1** 硬件要求

| 项目 | 说明 |
| --- | --- |
| 服务器和处理器 | 鲲鹏950处理器 |
| 架构 | AArch64 |
| SVE向量长度 | AES-XTS热路径按256bit向量长度优化 |
| 加速设备 | 无外部加速卡要求 |

**表 2** 软件要求

| 项目 | 说明 |
| --- | --- |
| 操作系统 | AArch64 Linux |
| OpenSSL | OpenSSL 3.0.16 |
| 编译器 | 支持AArch64 SVE2相关`-march`选项的GCC或Clang |
| 构建工具 | Git、GCC、make、perl |

> ![icon note](public_sys-resources/icon-note.gif) **说明：**
>
>- AES-GCM和AES-XTS优化依赖AArch64 SVE2能力，不满足能力条件时应回到OpenSSL原本路径。
>- RSA benchmark使用SVE2汇编并链接OpenSSL的`libcrypto`库，支持`libcrypto.a`和`libcrypto.so`。
>- 未列入已验证环境的组合需要单独完成兼容性和性能验证。

### 安装依赖

- yum系发行版

  ```bash
  sudo yum install -y git gcc make perl
  ```

- apt系发行版

  ```bash
  sudo apt-get update
  sudo apt-get install -y git gcc make perl
  ```

## 安装方式说明

KACC_Crypto当前提供源码接入方式：仓库保存优化相关源码、接入脚本和测试脚本；使用时将优化代码接入到目标OpenSSL源码树，再重新编译OpenSSL或独立编译benchmark。

**表 3** 安装方式说明

| 安装方式 | 安装说明 | 适用场景 |
| --- | --- | --- |
| 源码接入 | 通过`scripts/install_*`脚本修改目标OpenSSL源码树并复制优化源码。 | 功能验证、性能验证、后续上游化开发。 |
| 一键验证 | 通过`scripts/apply_and_test_*`脚本完成接入和测试。 | 快速回归单个算法。 |

## 准备OpenSSL源码树

1. 获取OpenSSL源码。

    ```bash
    git clone https://github.com/openssl/openssl.git -b openssl-3.0.16
    cd openssl
    ```

2. 配置并编译OpenSSL。

    ```bash
    ./Configure linux-aarch64
    make -j$(nproc)
    ```

3. 确认生成物存在。

    ```bash
    test -f include/openssl/configuration.h
    test -f libcrypto.a || test -f libcrypto.so || test -f .openssl/lib/libcrypto.so
    ```

## 获取KACC_Crypto代码

```bash
git clone https://gitcode.com/weiaq/kacc_crypto.git -b dev
cd kacc_crypto
export OPENSSL_DIR=/path/to/openssl
```

## 安装与测试AES-XTS

### 功能说明

AES-XTS优化在OpenSSL AArch64 XTS底层stream层新增SVE2实现，并根据平台能力和key size选择SVE2 stream。支持AES-128-XTS、AES-192-XTS、AES-256-XTS的加密和解密。

### 接入优化代码

使用`install_sve2_xts_dispatch.sh`脚本接入优化代码。

```bash
OPENSSL_DIR=/path/to/openssl ./scripts/install_sve2_xts_dispatch.sh
```

`install_sve2_xts_dispatch.sh`脚本会执行以下动作。

| 步骤 | 修改内容 |
| --- | --- |
| 拷贝源码 | 安装`aesv8-armx-sve2.pl`、`aesv8-armx-sve2.h`、`sve2_unit_tests.c`、`sve2_performance_test.c`。 |
| 修改构建 | 在`crypto/aes/build.info`中加入`aesv8-armx-sve2.S`生成和编译目标。 |
| 修改能力声明 | 在`include/crypto/aes_platform.h`中声明SVE2 XTS内部接口和能力宏。 |
| 修改分发 | 在`cipher_aes_xts_hw.c`中按key size设置SVE2或开源stream。 |

### 编译OpenSSL

执行以下命令。

```bash
cd /path/to/openssl
make -j$(nproc)
```

### 测试功能和性能

1. 执行以下命令。

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
   ```

2. 如需打开额外性能分析项，可设置环境变量。

   ```bash
   RUN_KPERF=1 RUN_TWEAK_BENCH=1 \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
   ```

## 安装与测试AES-GCM

### 功能说明

AES-GCM优化在OpenSSL GCM大块路径中增加SVE2 AES-CTR与GHASH融合计算路径。输入长度达到8192B、平台支持AES/PMULL/SVE2且当前上下文使用ARMv8 GCM汇编时进入SVE2；小包、尾部和不满足能力条件的场景继续使用ARMv8/NEON路径。

### 接入优化代码

使用`install_sve2_gcm_dispatch.sh`脚本接入优化代码。

```bash
OPENSSL_DIR=/path/to/openssl ./scripts/install_sve2_gcm_dispatch.sh
```

`install_sve2_gcm_dispatch.sh`脚本会执行以下动作。

| 步骤 | 修改内容 |
| --- | --- |
| 拷贝源码 | 安装`gcm-sve2-armv8.c`、`ghash-sve2-armv8_64.pl`、`gcm_unit_bench.c`和GCM测试脚本。 |
| 修改构建 | 在`crypto/modes/build.info`中加入SVE2 GCM C文件和汇编生成目标。 |
| 修改能力声明 | 在`include/crypto/aes_platform.h`中增加GCM能力宏、阈值宏和内部接口声明。 |
| 修改上下文 | 在`cipher_aes_gcm.h/c`中增加`pairtab`缓存并处理复制和释放。 |
| 修改分发 | 在`cipher_aes_gcm_hw.c`中插入8192B大窗口SVE2分发。 |

### 编译OpenSSL

```bash
cd /path/to/openssl
make -j$(nproc)
```

### 功能测试

```bash
cd /path/to/openssl/crypto/modes/asm
./run_gcm_unit_bench.sh --verify-only
```

### 性能测试

1. 执行完整性能矩阵。

   ```bash
   cd /path/to/openssl/crypto/modes/asm
   ./run_all_gcm_tests.sh
   ```

2. 指定长度规格。

   ```bash
   GCM_SPEED_SIZES="16 64 256 1024 8192 16384" ./run_all_gcm_tests.sh
   ```

3. 指定单项。

   ```bash
   ./run_gcm_unit_bench.sh --unit aes-128-gcm-sve2-enc --size 16384
   ./run_gcm_unit_bench.sh --unit aes-256-gcm-sve2-dec --size 16384
   ```

## 安装与测试RSA

### 功能说明

RSA优化使用SVE2指令和8路多缓冲方式优化private CRT中的Montgomery模幂热点。当前通过独立benchmark验证RSA2048和RSA4096的数学私钥运算性能，CRT recombine仍使用OpenSSL BN。

### 接入优化代码

使用`install_rsa_rsaz29_x8.sh`脚本接入优化代码。

```bash
OPENSSL_DIR=/path/to/openssl ./scripts/install_rsa_rsaz29_x8.sh
```

`install_rsa_rsaz29_x8.sh`脚本会执行以下动作。

| 步骤 | 修改内容 |
| --- | --- |
| 拷贝汇编 | 安装`rsaz29-sve2-x8.S`到目标OpenSSL `crypto/bn/asm`。 |
| 拷贝测试 | 安装`rsa2048_private_rsaz29_x8_bench.c`和`rsa4096_private_rsaz29_x8_bench.c`到目标OpenSSL `test`。 |

### 编译并运行

- 编译并运行RSA2048 benchmark

  ```bash
  cd /path/to/kacc_crypto
  RSA_BENCH_ITERS=1000 RSA_BENCH_MODE=all \
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
  ```

- 编译并运行RSA4096 benchmark

  ```bash
  cd /path/to/kacc_crypto
  RSA_BENCH_BITS=4096 RSA_BENCH_ITERS=100 RSA_BENCH_MODE=all \
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
  ```

### 常用参数

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| RSA_BENCH_BITS | RSA key size，支持`2048`和`4096` | `2048` |
| RSA_BENCH_ITERS | benchmark迭代次数 | `1000` |
| RSA_BENCH_CORE | 使用`taskset`绑定CPU core | 未绑定 |
| RSA_BENCH_MODE | `all`、`native_default`、`native_no_blind`、`rsaz29_math`、`rsaz29_blind` | `all` |
| RSA_BENCH_LINK | `auto`、`static`、`shared`，控制链接OpenSSL静态库或动态库 | `auto` |
| OPENSSL_LIB | 显式指定`libcrypto.a`或`libcrypto.so`路径 | 未指定 |
| CC | benchmark编译器 | `cc` |

## 安装后检查

完成任一算法测试后，建议确认以下结果。

| 检查项 | 成功标准 |
| --- | --- |
| OpenSSL编译 | `make`成功结束，无新增编译错误。 |
| AES-XTS正确性 | 输出包含AES-128/192/256 XTS加解密`PASS`。 |
| AES-GCM正确性 | `run_gcm_unit_bench.sh --verify-only`成功结束。 |
| RSA正确性 | benchmark输出与native或原始message对比通过。 |
| 性能测试 | 输出GB/s或ns/op数据，可与开源路径对比。 |

## 卸载KACC_Crypto接入内容

KACC_Crypto当前不提供自动卸载脚本。如需恢复目标OpenSSL源码树，建议使用干净OpenSSL源码重新构建，或在目标OpenSSL仓库中通过版本控制工具回退由`scripts/install_*`写入的文件和锚点修改。

## 修订记录

| 文档版本 | 发布日期 | 修改说明 |
| ---- | ---- | -- |
| 01 | 2026-09-30 | 第一次正式发布。 |
