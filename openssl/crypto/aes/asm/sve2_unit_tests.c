#include <openssl/aes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void (*xts_fn)(const unsigned char *in, unsigned char *out,
                       size_t len, const AES_KEY *key1,
                       const AES_KEY *key2, const unsigned char iv[16]);

extern void aes_v8_xts_encrypt(const unsigned char *in, unsigned char *out,
                               size_t len, const AES_KEY *key1,
                               const AES_KEY *key2,
                               const unsigned char iv[16]);
extern void aes_v8_xts_decrypt(const unsigned char *in, unsigned char *out,
                               size_t len, const AES_KEY *key1,
                               const AES_KEY *key2,
                               const unsigned char iv[16]);

extern int aes_v8_set_encrypt_key(const unsigned char *userKey, const int bits,
                                  AES_KEY *key);
extern int aes_v8_set_decrypt_key(const unsigned char *userKey, const int bits,
                                  AES_KEY *key);

extern void sve2_aes_xts_128_encrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char iv[16]);
extern void sve2_aes_xts_128_decrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char iv[16]);
extern void sve2_aes_xts_192_encrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char iv[16]);
extern void sve2_aes_xts_192_decrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char iv[16]);
extern void sve2_aes_xts_256_encrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char iv[16]);
extern void sve2_aes_xts_256_decrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char iv[16]);

static void fill_input(unsigned char *buf, size_t len)
{
    size_t i;

    for (i = 0; i < len; i++)
        buf[i] = (unsigned char)(0x5a ^ (i * 17u) ^ (i >> 3));
}

static void fill_key(unsigned char *buf, size_t len, unsigned int seed)
{
    size_t i;

    for (i = 0; i < len; i++)
        buf[i] = (unsigned char)(seed + i * 37u + (i >> 1));
}

static int report_mismatch(const char *name, size_t len,
                           const unsigned char *expected,
                           const unsigned char *actual)
{
    size_t i;

    for (i = 0; i < len; i++) {
        if (expected[i] != actual[i]) {
            printf("FAIL %s len=%zu byte=%zu expected=%02x actual=%02x\n",
                   name, len, i, expected[i], actual[i]);
            return 0;
        }
    }

    printf("PASS %s len=%zu\n", name, len);
    return 1;
}

static int test_size(const char *name, int bits, size_t len,
                     xts_fn sve2_encrypt, xts_fn sve2_decrypt,
                     const unsigned char *key1_raw,
                     const unsigned char *key2_raw,
                     const unsigned char iv[16])
{
    unsigned char *pt = malloc(len);
    unsigned char *ct_native = malloc(len);
    unsigned char *ct_sve2 = malloc(len);
    unsigned char *dec_native = malloc(len);
    unsigned char *dec_sve2 = malloc(len);
    AES_KEY enc_data, dec_data, tweak;
    int ok = 1;

    if (pt == NULL || ct_native == NULL || ct_sve2 == NULL ||
        dec_native == NULL || dec_sve2 == NULL) {
        fprintf(stderr, "allocation failed for %s len=%zu\n", name, len);
        free(pt);
        free(ct_native);
        free(ct_sve2);
        free(dec_native);
        free(dec_sve2);
        return 0;
    }

    fill_input(pt, len);
    memset(ct_native, 0, len);
    memset(ct_sve2, 0, len);
    memset(dec_native, 0, len);
    memset(dec_sve2, 0, len);

    if (aes_v8_set_encrypt_key(key1_raw, bits, &enc_data) != 0 ||
        aes_v8_set_decrypt_key(key1_raw, bits, &dec_data) != 0 ||
        aes_v8_set_encrypt_key(key2_raw, bits, &tweak) != 0) {
        fprintf(stderr, "key schedule setup failed for %s len=%zu\n", name,
                len);
        free(pt);
        free(ct_native);
        free(ct_sve2);
        free(dec_native);
        free(dec_sve2);
        return 0;
    }

    aes_v8_xts_encrypt(pt, ct_native, len, &enc_data, &tweak, iv);
    sve2_encrypt(pt, ct_sve2, len, &enc_data, &tweak, iv);
    if (memcmp(ct_native, ct_sve2, len) != 0)
        ok = report_mismatch(name, len, ct_native, ct_sve2) && ok;

    aes_v8_xts_decrypt(ct_sve2, dec_native, len, &dec_data, &tweak, iv);
    sve2_decrypt(ct_sve2, dec_sve2, len, &dec_data, &tweak, iv);
    if (memcmp(dec_native, dec_sve2, len) != 0)
        ok = report_mismatch(name, len, dec_native, dec_sve2) && ok;
    if (memcmp(pt, dec_sve2, len) != 0)
        ok = report_mismatch(name, len, pt, dec_sve2) && ok;

    if (ok)
        printf("PASS %s len=%zu\n", name, len);

    free(pt);
    free(ct_native);
    free(ct_sve2);
    free(dec_native);
    free(dec_sve2);
    return ok;
}

static int test_case(const char *name, int bits, xts_fn sve2_encrypt,
                     xts_fn sve2_decrypt)
{
    static const size_t test_sizes[] = {
        16, 32, 64, 128, 256, 320, 512, 1024, 4096, 8192
    };
    unsigned char key1_raw[32];
    unsigned char key2_raw[32];
    unsigned char iv[16] = {
        0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00, 0xff,
        0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11
    };
    size_t key_len = (size_t)bits / 8;
    size_t i;
    int ok = 1;

    fill_key(key1_raw, key_len, 0x11);
    fill_key(key2_raw, key_len, 0x83);

    printf("\n=========================================================================\n");
    printf("UNIT TEST: SVE2 AES-%d-XTS ENCRYPT/DECRYPT\n", bits);
    printf("=========================================================================\n\n");

    for (i = 0; i < sizeof(test_sizes) / sizeof(test_sizes[0]); i++) {
        if (!test_size(name, bits, test_sizes[i], sve2_encrypt, sve2_decrypt,
                       key1_raw, key2_raw, iv))
            ok = 0;
    }

    return ok;
}

int main(void)
{
    int ok = 1;

    ok = test_case("AES-128-XTS", 128, sve2_aes_xts_128_encrypt,
                   sve2_aes_xts_128_decrypt) && ok;
    ok = test_case("AES-192-XTS", 192, sve2_aes_xts_192_encrypt,
                   sve2_aes_xts_192_decrypt) && ok;
    ok = test_case("AES-256-XTS", 256, sve2_aes_xts_256_encrypt,
                   sve2_aes_xts_256_decrypt) && ok;

    printf("\n-------------------------------------------------------------------------\n");
    printf("FINAL RESULT: %s\n", ok ? "PASS" : "FAIL");
    printf("=========================================================================\n");

    return ok ? 0 : 1;
}
