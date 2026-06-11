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
