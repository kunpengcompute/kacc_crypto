# kacc_crypto

Crypto acceleration source work for BoostKit.

The `dev` branch keeps the SVE2 AES-XTS and AES-GCM source files plus helper
scripts for iterative development.

Use `scripts/apply_and_test_xts.sh` to install the AES-XTS overlay into an
OpenSSL tree and run the validation/performance tests.

Use `scripts/apply_and_test_gcm.sh` to install the AES-GCM overlay into an
OpenSSL tree and run the focused validation/performance tests.  The AES-GCM
dispatch keeps the original ARMv8/NEON path unless the target reports AES,
PMULL, and SVE2 support; the SVE2 path is only used for large GCM windows.

Use `scripts/apply_and_test_rsa.sh` to install the retained SVE2 RSA2048
radix29 x8 overlay into a built OpenSSL tree and run the end-to-end private CRT
validation/performance benchmark.  The RSA overlay keeps only the final
multi-buffer kernels and benchmark harness; intermediate optimization probes
are not part of this repository.
