/*
 * Copyright 2025 The OpenSSL Project Authors. All Rights Reserved.
 *
 * Licensed under the Apache License 2.0 (the "License").  You may not use
 * this file except in compliance with the License.  You can obtain a copy
 * in the file LICENSE in the source distribution or at
 * https://www.openssl.org/source/license.html
 */

#ifndef OSSL_CRYPTO_AES_ASM_AESV8_ARMX_SVE2_H
#define OSSL_CRYPTO_AES_ASM_AESV8_ARMX_SVE2_H

#include <stddef.h>
#include <openssl/aes.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * SVE2-optimized AES-XTS functions for ARMv9
 *
 * These functions use ARMv9 SVE2 instructions to accelerate AES-XTS
 * encryption and decryption. They are vector length agnostic and can
 * process multiple AES blocks in parallel.
 */

/**
 * AES-128-XTS encryption using SVE2
 *
 * @param in    Input data pointer
 * @param out   Output data pointer
 * @param len   Length of data (must be multiple of 16)
 * @param key1  Data encryption key (128-bit AES key)
 * @param key2  Tweak key (128-bit AES key)
 * @param iv    Initialization vector (16 bytes)
 */
void aes_v8_sve2_xts_128_encrypt(const unsigned char *in,
                                   unsigned char *out,
                                   size_t len,
                                   const AES_KEY *key1,
                                   const AES_KEY *key2,
                                   const unsigned char iv[16]);

/**
 * AES-128-XTS decryption using SVE2
 *
 * @param in    Input data pointer
 * @param out   Output data pointer
 * @param len   Length of data (must be multiple of 16)
 * @param key1  Data decryption key schedule (128-bit AES key)
 * @param key2  Tweak key (128-bit AES key)
 * @param iv    Initialization vector (16 bytes)
 */
void aes_v8_sve2_xts_128_decrypt(const unsigned char *in,
                                   unsigned char *out,
                                   size_t len,
                                   const AES_KEY *key1,
                                   const AES_KEY *key2,
                                   const unsigned char iv[16]);

/**
 * AES-192-XTS encryption using SVE2
 *
 * @param in    Input data pointer
 * @param out   Output data pointer
 * @param len   Length of data (must be multiple of 16)
 * @param key1  Data encryption key (192-bit AES key)
 * @param key2  Tweak key (192-bit AES key)
 * @param iv    Initialization vector (16 bytes)
 */
void aes_v8_sve2_xts_192_encrypt(const unsigned char *in,
                                   unsigned char *out,
                                   size_t len,
                                   const AES_KEY *key1,
                                   const AES_KEY *key2,
                                   const unsigned char iv[16]);

/**
 * AES-192-XTS decryption using SVE2
 *
 * @param in    Input data pointer
 * @param out   Output data pointer
 * @param len   Length of data (must be multiple of 16)
 * @param key1  Data decryption key schedule (192-bit AES key)
 * @param key2  Tweak key (192-bit AES key)
 * @param iv    Initialization vector (16 bytes)
 */
void aes_v8_sve2_xts_192_decrypt(const unsigned char *in,
                                   unsigned char *out,
                                   size_t len,
                                   const AES_KEY *key1,
                                   const AES_KEY *key2,
                                   const unsigned char iv[16]);

/**
 * AES-256-XTS encryption using SVE2
 *
 * @param in    Input data pointer
 * @param out   Output data pointer
 * @param len   Length of data (must be multiple of 16)
 * @param key1  Data encryption key (256-bit AES key)
 * @param key2  Tweak key (256-bit AES key)
 * @param iv    Initialization vector (16 bytes)
 */
void aes_v8_sve2_xts_256_encrypt(const unsigned char *in,
                                   unsigned char *out,
                                   size_t len,
                                   const AES_KEY *key1,
                                   const AES_KEY *key2,
                                   const unsigned char iv[16]);

/**
 * AES-256-XTS decryption using SVE2
 *
 * @param in    Input data pointer
 * @param out   Output data pointer
 * @param len   Length of data (must be multiple of 16)
 * @param key1  Data decryption key schedule (256-bit AES key)
 * @param key2  Tweak key (256-bit AES key)
 * @param iv    Initialization vector (16 bytes)
 */
void aes_v8_sve2_xts_256_decrypt(const unsigned char *in,
                                   unsigned char *out,
                                   size_t len,
                                   const AES_KEY *key1,
                                   const AES_KEY *key2,
                                   const unsigned char iv[16]);

#ifdef __cplusplus
}
#endif

#endif /* OSSL_CRYPTO_AES_ASM_AESV8_ARMX_SVE2_H */
