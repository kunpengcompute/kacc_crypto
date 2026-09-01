# 用户指南

本文档介绍KACC_Crypto安装完成后的使用方法。开始使用前，请先完成《[安装指南](./installation_guide.md)》中的OpenSSL构建、优化代码接入和基础验证步骤。

## 使用AES-XTS优化

### 调用方式

AES-XTS优化接入OpenSSL AArch64 XTS底层stream分发层。应用不需要调用新的外部API，仍通过OpenSSL EVP或provider AES-XTS接口使用算法；当目标机器支持SVE2 AES，且key size为AES-128-XTS、AES-192-XTS或AES-256-XTS时，OpenSSL内部分发到SVE2 stream，否则继续使用原HWAES XTS stream。

### 进入优化路径的条件

| 条件 | 说明 |
| --- | --- |
| 架构 | AArch64 |
| 指令能力 | ARMv8 AES 与 SVE2 |
| 算法 | AES-128-XTS、AES-192-XTS、AES-256-XTS |
| 输入要求 | 16字节AES block粒度；XTS CTS和非对齐边界由OpenSSL上层处理 |
| 回退路径 | 不满足条件时使用OpenSSL开源HWAES XTS |

### 使用示例

- 使用OpenSSL命令行验证AES-128-XTS加密吞吐。

   ```bash
   cd /path/to/openssl
   ./apps/openssl speed -elapsed -seconds 10 -evp aes-128-xts
   ```

- 如需直接对比SVE2与开源算法实现，可运行仓库提供的XTS测试脚本。

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
   ```

## 使用AES-GCM优化

### 调用方式

AES-GCM优化接入OpenSSL provider AES-GCM大块update路径。应用仍通过`EVP_EncryptUpdate()`、`EVP_DecryptUpdate()`或OpenSSL provider接口使用AES-GCM；当输入长度达到阈值并满足能力条件时，内部进入SVE2 AES-CTR与GHASH融合路径。

### 进入优化路径的条件

| 条件 | 说明 |
| --- | --- |
| 架构 | AArch64 |
| 指令能力 | ARMv8 AES、PMULL、SVE2 |
| 算法 | AES-128-GCM、AES-192-GCM、AES-256-GCM |
| 长度阈值 | 加密和解密均为8192B |
| 上下文要求 | 当前GCM context使用ARMv8 AES/GHASH汇编 |
| 回退路径 | 小包、尾部、不满足能力条件或kernel不支持时使用ARMv8/NEON GCM |

### 使用示例

1. 运行OpenSSL speed验证AES-GCM。

   ```bash
   cd /path/to/openssl
   ./apps/openssl speed -elapsed -seconds 10 -evp aes-128-gcm
   ```

2. 运行仓库提供的GCM矩阵测试。

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_gcm.sh
   ```

3. 指定OpenSSL speed常用长度规格。

   ```bash
   cd /path/to/openssl/crypto/modes/asm
   GCM_SPEED_SIZES="16 64 256 1024 8192 16384" ./run_all_gcm_tests.sh
   ```

## 使用RSA多缓冲优化

### 调用方式

RSA优化当前通过独立benchmark验证，不是OpenSSL对外RSA API的透明分发。benchmark会生成RSA key和8个独立ciphertext，分别运行OpenSSL开源路径和SVE2 x8 private CRT路径，并比较输出正确性和性能。

### 参数说明

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| RSA_BENCH_BITS | RSA key size，支持`2048`和`4096` | `2048` |
| RSA_BENCH_ITERS | benchmark迭代次数 | `1000` |
| RSA_BENCH_CORE | 绑定CPU core；设置后通过`taskset`执行 | 未绑定 |
| RSA_BENCH_MODE | `all`、`native_default`、`native_no_blind`、`rsaz29_math`、`rsaz29_blind` | `all` |
| RSA_BENCH_LINK | `auto`、`static`、`shared`，控制链接OpenSSL静态库或动态库 | `auto` |
| OPENSSL_LIB | 显式指定`libcrypto.a`或`libcrypto.so`路径 | 未指定 |
| CC | 编译benchmark使用的编译器 | `cc` |

### 使用示例

1. 运行RSA2048测试。

   ```shell
   cd /path/to/kacc_crypto
   RSA_BENCH_ITERS=1000 RSA_BENCH_MODE=all \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

2. 运行RSA4096测试。

   ```shell
   cd /path/to/kacc_crypto
   RSA_BENCH_BITS=4096 RSA_BENCH_ITERS=100 \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

3. 强制使用OpenSSL动态库。

   ```shell
   RSA_BENCH_LINK=shared OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

## 验证优化是否生效

| 算法 | 推荐验证方式 | 成功标准 |
| --- | --- | --- |
| AES-XTS | `apply_and_test_xts.sh` | 正确性输出`PASS`，性能输出包含native与SVE2对比。 |
| AES-GCM | `run_gcm_unit_bench.sh --verify-only`和`run_all_gcm_tests.sh` | 正确性通过，性能矩阵输出NEON/SVE2 GB/s。 |
| RSA | `apply_and_test_rsa.sh` | SVE2结果与native或原始message一致，输出ns/op。 |

## 特殊说明

- KACC_Crypto当前面向优化代码验证和上游化开发，不提供独立运行时库。
- 接入脚本会修改目标OpenSSL源码树，建议在干净OpenSSL工作树中执行。
- 性能测试前建议固定CPU频率、绑定CPU core，并确认目标机器实际支持SVE2。

## 修订记录

| 文档版本 | 发布日期 | 修改说明 |
| ---- | ---- | -- |
| 01 | 2026-09-30 | 第一次正式发布。 |
