# Installation Guide

<!-- md-trans-meta sourceCommit=cf44427b349a15f3e2de14446543026ddc946f03 translatedAt=2026-09-01T09:06:04.123Z pushedAt=2026-09-03T00:40:42.578Z -->

## Environment Setup

### Environment Requirements

Before installation, check that the environment meets the current support scope of KACC_Crypto.

**Table 1** Hardware requirements

| Item | Description |
| --- | --- |
| Processor | Kunpeng 950 |
| Architecture | AArch64 |
| SVE vector length | AES-XTS hot path optimized for 256-bit vectors |
| Accelerator device | No external accelerator cards required |

**Table 2** Software requirements

| Item | Description |
| --- | --- |
| OS | AArch64 Linux |
| OpenSSL | OpenSSL 3.0.16 |
| Compiler | GCC or Clang that supports AArch64 SVE2-related `-march` options |
| Build tool | Git, GCC, make, perl |

> ![icon note](public_sys-resources/icon-note.gif) **Note:**
>
>- The AES-GCM and AES-XTS optimizations depend on AArch64 SVE2 capabilities. When the capability condition is not met, fall back to the original OpenSSL path.
>- The RSA benchmark uses SVE2 assembly and links the OpenSSL `libcrypto` library, supporting both `libcrypto.a` and `libcrypto.so`.
>- Combinations not on the list of verified environments require separate compatibility and performance verification.

### Installing Dependencies

- yum-based distributions

  ```bash
  sudo yum install -y git gcc make perl
  ```

- apt-based distributions

  ```bash
  sudo apt-get update
  sudo apt-get install -y git gcc make perl
  ```

## Installation Methods

KACC_Crypto currently provides a source code integration method: The repository stores the source code for the optimizations, integration scripts, and test scripts. To use the optimizations, integrate the optimized code into the target OpenSSL source tree, and then recompile OpenSSL or compile the benchmark independently.

**Table 3** Installation methods

| Installation Method | Description | Application Scenario |
| --- | --- | --- |
| Source code integration | Modify the target OpenSSL source tree through the `scripts/install_*` script and copy the optimized source code. | Functional verification, performance verification, and subsequent upstream development |
| One-click verification | Complete integration and testing through the `scripts/apply_and_test_*` script. | Quick regression of a single algorithm |

## Preparing the OpenSSL Source Tree

1. Obtain the OpenSSL source code.

    ```bash
    git clone https://github.com/openssl/openssl.git -b openssl-3.0.16
    cd openssl
    ```

2. Configure and compile OpenSSL.

    ```bash
    ./Configure linux-aarch64
    make -j$(nproc)
    ```

3. Confirm that the build artifacts exist.

    ```bash
    test -f include/openssl/configuration.h
    test -f libcrypto.a || test -f libcrypto.so || test -f .openssl/lib/libcrypto.so
    ```

## Obtaining KACC_Crypto Code

```bash
git clone https://gitcode.com/weiaq/kacc_crypto.git -b dev
cd kacc_crypto
export OPENSSL_DIR=/path/to/openssl
```

## Installing and Testing AES-XTS

### Function

The AES-XTS optimization adds an SVE2 implementation to the underlying stream layer of OpenSSL AArch64 XTS, and selects the SVE2 stream based on the platform capabilities and key size. It supports encryption and decryption for AES-128-XTS, AES-192-XTS, and AES-256-XTS.

### Integrating Optimized Code

Use the `install_sve2_xts_dispatch.sh` script to integrate the optimized code.

```bash
OPENSSL_DIR=/path/to/openssl ./scripts/install_sve2_xts_dispatch.sh
```

The `install_sve2_xts_dispatch.sh` script performs the following actions:

| Step | Description |
| --- | --- |
| Copy the source code | Install `aesv8-armx-sve2.pl`, `aesv8-armx-sve2.h`, `sve2_unit_tests.c`, and `sve2_performance_test.c`. |
| Modify the build | Add `aesv8-armx-sve2.S` to `crypto/aes/build.info` for compilation. |
| Modify the capability declaration | Declare the SVE2 XTS internal interfaces and capability macros in `include/crypto/aes_platform.h`. |
| Modify the distribution | Set the SVE2 or open-source stream by key size in `cipher_aes_xts_hw.c`. |

### Compiling OpenSSL

Run the following command:

```bash
cd /path/to/openssl
make -j$(nproc)
```

### Testing Functionality and Performance

1. Run the following command:

   ```bash
   cd /path/to/kacc_crypto
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
   ```

2. To enable additional performance analysis items, set the environment variables.

   ```bash
   RUN_KPERF=1 RUN_TWEAK_BENCH=1 \
   OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_xts.sh
   ```

## Installing and Testing AES-GCM

### Function

The AES-GCM optimization adds an SVE2 path that combines AES-CTR and GHASH computations for large data blocks in OpenSSL GCM. The SVE2 path is used when the input length reaches 8,192 bytes, the platform supports AES/PMULL/SVE2, and the current context uses the Armv8 GCM assembly; the Armv8/NEON path continues to be used for small packets, tail data, and scenarios that do not meet the capability conditions.

### Integrating Optimized Code

Use the `install_sve2_gcm_dispatch.sh` script to integrate the optimized code.

