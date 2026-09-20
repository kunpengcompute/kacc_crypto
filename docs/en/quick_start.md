# Quick Start

<!-- md-trans-meta sourceCommit=cf44427b349a15f3e2de14446543026ddc946f03 translatedAt=2026-09-02T00:54:08.061Z pushedAt=2026-09-03T00:40:38.556Z -->

## Introduction to KACC_Crypto

KACC_Crypto is a cryptographic algorithm optimization library implemented based on OpenSSL. It currently includes three types of optimized code for AES-GCM, AES-XTS, and RSA. AES-GCM and AES-XTS use AArch64 SVE2 instructions to improve the large-block processing capability of symmetric cryptography, while RSA uses an 8-way multi-buffer approach to optimize the Montgomery modular exponentiation hot path in private-key CRT operations.

This document provides a quick start process for integrating OpenSSL using source code, helping complete code acquisition, OpenSSL build, optimized code integration, and basic verification.

## Prerequisites

- An AArch64 Linux environment has been set up.
- The current optimizations have been verified on servers that are equipped with the Kunpeng 950 processor and support SVE2.
- The OpenSSL 3.0.16 source tree is ready.
- Basic compilation tools have been installed.

    ```bash
    sudo yum install -y git gcc make perl
    ```

- The initial OpenSSL configuration and compilation are complete. The test script (`libcrypto.a` or `libcrypto.so`) and the generated OpenSSL header files are ready.

    ```bash
    cd /path/to/openssl
    ./Configure linux-aarch64
    make -j$(nproc)
    ```

## Installation Procedure

1. Obtain the KACC_Crypto source code.

    ```bash
    git clone https://gitcode.com/weiaq/kacc_crypto.git -b dev
    cd kacc_crypto
    ```

2. Set the OpenSSL source code path.

    ```bash
    export OPENSSL_DIR=/path/to/openssl
    ```

3. Integrate the AES-XTS optimized code.

    ```bash
    ./scripts/install_sve2_xts_dispatch.sh "${OPENSSL_DIR}"
    ```

4. Integrate the AES-GCM optimized code.

    ```bash
    ./scripts/install_sve2_gcm_dispatch.sh "${OPENSSL_DIR}"
    ```

5. Recompile OpenSSL.

    ```bash
    cd "${OPENSSL_DIR}"
    make -j$(nproc)
    ```

## Verifying AES-XTS

Run the one-click AES-XTS test.

```bash
cd /path/to/kacc_crypto
OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
```

The test covers the encryption and decryption paths of AES-128-XTS, AES-192-XTS, and AES-256-XTS. An output including `PASS` indicates that the SVE2 result matches that of the OpenSSL open-source implementation.

## Verifying AES-GCM

1. Run the AES-GCM correctness test.

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_gcm.sh
   ```

2. This script first integrates the GCM optimized code, then runs functional verification and the NEON/SVE2 performance matrix.

   By default, the performance data is collected for the common data sizes in the OpenSSL speed benchmark, as shown below.

   ```text
   16 64 256 1024 8192 16384
   ```

## Verifying RSA

1. RSA currently verifies the 8-way multi-buffer private-key CRT path through an independent benchmark. Run the RSA2048 test.

   ```bash
   cd /path/to/kacc_crypto
   RSA_BENCH_ITERS=1000 RSA_BENCH_MODE=all \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

2. Run the RSA4096 test.

   ```bash
   cd /path/to/kacc_crypto
   RSA_BENCH_BITS=4096 RSA_BENCH_ITERS=100 \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

3. To force the use of the OpenSSL dynamic library, configure it as follows.

   ```bash
   RSA_BENCH_LINK=shared OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

## Related Documents

- For details about the complete environment requirements, integration process, and test commands, see [Installation Guide](./installation_guide.md).
- For details about invocation after installation, see [User Guide](./user_guide.md).
- For details about version capabilities, constraints, and known issues, see [Release Notes](./release_notes.md).

## Change History

| Issue | Date | Description |
| -- | ---- | ---- |
| 01 | 2026-09-30 | This is the first official release. |
