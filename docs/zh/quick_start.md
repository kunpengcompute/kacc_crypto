# 快速入门

## KACC_Crypto介绍

KACC_Crypto是基于开源OpenSSL实现的密码算法优化库，当前包含AES-GCM、AES-XTS和RSA三类优化代码。AES-GCM与AES-XTS使用AArch64 SVE2指令提升对称密码大块处理能力，RSA使用8路多缓冲思路优化私钥CRT模幂热点。

本文提供基于源码接入OpenSSL的快速入门流程，帮助用户完成代码获取、OpenSSL构建、优化代码接入和基础验证。

## 前提条件

- 使用AArch64 Linux环境。
- 当前优化面向支持SVE2的鲲鹏950处理器机器验证。
- 已准备OpenSSL 3.0.16源码树。
- 已安装基础编译工具。

    ```bash
    sudo yum install -y git gcc make perl
    ```

- 已完成OpenSSL初始配置和编译，测试脚本需要`libcrypto.a`或`libcrypto.so`，以及生成后的OpenSSL头文件。

    ```bash
    cd /path/to/openssl
    ./Configure linux-aarch64
    make -j$(nproc)
    ```

## 安装步骤

1. 获取KACC_Crypto源码。

    ```bash
    git clone https://gitcode.com/weiaq/kacc_crypto.git -b dev
    cd kacc_crypto
    ```

2. 设置OpenSSL源码路径。

    ```bash
    export OPENSSL_DIR=/path/to/openssl
    ```

3. 接入AES-XTS优化代码。

    ```bash
    ./scripts/install_sve2_xts_dispatch.sh "${OPENSSL_DIR}"
    ```

4. 接入AES-GCM优化代码。

    ```bash
    ./scripts/install_sve2_gcm_dispatch.sh "${OPENSSL_DIR}"
    ```

5. 重新编译OpenSSL。

    ```bash
    cd "${OPENSSL_DIR}"
    make -j$(nproc)
    ```

## 验证AES-XTS

执行AES-XTS一键测试。

```bash
cd /path/to/kacc_crypto
OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
```

测试覆盖AES-128-XTS、AES-192-XTS、AES-256-XTS的加密和解密路径，输出中出现`PASS`表示SVE2结果与OpenSSL开源结果一致。

## 验证AES-GCM

1. 执行AES-GCM正确性测试。

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_gcm.sh
   ```

2. 该脚本会先接入GCM优化代码，再运行功能验证和NEON/SVE2性能矩阵。

   性能数据默认采用OpenSSL speed常用长度规格，常用长度规格如下。

   ```text
   16 64 256 1024 8192 16384
   ```

## 验证RSA

1. RSA当前通过独立benchmark验证8路多缓冲私钥CRT路径。执行RSA2048测试。

   ```bash
   cd /path/to/kacc_crypto
   RSA_BENCH_ITERS=1000 RSA_BENCH_MODE=all \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

2. 执行RSA4096测试。

   ```bash
   cd /path/to/kacc_crypto
   RSA_BENCH_BITS=4096 RSA_BENCH_ITERS=100 \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

3. 如需强制使用OpenSSL动态库，可设置。

   ```bash
   RSA_BENCH_LINK=shared OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

## 学习文档

- 如需了解完整环境要求、接入过程和测试命令，请参见[安装指南](./installation_guide.md)。
- 如需了解安装后的调用方式，请参见[用户指南](./user_guide.md)。
- 如需了解版本能力、约束和已知问题，请参见[版本说明书](./release_notes.md)。

## 修订记录

| 文档版本 | 发布日期 | 修改说明 |
| -- | ---- | ---- |
| 01 | 2026-09-30 | 第一次正式发布。 |