```bash
OPENSSL_DIR=/path/to/openssl ./scripts/install_sve2_gcm_dispatch.sh
```

The `install_sve2_gcm_dispatch.sh` script performs the following actions.

| Step | Description |
| --- | --- |
| Copy the source code | Install `gcm-sve2-armv8.c`, `ghash-sve2-armv8_64.pl`, `gcm_unit_bench.c`, and the GCM test script. |
| Modify the build | Add the SVE2 GCM C and assembly files to `crypto/modes/build.info` for compilation. |
| Modify the capability declaration | Add the GCM capability macro, threshold macro, and internal interface declaration to `include/crypto/aes_platform.h`. |
| Modify the context | Add a `pairtab` cache to `cipher_aes_gcm.h/c` and handle its copying and release. |
| Modify the distribution | Add SVE2 dispatch for input lengths of 8,192 bytes or more in `cipher_aes_gcm_hw.c`. |

### Compiling OpenSSL

```bash
cd /path/to/openssl
make -j$(nproc)
```

### Testing Functionality

```bash
cd /path/to/openssl/crypto/modes/asm
./run_gcm_unit_bench.sh --verify-only
```

### Testing Performance

1. Run the complete performance matrix.

   ```bash
   cd /path/to/openssl/crypto/modes/asm
   ./run_all_gcm_tests.sh
   ```

2. Specify the data sizes to test.

   ```bash
   GCM_SPEED_SIZES="16 64 256 1024 8192 16384" ./run_all_gcm_tests.sh
   ```

3. Run a specific test.

   ```bash
   ./run_gcm_unit_bench.sh --unit aes-128-gcm-sve2-enc --size 16384
   ./run_gcm_unit_bench.sh --unit aes-256-gcm-sve2-dec --size 16384
   ```

## Installing and Testing RSA

### Function

The RSA optimization uses SVE2 instructions and an 8-way multi-buffer approach to optimize the Montgomery modular exponentiation hot path in private-key CRT operations. Currently, an independent benchmark is used to verify the performance of RSA2048 and RSA4096 mathematical private-key operations. CRT recombination still uses OpenSSL BN.

### Integrating Optimized Code

Use the `install_rsa_rsaz29_x8.sh` script to integrate the optimized code.

```bash
OPENSSL_DIR=/path/to/openssl ./scripts/install_rsa_rsaz29_x8.sh
```

The `install_rsa_rsaz29_x8.sh` script performs the following actions.

| Step | Description |
| --- | --- |
| Copy assembly | Install `rsaz29-sve2-x8.S` to the target OpenSSL `crypto/bn/asm`. |
| Copy tests | Install `rsa2048_private_rsaz29_x8_bench.c` and `rsa4096_private_rsaz29_x8_bench.c` to the target OpenSSL `test`. |

### Compiling and Running

- Compile and run the RSA2048 benchmark.

  ```bash
  cd /path/to/kacc_crypto
  RSA_BENCH_ITERS=1000 RSA_BENCH_MODE=all \
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
  ```

- Compile and run the RSA4096 benchmark.

  ```bash
  cd /path/to/kacc_crypto
  RSA_BENCH_BITS=4096 RSA_BENCH_ITERS=100 RSA_BENCH_MODE=all \
  OPENSSL_DIR=/path/to/openssl ./scripts/apply_and_test_rsa.sh
  ```

### Common Parameters

| Parameter | Description | Default Value |
| --- | --- | --- |
| RSA_BENCH_BITS | RSA key size, which is `2048` or `4096`. | `2048` |
| RSA_BENCH_ITERS | Number of benchmark iterations. | `1000` |
| RSA_BENCH_CORE | Binds CPU core using `taskset`. | Not bound |
| RSA_BENCH_MODE | Options: `all`, `native_default`, `native_no_blind`, `rsaz29_math`, and `rsaz29_blind`. | `all` |
| RSA_BENCH_LINK | Options: `auto`, `static`, and `shared`, controlling whether to link OpenSSL statically or dynamically. | `auto` |
| OPENSSL_LIB | Explicitly specifies the path to `libcrypto.a` or `libcrypto.so`. | Not specified |
| CC | Compiler used to compile the benchmark. | `cc` |

## Verifying the Installation

After completing any algorithm test, it is recommended to confirm the following results.

| Check Item | Success Criteria |
| --- | --- |
| OpenSSL compilation | `make` completes successfully with no new compilation errors. |
| AES-XTS correctness | The output includes `PASS` for AES-128/192/256 XTS encryption and decryption. |
| AES-GCM correctness | `run_gcm_unit_bench.sh --verify-only` completes successfully. |
| RSA correctness | The benchmark output passes comparison with the native or original message. |
| Performance testing | The output includes performance data in GB/s or ns/op, which can be compared with the open-source implementation. |

## Uninstalling KACC_Crypto Integration

KACC_Crypto currently does not provide an automatic uninstallation script. To restore the target OpenSSL source tree, it is recommended to rebuild from a clean OpenSSL source code, or use a version control tool in the target OpenSSL repository to revert the files and anchor modifications written by `scripts/install_*`.

## Change History

| Issue | Date | Description |
| ---- | ---- | -- |
| 01 | 2026-09-30 | This is the first official release. |
