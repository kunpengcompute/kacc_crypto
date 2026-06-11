#include <openssl/aes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern void aes_v8_xts_encrypt(const unsigned char *in, unsigned char *out,
                               size_t len, const AES_KEY *key1,
                               const AES_KEY *key2,
                               const unsigned char *iv);
extern void aes_v8_xts_decrypt(const unsigned char *in, unsigned char *out,
                               size_t len, const AES_KEY *key1,
                               const AES_KEY *key2,
                               const unsigned char *iv);

extern int aes_v8_set_encrypt_key(const unsigned char *userKey, const int bits,
                                  AES_KEY *key);
extern int aes_v8_set_decrypt_key(const unsigned char *userKey, const int bits,
                                  AES_KEY *key);
extern void sve2_aes_xts_128_encrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char *iv);
extern void sve2_aes_xts_128_decrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char *iv);
extern void sve2_aes_xts_192_encrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char *iv);
extern void sve2_aes_xts_192_decrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char *iv);
extern void sve2_aes_xts_256_encrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char *iv);
extern void sve2_aes_xts_256_decrypt(const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const AES_KEY *key1,
                                     const AES_KEY *key2,
                                     const unsigned char *iv);

#define ALIGNMENT 64
#define REPEATS 5
#define TARGET_BYTES (4ULL * 1024 * 1024 * 1024)
#define TARGET_SPEEDUP 1.10

typedef void (*xts_fn)(const unsigned char *, unsigned char *, size_t,
                       const AES_KEY *, const AES_KEY *,
                       const unsigned char *);

enum xts_direction {
    XTS_ENCRYPT,
    XTS_DECRYPT
};

struct bench_case {
    const char *name;
    int bits;
    enum xts_direction direction;
    xts_fn native_fn;
    xts_fn sve2_fn;
    const char *native_label;
};

