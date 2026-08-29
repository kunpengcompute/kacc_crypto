/*
 * Focused AES-GCM benchmark for the SVE2 productization path.
 *
 * This file intentionally keeps only the units needed by PR validation:
 * functional checks plus NEON/SVE2 AES-128/192/256 GCM enc/dec throughput.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "internal/deprecated.h"
#include <openssl/aes.h>

#if defined(__aarch64__)
# include "crypto/modes.h"
# include "crypto/aes_platform.h"
# if defined(__ARM_FEATURE_SVE2_AES)
#  include <arm_sve.h>
# endif

# if defined(__GNUC__)
#  define GCM_BENCH_WEAK __attribute__((weak))
# else
#  define GCM_BENCH_WEAK
# endif

extern void aes_v8_ctr32_encrypt_blocks(const unsigned char *in,
                                        unsigned char *out, size_t blocks,
                                        const void *key,
                                        const unsigned char ivec[16]);
extern void aes_v8_ctr32_encrypt_blocks_unroll12_eor3(
    const unsigned char *in, unsigned char *out, size_t blocks,
    const void *key, const unsigned char ivec[16]) GCM_BENCH_WEAK;
extern void gcm_init_v8(u128 Htable[16], const u64 H[2]);
extern void gcm_ghash_v8(u64 Xi[2], const u128 Htable[16],
                         const u8 *inp, size_t len);
extern size_t unroll8_eor3_aes_gcm_enc_128_kernel(
    const unsigned char *in, uint64_t len, unsigned char *out, u64 Xi[2],
    unsigned char ivec[16], const void *key) GCM_BENCH_WEAK;
extern size_t unroll8_eor3_aes_gcm_enc_192_kernel(
    const unsigned char *in, uint64_t len, unsigned char *out, u64 Xi[2],
    unsigned char ivec[16], const void *key) GCM_BENCH_WEAK;
extern size_t unroll8_eor3_aes_gcm_enc_256_kernel(
    const unsigned char *in, uint64_t len, unsigned char *out, u64 Xi[2],
    unsigned char ivec[16], const void *key) GCM_BENCH_WEAK;
extern size_t unroll8_eor3_aes_gcm_dec_128_kernel(
    const unsigned char *in, uint64_t len, unsigned char *out, u64 Xi[2],
    unsigned char ivec[16], const void *key) GCM_BENCH_WEAK;
extern size_t unroll8_eor3_aes_gcm_dec_192_kernel(
    const unsigned char *in, uint64_t len, unsigned char *out, u64 Xi[2],
    unsigned char ivec[16], const void *key) GCM_BENCH_WEAK;
extern size_t unroll8_eor3_aes_gcm_dec_256_kernel(
    const unsigned char *in, uint64_t len, unsigned char *out, u64 Xi[2],
    unsigned char ivec[16], const void *key) GCM_BENCH_WEAK;

# if defined(__ARM_FEATURE_SVE2_AES) && defined(GCM_BENCH_USE_ASM_SVE2)
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_12_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_14_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_12_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_pf_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_pf_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[1024],
    const unsigned char ivec[16]);
# endif

static const unsigned char kKey[32] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f
};
static const unsigned char kIv[16] = {
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x00, 0x00, 0x00, 0x01
};

enum gcm_unit {
    U_NEON_128_ENC,
    U_NEON_192_ENC,
    U_NEON_256_ENC,
    U_NEON_128_DEC,
    U_NEON_192_DEC,
    U_NEON_256_DEC,
    U_SVE2_128_ENC,
    U_SVE2_192_ENC,
    U_SVE2_256_ENC,
    U_SVE2_128_DEC,
    U_SVE2_192_DEC,
    U_SVE2_256_DEC,
    U_ALL
};

struct bench_ctx {
    int bits;
    int enc;
    AES_KEY key;
    u128 htable[16];
    u128 pairtab[1024];
};

static double now_sec(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static uint32_t get_be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
           | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void put_be32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

static void fill_input(unsigned char *buf, size_t len)
{
    size_t i;

    for (i = 0; i < len; i++)
        buf[i] = (unsigned char)((i * 131u + 17u) & 0xffu);
}

static void clmul64(uint64_t out[2], uint64_t a, uint64_t b)
{
    __asm__ volatile(
        ".arch_extension crypto\n"
        "fmov    d0, %x[a]\n"
        "fmov    d1, %x[b]\n"
        "pmull   v0.1q, v0.1d, v1.1d\n"
        "umov    %x[lo], v0.d[0]\n"
        "umov    %x[hi], v0.d[1]\n"
        : [lo] "=r"(out[0]), [hi] "=r"(out[1])
        : [a] "r"(a), [b] "r"(b)
        : "v0", "v1");
}

static void xor128(uint64_t out[2], const uint64_t a[2],
                   const uint64_t b[2])
{
    out[0] = a[0] ^ b[0];
    out[1] = a[1] ^ b[1];
}

static void ext8(uint64_t out[2], const uint64_t a[2], const uint64_t b[2])
{
    out[0] = a[1];
    out[1] = b[0];
}

static void mul_hpow(u128 *out, const u128 *a, const u128 *b)
{
    const uint64_t c2[2] = { 0xc200000000000000ULL, 0 };
    uint64_t ap[2], bp[2], xl[2], xm[2], xh[2];
    uint64_t t0[2], t1[2], t2[2], result[2];
    uint64_t amid, bmid;

    memcpy(ap, a, sizeof(ap));
    memcpy(bp, b, sizeof(bp));
    clmul64(xl, ap[0], bp[0]);
    clmul64(xh, ap[1], bp[1]);
    amid = ap[0] ^ ap[1];
    bmid = bp[0] ^ bp[1];
    clmul64(xm, amid, bmid);

    ext8(t1, xl, xh);
    xor128(t2, xl, xh);
    xor128(xm, xm, t1);
    xor128(xm, xm, t2);
    clmul64(t2, xl[0], c2[0]);

    xh[0] = xm[1];
    xm[1] = xl[0];
    xor128(xl, xm, t2);

    ext8(t2, xl, xl);
    clmul64(t0, xl[0], c2[0]);
    xor128(t2, t2, xh);
    xor128(result, t0, t2);
    memcpy(out, result, sizeof(*out));
}

static void precompute_pairtab(const u128 htable[16], u128 pairtab[1024])
{
    u128 hpow[513];
    size_t i, j;

    memset(hpow, 0, sizeof(hpow));
    hpow[1] = htable[0];
    for (i = 2; i <= 512; i++)
        mul_hpow(&hpow[i], &hpow[i - 1], &hpow[1]);

    memset(pairtab, 0, sizeof(u128) * 1024);
    for (j = 0; j < 256; j++) {
        size_t e0 = 512 - 2 * j;
        size_t e1 = e0 - 1;
        const uint64_t *h0 = (const uint64_t *)&hpow[e0];
        const uint64_t *h1 = (const uint64_t *)&hpow[e1];
        uint64_t *dst = (uint64_t *)&pairtab[j * 4];

        dst[0] = h0[0];
        dst[1] = h0[1];
        dst[2] = h1[0];
        dst[3] = h1[1];
        dst[4] = dst[1] ^ dst[0];
        dst[5] = dst[0] ^ dst[1];
        dst[6] = dst[3] ^ dst[2];
        dst[7] = dst[2] ^ dst[3];
    }
}

static int init_key(int bits, AES_KEY *key, u128 htable[16],
                    u128 pairtab[1024])
{
    unsigned char zero[16] = {0};
    unsigned char hblk[16];

    if (AES_set_encrypt_key(kKey, bits, key) != 0)
        return 0;
    AES_encrypt(zero, hblk, key);
    gcm_init_v8(htable, (const u64 *)hblk);
    precompute_pairtab(htable, pairtab);
    return 1;
}

static size_t call_neon(int bits, int enc, const unsigned char *in,
                        unsigned char *out, size_t len, u64 xi[2],
                        const AES_KEY *key, const unsigned char ivec[16])
{
    unsigned char ctr[16];

    memcpy(ctr, ivec, sizeof(ctr));
    switch (bits) {
    case 128:
        if (enc && unroll8_eor3_aes_gcm_enc_128_kernel == NULL)
            return 0;
        if (!enc && unroll8_eor3_aes_gcm_dec_128_kernel == NULL)
            return 0;
        return enc ? unroll8_eor3_aes_gcm_enc_128_kernel(
                         in, len * 8, out, xi, ctr, key)
                   : unroll8_eor3_aes_gcm_dec_128_kernel(
                         in, len * 8, out, xi, ctr, key);
    case 192:
        if (enc && unroll8_eor3_aes_gcm_enc_192_kernel == NULL)
            return 0;
        if (!enc && unroll8_eor3_aes_gcm_dec_192_kernel == NULL)
            return 0;
        return enc ? unroll8_eor3_aes_gcm_enc_192_kernel(
                         in, len * 8, out, xi, ctr, key)
                   : unroll8_eor3_aes_gcm_dec_192_kernel(
                         in, len * 8, out, xi, ctr, key);
    case 256:
        if (enc && unroll8_eor3_aes_gcm_enc_256_kernel == NULL)
            return 0;
        if (!enc && unroll8_eor3_aes_gcm_dec_256_kernel == NULL)
            return 0;
        return enc ? unroll8_eor3_aes_gcm_enc_256_kernel(
                         in, len * 8, out, xi, ctr, key)
                   : unroll8_eor3_aes_gcm_dec_256_kernel(
                         in, len * 8, out, xi, ctr, key);
    default:
        return 0;
    }
}

static int call_ctr_ghash(int enc, const unsigned char *in,
                          unsigned char *out, size_t len, u64 xi[2],
                          const AES_KEY *key, const u128 htable[16],
                          const unsigned char ivec[16])
{
    if (aes_v8_ctr32_encrypt_blocks_unroll12_eor3 != NULL)
        aes_v8_ctr32_encrypt_blocks_unroll12_eor3(in, out, len / 16, key, ivec);
    else
        aes_v8_ctr32_encrypt_blocks(in, out, len / 16, key, ivec);
    gcm_ghash_v8(xi, htable, enc ? out : in, len);
    return 1;
}

static size_t call_sve2_kernel(int bits, int enc, const unsigned char *in,
                               unsigned char *out, size_t len, u64 xi[2],
                               const AES_KEY *key, const u128 pairtab[1024],
                               const unsigned char ivec[16])
{
# if defined(__ARM_FEATURE_SVE2_AES) && defined(GCM_BENCH_USE_ASM_SVE2)
    switch (bits) {
    case 128:
        if (!enc && len >= 16384 && len < 32768)
            return gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_pf_asm(
                in, out, len, xi, key, pairtab, ivec);
        return enc
            ? gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm(
                  in, out, len, xi, key, pairtab, ivec)
            : gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_asm(
                  in, out, len, xi, key, pairtab, ivec);
    case 192:
        return enc
            ? gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_12_asm(
                  in, out, len, xi, key, pairtab, ivec)
            : gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_12_asm(
                  in, out, len, xi, key, pairtab, ivec);
    case 256:
        if (!enc && len >= 16384 && len < 32768)
            return gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_pf_asm(
                in, out, len, xi, key, pairtab, ivec);
        return enc
            ? gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_14_asm(
                  in, out, len, xi, key, pairtab, ivec)
            : gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_asm(
                  in, out, len, xi, key, pairtab, ivec);
    default:
        return 0;
    }
# else
    (void)bits;
    (void)enc;
    (void)in;
    (void)out;
    (void)len;
    (void)xi;
    (void)key;
    (void)pairtab;
    (void)ivec;
    return 0;
# endif
}

static int call_sve2_product(int bits, int enc, const unsigned char *in,
                             unsigned char *out, size_t len, u64 xi[2],
                             const AES_KEY *key, const u128 htable[16],
                             const u128 pairtab[1024],
                             const unsigned char ivec[16])
{
    size_t done;

    if ((len & 15) != 0)
        return 0;
    if (len < 8192)
        return call_ctr_ghash(enc, in, out, len, xi, key, htable, ivec);

    done = call_sve2_kernel(bits, enc, in, out, len, xi, key, pairtab, ivec);
    if (done == 0)
        return call_ctr_ghash(enc, in, out, len, xi, key, htable, ivec);
    if (done != len) {
        unsigned char tail_ctr[16];

        memcpy(tail_ctr, ivec, sizeof(tail_ctr));
        put_be32(tail_ctr + 12, get_be32(ivec + 12) + (uint32_t)(done / 16));
        return call_ctr_ghash(enc, in + done, out + done, len - done, xi, key,
                              htable, tail_ctr);
    }
    return 1;
}

static int reference_gcm(int enc, const unsigned char *in, unsigned char *out,
                         size_t len, u64 xi[2], const AES_KEY *key,
                         const u128 htable[16], const unsigned char ivec[16])
{
    aes_v8_ctr32_encrypt_blocks(in, out, len / 16, key, ivec);
    gcm_ghash_v8(xi, htable, enc ? out : in, len);
    return 1;
}

static void unit_bits_enc(enum gcm_unit unit, int *bits, int *enc)
{
    *bits = 128;
    *enc = 1;

    switch (unit) {
    case U_NEON_192_ENC:
    case U_NEON_192_DEC:
    case U_SVE2_192_ENC:
    case U_SVE2_192_DEC:
        *bits = 192;
        break;
    case U_NEON_256_ENC:
    case U_NEON_256_DEC:
    case U_SVE2_256_ENC:
    case U_SVE2_256_DEC:
        *bits = 256;
        break;
    default:
        *bits = 128;
        break;
    }

    switch (unit) {
    case U_NEON_128_DEC:
    case U_NEON_192_DEC:
    case U_NEON_256_DEC:
    case U_SVE2_128_DEC:
    case U_SVE2_192_DEC:
    case U_SVE2_256_DEC:
        *enc = 0;
        break;
    default:
        *enc = 1;
        break;
    }
}

static int prepare_ctx(enum gcm_unit unit, struct bench_ctx *ctx)
{
    unit_bits_enc(unit, &ctx->bits, &ctx->enc);
    return init_key(ctx->bits, &ctx->key, ctx->htable, ctx->pairtab);
}

static int run_prepared(enum gcm_unit unit, const struct bench_ctx *ctx,
                        const unsigned char *in, unsigned char *out,
                        size_t len, u64 xi[2])
{
    if ((len & 15) != 0)
        return 0;
    memset(xi, 0, sizeof(u64) * 2);

    switch (unit) {
    case U_NEON_128_ENC:
    case U_NEON_192_ENC:
    case U_NEON_256_ENC:
    case U_NEON_128_DEC:
    case U_NEON_192_DEC:
    case U_NEON_256_DEC:
        if (call_neon(ctx->bits, ctx->enc, in, out, len, xi,
                      &ctx->key, kIv) == len)
            return 1;
        return call_ctr_ghash(ctx->enc, in, out, len, xi, &ctx->key,
                              ctx->htable, kIv);
    case U_SVE2_128_ENC:
    case U_SVE2_192_ENC:
    case U_SVE2_256_ENC:
    case U_SVE2_128_DEC:
    case U_SVE2_192_DEC:
    case U_SVE2_256_DEC:
        return call_sve2_product(ctx->bits, ctx->enc, in, out, len, xi,
                                 &ctx->key, ctx->htable, ctx->pairtab, kIv);
    default:
        return 0;
    }
}

static int verify_one(int bits, int enc, enum gcm_unit unit)
{
    static const size_t lengths[] = {
        16, 64, 256, 1024, 4096, 8192, 8208, 16384, 16400
    };
    unsigned char input[16400];
    unsigned char ref[16400];
    unsigned char got[16400];
    struct bench_ctx ctx;
    size_t i;

    fill_input(input, sizeof(input));
    if (!prepare_ctx(unit, &ctx))
        return 0;

    for (i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
        u64 ref_xi[2] = {0, 0};
        u64 got_xi[2] = {0, 0};

        memset(ref, 0, sizeof(ref));
        memset(got, 0, sizeof(got));
        reference_gcm(enc, input, ref, lengths[i], ref_xi, &ctx.key,
                      ctx.htable, kIv);
        if (!run_prepared(unit, &ctx, input, got, lengths[i], got_xi)
            || memcmp(ref, got, lengths[i]) != 0
            || ref_xi[0] != got_xi[0] || ref_xi[1] != got_xi[1]) {
            size_t j;

            for (j = 0; j < lengths[i]; j++) {
                if (ref[j] != got[j]) {
                    fprintf(stderr,
                            "ciphertext mismatch byte=%zu ref=%02x got=%02x\n",
                            j, ref[j], got[j]);
                    break;
                }
            }
            if (j == lengths[i])
                fprintf(stderr, "ciphertext match; GHASH Xi mismatch\n");
            fprintf(stderr,
                    "verify failed bits=%d enc=%d len=%zu ref_xi=%016llx%016llx got_xi=%016llx%016llx\n",
                    bits, enc, lengths[i],
                    (unsigned long long)ref_xi[0],
                    (unsigned long long)ref_xi[1],
                    (unsigned long long)got_xi[0],
                    (unsigned long long)got_xi[1]);
            return 0;
        }
    }
    return 1;
}

static int verify_all(void)
{
# if defined(__ARM_FEATURE_SVE2_AES)
    if ((size_t)svcntb() != 32) {
        fprintf(stderr, "skip: current SVE VL is not 256-bit\n");
        return 1;
    }
# endif
    return verify_one(128, 1, U_SVE2_128_ENC)
        && verify_one(192, 1, U_SVE2_192_ENC)
        && verify_one(256, 1, U_SVE2_256_ENC)
        && verify_one(128, 0, U_SVE2_128_DEC)
        && verify_one(192, 0, U_SVE2_192_DEC)
        && verify_one(256, 0, U_SVE2_256_DEC);
}

static const char *unit_name(enum gcm_unit unit)
{
    switch (unit) {
    case U_NEON_128_ENC:
        return "neon-128-gcm-enc";
    case U_NEON_192_ENC:
        return "neon-192-gcm-enc";
    case U_NEON_256_ENC:
        return "neon-256-gcm-enc";
    case U_NEON_128_DEC:
        return "neon-128-gcm-dec";
    case U_NEON_192_DEC:
        return "neon-192-gcm-dec";
    case U_NEON_256_DEC:
        return "neon-256-gcm-dec";
    case U_SVE2_128_ENC:
        return "aes-128-gcm-sve2-enc";
    case U_SVE2_192_ENC:
        return "aes-192-gcm-sve2-enc";
    case U_SVE2_256_ENC:
        return "aes-256-gcm-sve2-enc";
    case U_SVE2_128_DEC:
        return "aes-128-gcm-sve2-dec";
    case U_SVE2_192_DEC:
        return "aes-192-gcm-sve2-dec";
    case U_SVE2_256_DEC:
        return "aes-256-gcm-sve2-dec";
    default:
        return "all";
    }
}

static int parse_unit(const char *s, enum gcm_unit *unit)
{
    size_t i;
    static const enum gcm_unit units[] = {
        U_NEON_128_ENC, U_NEON_192_ENC, U_NEON_256_ENC,
        U_NEON_128_DEC, U_NEON_192_DEC, U_NEON_256_DEC,
        U_SVE2_128_ENC, U_SVE2_192_ENC, U_SVE2_256_ENC,
        U_SVE2_128_DEC, U_SVE2_192_DEC, U_SVE2_256_DEC
    };

    if (strcmp(s, "all") == 0) {
        *unit = U_ALL;
        return 1;
    }
    for (i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
        if (strcmp(s, unit_name(units[i])) == 0) {
            *unit = units[i];
            return 1;
        }
    }
    if (strcmp(s, "kernel-eor3-enc") == 0) {
        *unit = U_NEON_128_ENC;
        return 1;
    }
    if (strcmp(s, "ctr-sve2-ghash-hpow512-pairtab2-eor3-ctrtpl-tmpnorm-fused-asm") == 0) {
        *unit = U_SVE2_128_ENC;
        return 1;
    }
    return 0;
}

static unsigned int default_iterations(size_t len)
{
    const uint64_t target = 1ULL << 32;
    uint64_t it = target / len;

    if (it < 8192)
        it = 8192;
    if (it > 1000000)
        it = 1000000;
    return (unsigned int)it;
}

static int bench_unit(enum gcm_unit unit, size_t len, unsigned int iterations)
{
    unsigned char *in = NULL;
    unsigned char *out = NULL;
    struct bench_ctx ctx;
    unsigned int repeats = 5;
    unsigned int r, i;
    double best = 1.0e100;
    double total = 0.0;
    volatile uint64_t sink = 0;

    if (len == 0 || (len & 15) != 0)
        return 0;
    in = malloc(len);
    out = malloc(len);
    if (in == NULL || out == NULL) {
        free(in);
        free(out);
        return 0;
    }
    fill_input(in, len);
    if (!prepare_ctx(unit, &ctx)) {
        free(in);
        free(out);
        return 0;
    }

    for (r = 0; r < repeats; r++) {
        double start = now_sec();

        for (i = 0; i < iterations; i++) {
            u64 xi[2];

            if (!run_prepared(unit, &ctx, in, out, len, xi)) {
                free(in);
                free(out);
                return 0;
            }
            sink ^= xi[0] ^ xi[1] ^ out[(i + r) % len];
        }
        {
            double elapsed = now_sec() - start;

            if (elapsed < best)
                best = elapsed;
            total += elapsed;
        }
    }
    if (sink == 0xdeadbeefULL)
        fprintf(stderr, "ignore: %llu\n", (unsigned long long)sink);

    {
        double bytes = (double)len * (double)iterations;
        double best_gbps = bytes / best / 1000000000.0;
        double avg_gbps = bytes / (total / repeats) / 1000000000.0;
        double ns_per_byte = best * 1000000000.0 / bytes;

        printf("%s %zu %u %.2f %.2f %.4f\n", unit_name(unit), len,
               iterations, best_gbps, avg_gbps, ns_per_byte);
    }
    free(in);
    free(out);
    return 1;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s [--verify-only] [--unit all|neon-128-gcm-enc|neon-192-gcm-enc|neon-256-gcm-enc|neon-128-gcm-dec|neon-192-gcm-dec|neon-256-gcm-dec|aes-128-gcm-sve2-enc|aes-192-gcm-sve2-enc|aes-256-gcm-sve2-enc|aes-128-gcm-sve2-dec|aes-192-gcm-sve2-dec|aes-256-gcm-sve2-dec] [--size bytes] [--iterations n]\n",
            prog);
}

int main(int argc, char **argv)
{
    enum gcm_unit unit = U_SVE2_128_ENC;
    size_t len = 8192;
    unsigned int iterations = 0;
    int verify_only = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--verify-only") == 0) {
            verify_only = 1;
        } else if (strcmp(argv[i], "--unit") == 0 && i + 1 < argc) {
            if (!parse_unit(argv[++i], &unit)) {
                usage(argv[0]);
                return 2;
            }
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            len = (size_t)strtoull(argv[++i], NULL, 0);
        } else if (strcmp(argv[i], "--iterations") == 0 && i + 1 < argc) {
            iterations = (unsigned int)strtoul(argv[++i], NULL, 0);
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (verify_only) {
        if (!verify_all()) {
            fprintf(stderr, "sve2 gcm product candidate verify: FAIL\n");
            return 1;
        }
        printf("sve2 gcm product candidate verify: PASS\n");
        return 0;
    }

    if (iterations == 0)
        iterations = default_iterations(len);

    if (unit == U_ALL) {
        static const enum gcm_unit units[] = {
            U_NEON_128_ENC, U_NEON_192_ENC, U_NEON_256_ENC,
            U_NEON_128_DEC, U_NEON_192_DEC, U_NEON_256_DEC,
            U_SVE2_128_ENC, U_SVE2_192_ENC, U_SVE2_256_ENC,
            U_SVE2_128_DEC, U_SVE2_192_DEC, U_SVE2_256_DEC
        };
        size_t j;

        for (j = 0; j < sizeof(units) / sizeof(units[0]); j++) {
            if (!bench_unit(units[j], len, iterations))
                return 1;
        }
        return 0;
    }

    return bench_unit(unit, len, iterations) ? 0 : 1;
}
#else
int main(void)
{
    fprintf(stderr, "AES-GCM SVE2 benchmark requires AArch64\n");
    return 1;
}
#endif
