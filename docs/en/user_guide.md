# User Guide

<!-- md-trans-meta sourceCommit=cf44427b349a15f3e2de14446543026ddc946f03 translatedAt=2026-09-02T02:31:12.054Z pushedAt=2026-09-03T00:40:34.416Z -->

This document describes how to use KACC_Crypto after installation. Before you begin, complete the OpenSSL build, optimized code integration, and basic verification steps described in [Installation Guide](./installation_guide.md).

## Using AES-XTS Optimization

### Invocation Method

The AES-XTS optimization is integrated into the stream dispatch layer of the OpenSSL AArch64 XTS implementation. Applications do not need to call any new external APIs and can continue to use the algorithm through the OpenSSL EVP/provider AES-XTS interface. When the target machine supports SVE2 AES and the key size is AES-128-XTS, AES-192-XTS, or AES-256-XTS, OpenSSL internally dispatches to the SVE2 stream; otherwise, it continues to use the original HWAES XTS stream.

### Conditions for Entering the Optimized Path

| Condition | Description |
| --- | --- |
| Architecture | AArch64 |
| Instruction capabilities | Armv8 AES and SVE2 |
| Algorithm | AES-128-XTS, AES-192-XTS, AES-256-XTS |
| Input requirements | Uses a 16-byte AES block size. XTS CTS and unaligned boundaries are handled by the OpenSSL upper layer. |
| Fallback path | When the conditions are not met, the OpenSSL open-source HWAES XTS is used. |

### Example

- Use the OpenSSL command line to verify AES-128-XTS encryption throughput.

   ```bash
   cd /path/to/openssl
   ./apps/openssl speed -elapsed -seconds 10 -evp aes-128-xts
   ```

- To directly compare SVE2 with the open-source algorithm implementation, run the XTS test script provided in the repository.

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
   ```

## Using AES-GCM Optimization

### Invocation Method

The AES-GCM optimization is integrated into the large-block update path of the OpenSSL provider AES-GCM implementation. Applications still use AES-GCM through `EVP_EncryptUpdate()`, `EVP_DecryptUpdate()`, or the OpenSSL provider interface. When the input length reaches the threshold and the capability conditions are met, the SVE2 path that combines AES-CTR and GHASH computations is internally used.

### Conditions for Entering the Optimization Path

| Condition | Description |
| --- | --- |
| Architecture | AArch64 |
| Instruction capabilities | Armv8 AES, PMULL, SVE2 |
| Algorithm | AES-128-GCM, AES-192-GCM, AES-256-GCM |
| Length threshold | 8,192 bytes for both encryption and decryption |
| Context requirement | The current GCM context uses Armv8 AES/GHASH assembly. |
| Fallback path | Armv8/NEON GCM is used for small packets, tail data, scenarios that do not meet the capability conditions, and kernels that do not support the required features. |

### Example

1. Run `openssl speed` to verify AES-GCM.

   ```bash
   cd /path/to/openssl
   ./apps/openssl speed -elapsed -seconds 10 -evp aes-128-gcm
   ```

2. Run the GCM matrix test provided in the repository.

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_gcm.sh
   ```

3. Specify the commonly used data sizes for `openssl speed`.

   ```bash
   cd /path/to/openssl/crypto/modes/asm
   GCM_SPEED_SIZES="16 64 256 1024 8192 16384" ./run_all_gcm_tests.sh
   ```

## Using RSA Multi-Buffer Optimization

### Invocation Method

The RSA optimization is currently verified through an independent benchmark, rather than transparent dispatch through the public OpenSSL RSA APIs. The benchmark generates an RSA key and eight independent ciphertexts, runs the OpenSSL open-source path and the SVE2 x8 private-key CRT path, and compares the output correctness and performance.

### Parameter Description

| Parameter | Description | Default Value |
| --- | --- | --- |
| RSA_BENCH_BITS | RSA key size, which is `2048` or `4096`. | `2048` |
| RSA_BENCH_ITERS | Number of benchmark iterations. | `1000` |
| RSA_BENCH_CORE | Binds CPU cores. To enable it, run `taskset`. | Not bound |
| RSA_BENCH_MODE | Options: `all`, `native_default`, `native_no_blind`, `rsaz29_math`, and `rsaz29_blind` | `all` |
| RSA_BENCH_LINK | Options: `auto`, `static`, and `shared`, controlling whether to link OpenSSL statically or dynamically. | `auto` |
| OPENSSL_LIB | Explicitly specifies the path to `libcrypto.a` or `libcrypto.so`. | Not specified |
| CC | Compiler used to compile the benchmark. | `cc` |

### Example

1. Run the RSA2048 test.

   ```shell
   cd /path/to/kacc_crypto
   RSA_BENCH_ITERS=1000 RSA_BENCH_MODE=all \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

2. Run the RSA4096 test.

   ```shell
   cd /path/to/kacc_crypto
   RSA_BENCH_BITS=4096 RSA_BENCH_ITERS=100 \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

3. Force the use of the OpenSSL dynamic library.

   ```shell
   RSA_BENCH_LINK=shared OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
   ```

## Verifying the Optimization

| Algorithm | Recommended Verification Method | Success Criteria |
| --- | --- | --- |
| AES-XTS | `apply_and_test_xts.sh` | The correctness test outputs `PASS`, and the performance output includes a comparison between native and SVE2. |
| AES-GCM | `run_gcm_unit_bench.sh --verify-only` and `run_all_gcm_tests.sh` | The correctness test passes, and the performance matrix outputs NEON/SVE2 results in GB/s. |
| RSA | `apply_and_test_rsa.sh` | The SVE2 results match the native or original message, and the output includes ns/op data. |

## Important Notes

- KACC_Crypto is currently intended for optimized code verification and upstream development. It does not provide a standalone runtime library.
- The integration scripts modify the target OpenSSL source tree. It is recommended to run them in a clean OpenSSL working tree.
- Before performance testing, it is recommended to fix the CPU frequency, bind CPU cores, and confirm that the target machine actually supports SVE2.

## Change History

| Issue | Date | Description |
| ---- | ---- | -- |
| 01 | 2026-09-30 | This is the first official release. |