static double now_sec(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static void fill_input(unsigned char *buf, size_t len)
{
    size_t i;

    for (i = 0; i < len; i++)
        buf[i] = (unsigned char)(0x5a ^ (i * 131u) ^ (i >> 5));
}

static void fill_key(unsigned char *buf, size_t len, unsigned int seed)
{
    size_t i;

    for (i = 0; i < len; i++)
        buf[i] = (unsigned char)(seed + i * 37u + (i >> 1));
}

static unsigned char *alloc_aligned(size_t len)
{
    void *ptr = NULL;

    if (posix_memalign(&ptr, ALIGNMENT, len) != 0)
        return NULL;
    return ptr;
}

static unsigned int iterations_for(size_t len)
{
    unsigned long long iters = TARGET_BYTES / len;

    if (iters < 16)
        iters = 16;
    if (iters > 1000000)
        iters = 1000000;
    return (unsigned int)iters;
}

static double run_one(xts_fn fn, const unsigned char *in, unsigned char *out,
                      size_t len, const AES_KEY *ks1, const AES_KEY *ks2,
                      const unsigned char *iv, unsigned int iterations)
{
    unsigned int i;
    double start;

    fn(in, out, len, ks1, ks2, iv);
    __asm__ __volatile__("" ::: "memory");

    start = now_sec();
    for (i = 0; i < iterations; i++) {
        fn(in, out, len, ks1, ks2, iv);
        __asm__ __volatile__("" ::: "memory");
    }

    return now_sec() - start;
}

static int report_mismatch(const struct bench_case *bc, size_t len,
                           const unsigned char *expected,
                           const unsigned char *actual)
{
    size_t i;

    for (i = 0; i < len; i++) {
        if (expected[i] != actual[i]) {
            fprintf(stderr,
                    "correctness mismatch in %s len=%zu byte=%zu "
                    "expected=%02x actual=%02x\n",
                    bc->name, len, i, expected[i], actual[i]);
            return 0;
        }
    }

    return 0;
}

static int benchmark_size(const struct bench_case *bc, size_t len,
                          const AES_KEY *enc_data, const AES_KEY *dec_data,
                          const AES_KEY *tweak, const unsigned char *iv)
{
    unsigned char *plain = alloc_aligned(len);
    unsigned char *cipher = alloc_aligned(len);
    unsigned char *out_native = alloc_aligned(len);
    unsigned char *out_sve2 = alloc_aligned(len);
    const unsigned char *native_input;
    const unsigned char *sve2_input;
    const unsigned char *native_expected;
    const unsigned char *sve2_expected;
    const AES_KEY *native_data_key;
    const AES_KEY *sve2_data_key;
    unsigned int iterations = iterations_for(len);
    double best_native = 1.0e100;
    double best_sve2 = 1.0e100;
    double sum_native = 0.0;
    double sum_sve2 = 0.0;
    int r;

    if (plain == NULL || cipher == NULL || out_native == NULL ||
        out_sve2 == NULL) {
        fprintf(stderr, "allocation failed for %s %zu bytes\n", bc->name,
                len);
        free(plain);
        free(cipher);
        free(out_native);
        free(out_sve2);
        return 0;
    }

    fill_input(plain, len);
    memset(cipher, 0, len);
    memset(out_native, 0, len);
    memset(out_sve2, 0, len);

    aes_v8_xts_encrypt(plain, cipher, len, enc_data, tweak, iv);

    if (bc->direction == XTS_ENCRYPT) {
        native_input = plain;
        sve2_input = plain;
        native_expected = cipher;
        sve2_expected = cipher;
        native_data_key = enc_data;
        sve2_data_key = enc_data;
    } else {
        native_input = cipher;
        sve2_input = cipher;
        native_expected = plain;
        sve2_expected = plain;
        native_data_key = dec_data;
        sve2_data_key = dec_data;
    }

    bc->native_fn(native_input, out_native, len, native_data_key, tweak, iv);
    bc->sve2_fn(sve2_input, out_sve2, len, sve2_data_key, tweak, iv);
    if (memcmp(native_expected, out_native, len) != 0 ||
        memcmp(sve2_expected, out_sve2, len) != 0) {
        if (memcmp(native_expected, out_native, len) != 0)
            report_mismatch(bc, len, native_expected, out_native);
        if (memcmp(sve2_expected, out_sve2, len) != 0)
            report_mismatch(bc, len, sve2_expected, out_sve2);
        free(plain);
        free(cipher);
        free(out_native);
        free(out_sve2);
        return 0;
    }

    for (r = 0; r < REPEATS; r++) {
        double t_native;
        double t_sve2;

        if (((r + (int)len) & 1) == 0) {
            t_sve2 = run_one(bc->sve2_fn, sve2_input, out_sve2, len,
                             sve2_data_key, tweak, iv, iterations);
            t_native = run_one(bc->native_fn, native_input, out_native, len,
                               native_data_key, tweak, iv, iterations);
        } else {
            t_native = run_one(bc->native_fn, native_input, out_native, len,
                               native_data_key, tweak, iv, iterations);
            t_sve2 = run_one(bc->sve2_fn, sve2_input, out_sve2, len,
                             sve2_data_key, tweak, iv, iterations);
        }

        if (t_native < best_native)
            best_native = t_native;
        if (t_sve2 < best_sve2)
            best_sve2 = t_sve2;
        sum_native += t_native;
        sum_sve2 += t_sve2;
    }

    {
        double bytes = (double)len * (double)iterations;
        double gb = bytes / (1024.0 * 1024.0 * 1024.0);
        double native_best = gb / best_native;
        double sve2_best = gb / best_sve2;
        double native_avg = gb / (sum_native / REPEATS);
        double sve2_avg = gb / (sum_sve2 / REPEATS);
        double target_best = native_best * TARGET_SPEEDUP;

        printf("%8zu %10u %12.2f %12.2f %12.2f %12.2f %11.2f %9.2f%% %11.2f%%\n",
               len, iterations, native_best, sve2_best, native_avg, sve2_avg,
               target_best, (sve2_best / native_best - 1.0) * 100.0,
               (sve2_best / target_best - 1.0) * 100.0);
    }

    free(plain);
    free(cipher);
    free(out_native);
    free(out_sve2);
    return 1;
}

static int benchmark_case(const struct bench_case *bc)
{
    static const size_t sizes[] = {
        512, 4096, 8192, 16384
    };
    unsigned char key_data[32];
    unsigned char key_tweak[32];
    unsigned char iv[16] = {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
    };
    AES_KEY enc_data;
    AES_KEY dec_data;
    AES_KEY tweak;
    size_t key_len = (size_t)bc->bits / 8;
    size_t i;
    int ok = 1;

    fill_key(key_data, key_len, 0x21);
    fill_key(key_tweak, key_len, 0x9d);

    if (aes_v8_set_encrypt_key(key_data, bc->bits, &enc_data) != 0 ||
        aes_v8_set_decrypt_key(key_data, bc->bits, &dec_data) != 0 ||
        aes_v8_set_encrypt_key(key_tweak, bc->bits, &tweak) != 0) {
        fprintf(stderr, "key schedule setup failed for %s\n", bc->name);
        return 0;
    }

    printf("\nBenchmark: %s\n", bc->name);
    printf("Native reference: %s\n", bc->native_label);
    printf("Repeats: %d | Target bytes per repeat: %llu\n", REPEATS,
           (unsigned long long)TARGET_BYTES);
    printf("Goal: SVE2 >= native * %.2f\n", TARGET_SPEEDUP);
    printf("    size iterations native_best    sve2_best   native_avg     sve2_avg target_best   speedup target_gap\n");
    printf("--------------------------------------------------------------------------------------------------------\n");

    for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        if (!benchmark_size(bc, sizes[i], &enc_data, &dec_data, &tweak, iv))
            ok = 0;
    }

    return ok;
}

int main(void)
{
    static const struct bench_case cases[] = {
        { "AES-128-XTS ENCRYPT", 128, XTS_ENCRYPT, aes_v8_xts_encrypt,
          sve2_aes_xts_128_encrypt, "aes_v8_xts_encrypt" },
        { "AES-128-XTS DECRYPT", 128, XTS_DECRYPT, aes_v8_xts_decrypt,
          sve2_aes_xts_128_decrypt, "aes_v8_xts_decrypt" },
        { "AES-192-XTS ENCRYPT", 192, XTS_ENCRYPT, aes_v8_xts_encrypt,
          sve2_aes_xts_192_encrypt, "aes_v8_xts_encrypt" },
        { "AES-192-XTS DECRYPT", 192, XTS_DECRYPT, aes_v8_xts_decrypt,
          sve2_aes_xts_192_decrypt, "aes_v8_xts_decrypt" },
        { "AES-256-XTS ENCRYPT", 256, XTS_ENCRYPT, aes_v8_xts_encrypt,
          sve2_aes_xts_256_encrypt, "aes_v8_xts_encrypt" },
        { "AES-256-XTS DECRYPT", 256, XTS_DECRYPT, aes_v8_xts_decrypt,
          sve2_aes_xts_256_decrypt, "aes_v8_xts_decrypt" }
    };
    size_t i;
    int ok = 1;

    for (i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        if (!benchmark_case(&cases[i]))
            ok = 0;
    }

    return ok ? 0 : 1;
}
