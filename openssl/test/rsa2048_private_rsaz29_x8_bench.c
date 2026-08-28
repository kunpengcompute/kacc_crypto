/*
 * RSA private CRT x8 benchmark using the radix28 SVE2 kernels.
 *
 * Scope:
 *   - one RSA key, eight independent ciphertexts
 *   - RSA_NO_PADDING mathematical private operation
 *   - p and q CRT branches are executed through radix28 x8 fixed-window
 *     Montgomery exponentiation
 *   - CRT recombine is still native BN
 *
 * This benchmark is kept as the product validation/performance harness for the
 * retained radix28 x8 path.  It deliberately does not install experimental
 * intermediate probes such as radix32, radix52, ADCLB/T, or native64 x4
 * reduction scaffolds.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <arm_sve.h>

#include <openssl/bn.h>
#include <openssl/err.h>
#include <openssl/rsa.h>

#include "crypto/bn.h"

#define LANES 8
#ifndef RSA_BITS
# define RSA_BITS 2048
#endif
#define CRT_BITS (RSA_BITS / 2)
#define RSA_BYTES (RSA_BITS / 8)
#define CRT_BYTES (CRT_BITS / 8)
#define RADIX_BITS 28
#define LIMBS64 (CRT_BITS / 64)
#define LIMBS64_RED (LIMBS64 + 1)
#define LIMBS29 ((CRT_BITS + RADIX_BITS - 1) / RADIX_BITS)
#define TABLE_ENTRIES 32
#define WINDOW_BITS 5
#define WINDOWS ((CRT_BITS + WINDOW_BITS - 1) / WINDOW_BITS)
#define MASK29 UINT64_C(0x0fffffff)
#define DEFAULT_ITERS 100
#define WARMUP_ITERS 5

#if CRT_BITS == 1024
# define AMM_SVE2_X8_FUNC amm29_fused_lazy_sve2_x8_handasm
# define AMM_SVE2_X8_SQR_FUNC amm29_fused_sqr_lazy_sve2_x8_handasm
# define CT_GATHER_SVE_FUNC ct_gather_red29_soa_sve_handasm
extern void amm29_fused_lazy_sve2_x8_handasm(uint32_t *out,
                                             const uint32_t *a,
                                             const uint32_t *b,
                                             const uint32_t *m,
                                             const uint64_t *n0_b,
                                             const uint64_t *n0_t)
    __attribute__((weak));

extern void amm29_fused_sqr_lazy_sve2_x8_handasm(uint32_t *out,
                                                 const uint32_t *a,
                                                 const uint32_t *m,
                                                 const uint64_t *n0_b,
                                                 const uint64_t *n0_t)
    __attribute__((weak));

extern void ct_gather_red29_soa_sve_handasm(uint32_t *out,
                                            const uint32_t *table,
                                            uint32_t idx)
    __attribute__((weak));
#elif CRT_BITS == 2048
# define AMM_SVE2_X8_FUNC amm28_2048_fused_lazy_sve2_x8_handasm
# define AMM_SVE2_X8_SQR_FUNC amm28_2048_fused_sqr_lazy_sve2_x8_handasm
# define CT_GATHER_SVE_FUNC ct_gather_red28_2048_soa_sve_handasm
extern void amm28_2048_fused_lazy_sve2_x8_handasm(uint32_t *out,
                                                  const uint32_t *a,
                                                  const uint32_t *b,
                                                  const uint32_t *m,
                                                  const uint64_t *n0_b,
                                                  const uint64_t *n0_t)
    __attribute__((weak));

extern void amm28_2048_fused_sqr_lazy_sve2_x8_handasm(uint32_t *out,
                                                      const uint32_t *a,
                                                      const uint32_t *m,
                                                      const uint64_t *n0_b,
                                                      const uint64_t *n0_t)
    __attribute__((weak));

extern void ct_gather_red28_2048_soa_sve_handasm(uint32_t *out,
                                                 const uint32_t *table,
                                                 uint32_t idx)
    __attribute__((weak));
#else
# error "Unsupported RSA_BITS: only RSA2048 and RSA4096 are wired to SVE2 x8 kernels"
#endif

typedef struct branch_st {
    BN_MONT_CTX *mont;
    BIGNUM *r29_mod;
    BN_BLINDING *blind[LANES];
    const BIGNUM *mod;
    const BIGNUM *exp;
    uint32_t mod29[LIMBS29 * LANES] __attribute__((aligned(64)));
    uint32_t one29[LIMBS29 * LANES] __attribute__((aligned(64)));
    uint32_t normal_one29[LIMBS29 * LANES] __attribute__((aligned(64)));
    uint64_t n0_b[LANES / 2] __attribute__((aligned(64)));
    uint64_t n0_t[LANES / 2] __attribute__((aligned(64)));
    uint32_t windows[WINDOWS];
} BRANCH;

typedef struct bench_st {
    BN_CTX *ctx;
    RSA *rsa;
    BRANCH pbr;
    BRANCH qbr;
    BIGNUM *msg[LANES];
    BIGNUM *ct[LANES];
    BIGNUM *native[LANES];
    BIGNUM *native_nb[LANES];
    BIGNUM *opt[LANES];
    BIGNUM *opt_blind[LANES];
    BIGNUM *cp[LANES];
    BIGNUM *cq[LANES];
    BIGNUM *cp_mont[LANES];
    BIGNUM *cq_mont[LANES];
    BIGNUM *mp_mont[LANES];
    BIGNUM *mq_mont[LANES];
    BIGNUM *mp[LANES];
    BIGNUM *mq[LANES];
    BIGNUM *h[LANES];
    BIGNUM *tmp[LANES];
    unsigned char msg_bytes[LANES][RSA_BYTES];
    unsigned char ct_bytes[LANES][RSA_BYTES];
    unsigned char out_bytes[LANES][RSA_BYTES];
    uint32_t base29[LIMBS29 * LANES] __attribute__((aligned(64)));
    uint32_t result29[LIMBS29 * LANES] __attribute__((aligned(64)));
    uint32_t table29[TABLE_ENTRIES * LIMBS29 * LANES]
        __attribute__((aligned(64)));
    uint32_t gathered29[LIMBS29 * LANES] __attribute__((aligned(64)));
    unsigned int sink;
} BENCH;

static int run_native_default(BENCH *b);
static int run_native_no_blinding(BENCH *b);
static int run_rsaz29_x8(BENCH *b);
static int run_rsaz29_x8_blinded(BENCH *b);

static uint64_t now_ns(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int parse_iters(int argc, char **argv)
{
    long iters;
    char *end = NULL;

    if (argc < 2)
        return DEFAULT_ITERS;

    iters = strtol(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0' || iters <= 0) {
        fprintf(stderr, "usage: %s [iterations]\n", argv[0]);
        return -1;
    }

    return iters > 1000000 ? 1000000 : (int)iters;
}

static int mode_to_runner(const char *mode, int (**fn)(BENCH *),
                          const char **label)
{
    if (mode == NULL || strcmp(mode, "all") == 0)
        return 0;
    if (strcmp(mode, "native_default") == 0) {
        *fn = run_native_default;
        *label = "native_default_seq8_rsa_private_ns";
        return 1;
    }
    if (strcmp(mode, "native_no_blind") == 0) {
        *fn = run_native_no_blinding;
        *label = "native_no_blind_seq8_rsa_private_ns";
        return 1;
    }
    if (strcmp(mode, "rsaz28_math") == 0
        || strcmp(mode, "rsaz29_math") == 0) {
        *fn = run_rsaz29_x8;
        *label = "rsaz29_x8_rsa_private_math_ns";
        return 1;
    }
    if (strcmp(mode, "rsaz28_blind") == 0
        || strcmp(mode, "rsaz29_blind") == 0) {
        *fn = run_rsaz29_x8_blinded;
        *label = "rsaz29_x8_rsa_private_blinded_ns";
        return 1;
    }
    fprintf(stderr,
            "usage: rsa2048_private_rsaz29_x8_bench [iterations] "
            "[all|native_default|native_no_blind|rsaz29_math|rsaz29_blind]\n");
    return -1;
}

static uint32_t ct_eq_mask_u32(uint32_t a, uint32_t b)
{
    uint32_t x = a ^ b;

    x |= 0u - x;
    return 0u - (x >> 31 ^ 1u);
}

static uint64_t load64_le(const unsigned char *p)
{
    uint64_t v = 0;
    int i;

    for (i = 7; i >= 0; i--)
        v = (v << 8) | p[i];
    return v;
}

static void store64_le(unsigned char *p, uint64_t v)
{
    int i;

    for (i = 0; i < 8; i++) {
        p[i] = (unsigned char)v;
        v >>= 8;
    }
}

static uint32_t neg_inv_mod_r29(uint32_t x)
{
    uint32_t inv = 1;
    int i;

    for (i = 0; i < 5; i++)
        inv *= 2 - x * inv;
    return (0u - inv) & (uint32_t)MASK29;
}

static uint32_t norm64_get_digit29(const uint64_t in[LIMBS64], int digit)
{
    int bit = digit * RADIX_BITS;
    int word = bit >> 6;
    int shift = bit & 63;
    uint64_t v = 0;

    if (word < LIMBS64)
        v = in[word] >> shift;
    if (shift != 0 && word + 1 < LIMBS64)
        v |= in[word + 1] << (64 - shift);

    return (uint32_t)(v & MASK29);
}

static int bn_to_norm64(uint64_t out[LIMBS64], const BIGNUM *bn)
{
    unsigned char bytes[CRT_BYTES];
    int i;

    if (BN_bn2lebinpad(bn, bytes, sizeof(bytes)) != sizeof(bytes))
        return 0;

    for (i = 0; i < LIMBS64; i++)
        out[i] = load64_le(bytes + i * 8);
    return 1;
}

static int bn_lanes_to_red29_soa(uint32_t out[LIMBS29 * LANES],
                                 BIGNUM *const in[LANES])
{
    uint64_t norm[LIMBS64];
    int lane, digit;

    for (lane = 0; lane < LANES; lane++) {
        if (!bn_to_norm64(norm, in[lane]))
            return 0;
        for (digit = 0; digit < LIMBS29; digit++)
            out[(size_t)digit * LANES + lane] =
                norm64_get_digit29(norm, digit);
    }
    return 1;
}

static int bn_repeated_to_red29_soa(uint32_t out[LIMBS29 * LANES],
                                    const BIGNUM *bn)
{
    uint64_t norm[LIMBS64];
    int lane, digit;

    if (!bn_to_norm64(norm, bn))
        return 0;

    for (digit = 0; digit < LIMBS29; digit++) {
        uint32_t v = norm64_get_digit29(norm, digit);

        for (lane = 0; lane < LANES; lane++)
            out[(size_t)digit * LANES + lane] = v;
    }
    return 1;
}

static int red29_soa_to_bn_lanes(BIGNUM *out[LANES],
                                 const uint32_t in[LIMBS29 * LANES])
{
    uint64_t norm[LANES][LIMBS64_RED];
    unsigned char bytes[LIMBS64_RED * 8];
    int lane, digit, i;

    memset(norm, 0, sizeof(norm));
    for (digit = 0; digit < LIMBS29; digit++) {
        int bit = digit * RADIX_BITS;
        int word = bit >> 6;
        int shift = bit & 63;

        for (lane = 0; lane < LANES; lane++) {
            uint64_t v = in[(size_t)digit * LANES + lane] & MASK29;

            if (word < LIMBS64_RED)
                norm[lane][word] |= v << shift;
            if (shift > 64 - RADIX_BITS && word + 1 < LIMBS64_RED)
                norm[lane][word + 1] |= v >> (64 - shift);
        }
    }

    for (lane = 0; lane < LANES; lane++) {
        for (i = 0; i < LIMBS64_RED; i++)
            store64_le(bytes + i * 8, norm[lane][i]);
        if (BN_lebin2bn(bytes, sizeof(bytes), out[lane]) == NULL)
            return 0;
    }
    return 1;
}

static unsigned int get_window_value(const BIGNUM *e, int bit, int width)
{
    unsigned int v = 0;
    int i;

    for (i = 0; i < width; i++) {
        if (BN_is_bit_set(e, bit + i))
            v |= 1u << i;
    }
    return v;
}

static void make_windows(uint32_t windows[WINDOWS], const BIGNUM *e)
{
    int bits = CRT_BITS;
    int window0 = (bits - 1) % WINDOW_BITS + 1;
    int w = 0;

    bits -= window0;
    windows[w++] = get_window_value(e, bits, window0);
    while (bits > 0 && w < WINDOWS) {
        bits -= WINDOW_BITS;
        windows[w++] = get_window_value(e, bits, WINDOW_BITS);
    }
    while (w < WINDOWS)
        windows[w++] = 0;
}

static void fill_n0_from_mod29(BRANCH *br)
{
    uint32_t n0 = neg_inv_mod_r29(br->mod29[0]);
    int lane;

    for (lane = 0; lane < LANES; lane++) {
        if (lane & 1)
            br->n0_t[lane >> 1] = n0;
        else
            br->n0_b[lane >> 1] = n0;
    }
}

static void fill_normal_one29(BRANCH *br)
{
    int lane;

    memset(br->normal_one29, 0, sizeof(br->normal_one29));
    for (lane = 0; lane < LANES; lane++)
        br->normal_one29[lane] = 1;
}

static void ct_gather_red29_soa_sve(uint32_t out[LIMBS29 * LANES],
                                    const uint32_t table[TABLE_ENTRIES
                                                         * LIMBS29 * LANES],
                                    uint32_t idx)
{
    size_t total = (size_t)LIMBS29 * LANES;
    size_t pos;
    int entry;

    if (CT_GATHER_SVE_FUNC != NULL) {
        CT_GATHER_SVE_FUNC(out, table, idx);
        return;
    }

    {
        uint32_t mask = ct_eq_mask_u32(0, idx);
        const uint32_t *src = table;

        for (pos = 0; pos < total; pos++)
            out[pos] = src[pos] & mask;
    }

    for (entry = 1; entry < TABLE_ENTRIES; entry++) {
        uint32_t mask = ct_eq_mask_u32((uint32_t)entry, idx);
        const uint32_t *src = table + (size_t)entry * LIMBS29 * LANES;

        for (pos = 0; pos < total; pos++)
            out[pos] |= src[pos] & mask;
    }
}

static void precompute_sve(BENCH *b, const BRANCH *br)
{
    int entry;

    memcpy(b->table29, br->one29, LIMBS29 * LANES * sizeof(b->table29[0]));
    memcpy(b->table29 + LIMBS29 * LANES, b->base29,
           LIMBS29 * LANES * sizeof(b->table29[0]));

    for (entry = 2; entry < TABLE_ENTRIES; entry++) {
        AMM_SVE2_X8_FUNC(
            b->table29 + (size_t)entry * LIMBS29 * LANES,
            b->table29 + (size_t)(entry - 1) * LIMBS29 * LANES, b->base29,
            br->mod29, br->n0_b, br->n0_t);
    }
}

static void modexp_sve(BENCH *b, const BRANCH *br)
{
    int w, s;

    precompute_sve(b, br);
    ct_gather_red29_soa_sve(b->result29, b->table29, br->windows[0]);
    for (w = 1; w < WINDOWS; w++) {
        for (s = 0; s < WINDOW_BITS; s++)
            AMM_SVE2_X8_SQR_FUNC(b->result29, b->result29, br->mod29,
                                 br->n0_b, br->n0_t);
        ct_gather_red29_soa_sve(b->gathered29, b->table29, br->windows[w]);
        AMM_SVE2_X8_FUNC(b->result29, b->result29, b->gathered29, br->mod29,
                         br->n0_b, br->n0_t);
    }
}

static int setup_branch(BENCH *b, BRANCH *br, const BIGNUM *mod,
                        const BIGNUM *exp, const BIGNUM *pub_e)
{
    BIGNUM *mod_ct = NULL;
    int lane;
    int ret = 0;

    br->mod = mod;
    br->exp = exp;
    br->mont = BN_MONT_CTX_new();
    br->r29_mod = BN_new();
    mod_ct = BN_dup(mod);
    if (br->mont == NULL || br->r29_mod == NULL || mod_ct == NULL)
        goto err;

    BN_set_flags(mod_ct, BN_FLG_CONSTTIME);
    if (!BN_MONT_CTX_set(br->mont, mod, b->ctx)
        || !BN_one(br->r29_mod)
        || !BN_lshift(br->r29_mod, br->r29_mod, LIMBS29 * RADIX_BITS)
        || !BN_nnmod(br->r29_mod, br->r29_mod, mod, b->ctx)
        || !bn_repeated_to_red29_soa(br->mod29, mod)
        || !bn_repeated_to_red29_soa(br->one29, br->r29_mod))
        goto err;

    fill_n0_from_mod29(br);
    fill_normal_one29(br);
    make_windows(br->windows, exp);

    for (lane = 0; lane < LANES; lane++) {
        br->blind[lane] =
            BN_BLINDING_create_param(NULL, pub_e, mod_ct, b->ctx,
                                     BN_mod_exp_mont, br->mont);
        if (br->blind[lane] == NULL)
            goto err;
    }
    ret = 1;

err:
    BN_free(mod_ct);
    return ret;
}

static int alloc_bench(BENCH *b)
{
    int lane;

    b->ctx = BN_CTX_new();
    if (b->ctx == NULL)
        return 0;

    for (lane = 0; lane < LANES; lane++) {
        b->msg[lane] = BN_new();
        b->ct[lane] = BN_new();
        b->native[lane] = BN_new();
        b->native_nb[lane] = BN_new();
        b->opt[lane] = BN_new();
        b->opt_blind[lane] = BN_new();
        b->cp[lane] = BN_new();
        b->cq[lane] = BN_new();
        b->cp_mont[lane] = BN_new();
        b->cq_mont[lane] = BN_new();
        b->mp_mont[lane] = BN_new();
        b->mq_mont[lane] = BN_new();
        b->mp[lane] = BN_new();
        b->mq[lane] = BN_new();
        b->h[lane] = BN_new();
        b->tmp[lane] = BN_new();
        if (b->msg[lane] == NULL || b->ct[lane] == NULL
            || b->native[lane] == NULL || b->native_nb[lane] == NULL
            || b->opt[lane] == NULL
            || b->opt_blind[lane] == NULL || b->cp[lane] == NULL
            || b->cq[lane] == NULL || b->cp_mont[lane] == NULL
            || b->cq_mont[lane] == NULL || b->mp_mont[lane] == NULL
            || b->mq_mont[lane] == NULL || b->mp[lane] == NULL
            || b->mq[lane] == NULL || b->h[lane] == NULL
            || b->tmp[lane] == NULL)
            return 0;
    }
    return 1;
}

static void free_bench(BENCH *b)
{
    int lane;

    for (lane = 0; lane < LANES; lane++) {
        BN_BLINDING_free(b->qbr.blind[lane]);
        BN_BLINDING_free(b->pbr.blind[lane]);
        BN_free(b->tmp[lane]);
        BN_free(b->h[lane]);
        BN_free(b->mq[lane]);
        BN_free(b->mp[lane]);
        BN_free(b->mq_mont[lane]);
        BN_free(b->mp_mont[lane]);
        BN_free(b->cq_mont[lane]);
        BN_free(b->cp_mont[lane]);
        BN_free(b->cq[lane]);
        BN_free(b->cp[lane]);
        BN_free(b->opt_blind[lane]);
        BN_free(b->opt[lane]);
        BN_free(b->native_nb[lane]);
        BN_free(b->native[lane]);
        BN_free(b->ct[lane]);
        BN_free(b->msg[lane]);
    }
    BN_free(b->qbr.r29_mod);
    BN_free(b->pbr.r29_mod);
    BN_MONT_CTX_free(b->qbr.mont);
    BN_MONT_CTX_free(b->pbr.mont);
    RSA_free(b->rsa);
    BN_CTX_free(b->ctx);
}

static int prepare_messages(BENCH *b)
{
    const BIGNUM *n = NULL;
    const BIGNUM *e = NULL;
    int lane;
    int ret = 0;

    RSA_get0_key(b->rsa, &n, &e, NULL);
    if (n == NULL || e == NULL)
        return 0;

    for (lane = 0; lane < LANES; lane++) {
        if (!BN_rand_range(b->msg[lane], n) || BN_is_zero(b->msg[lane])
            || BN_bn2binpad(b->msg[lane], b->msg_bytes[lane], RSA_BYTES)
                   != RSA_BYTES)
            goto err;
        if (RSA_public_encrypt(RSA_BYTES, b->msg_bytes[lane],
                               b->ct_bytes[lane], b->rsa, RSA_NO_PADDING)
            != RSA_BYTES)
            goto err;
        if (BN_bin2bn(b->ct_bytes[lane], RSA_BYTES, b->ct[lane]) == NULL)
            goto err;
    }
    ret = 1;

err:
    return ret;
}

static int prepare_bench(BENCH *b)
{
    BIGNUM *e = NULL;
    const BIGNUM *pub_e = NULL;
    const BIGNUM *p = NULL, *q = NULL;
    const BIGNUM *dmp1 = NULL, *dmq1 = NULL, *iqmp = NULL;
    int ret = 0;

    if (AMM_SVE2_X8_FUNC == NULL || AMM_SVE2_X8_SQR_FUNC == NULL)
        return 0;

    if (!alloc_bench(b))
        return 0;

    b->rsa = RSA_new();
    e = BN_new();
    if (b->rsa == NULL || e == NULL || !BN_set_word(e, RSA_F4)
        || !RSA_generate_key_ex(b->rsa, RSA_BITS, e, NULL))
        goto err;

    RSA_get0_key(b->rsa, NULL, &pub_e, NULL);
    RSA_get0_factors(b->rsa, &p, &q);
    RSA_get0_crt_params(b->rsa, &dmp1, &dmq1, &iqmp);
    if (pub_e == NULL || p == NULL || q == NULL || dmp1 == NULL || dmq1 == NULL
        || iqmp == NULL)
        goto err;

    if (!setup_branch(b, &b->pbr, p, dmp1, pub_e)
        || !setup_branch(b, &b->qbr, q, dmq1, pub_e)
        || !prepare_messages(b))
        goto err;

    ret = 1;

err:
    BN_free(e);
    return ret;
}

static int run_native_default(BENCH *b)
{
    int lane;

    RSA_clear_flags(b->rsa, RSA_FLAG_NO_BLINDING);
    for (lane = 0; lane < LANES; lane++) {
        if (RSA_private_decrypt(RSA_BYTES, b->ct_bytes[lane],
                                b->out_bytes[lane], b->rsa, RSA_NO_PADDING)
            != RSA_BYTES)
            return 0;
        if (BN_bin2bn(b->out_bytes[lane], RSA_BYTES, b->native[lane]) == NULL)
            return 0;
        b->sink ^= b->out_bytes[lane][RSA_BYTES - 1] << (lane & 7);
    }
    return 1;
}

static int run_native_no_blinding(BENCH *b)
{
    int lane;

    RSA_set_flags(b->rsa, RSA_FLAG_NO_BLINDING);
    for (lane = 0; lane < LANES; lane++) {
        if (RSA_private_decrypt(RSA_BYTES, b->ct_bytes[lane],
                                b->out_bytes[lane], b->rsa, RSA_NO_PADDING)
            != RSA_BYTES)
            return 0;
        if (BN_bin2bn(b->out_bytes[lane], RSA_BYTES, b->native_nb[lane])
            == NULL)
            return 0;
        b->sink ^= b->out_bytes[lane][RSA_BYTES - 1] << ((lane & 7) + 8);
    }
    return 1;
}

static int prepare_branch_inputs(BENCH *b, const BRANCH *br,
                                 BIGNUM *const input[LANES],
                                 BIGNUM *reduced[LANES],
                                 BIGNUM *monted[LANES], int do_blind)
{
    int lane;

    for (lane = 0; lane < LANES; lane++) {
        if (!BN_nnmod(reduced[lane], input[lane], br->mod, b->ctx)
            || (do_blind
                && !BN_BLINDING_convert(reduced[lane], br->blind[lane],
                                        b->ctx))
            || !BN_mod_mul(monted[lane], reduced[lane], br->r29_mod, br->mod,
                           b->ctx))
            return 0;
    }
    return bn_lanes_to_red29_soa(b->base29, monted);
}

static int finish_branch_outputs(BENCH *b, const BRANCH *br,
                                 BIGNUM *monted[LANES],
                                 BIGNUM *plain[LANES])
{
    int lane;

    AMM_SVE2_X8_FUNC(b->base29, b->result29, br->normal_one29, br->mod29,
                     br->n0_b, br->n0_t);

    if (!red29_soa_to_bn_lanes(monted, b->base29))
        return 0;

    for (lane = 0; lane < LANES; lane++) {
        if (!BN_nnmod(plain[lane], monted[lane], br->mod, b->ctx))
            return 0;
    }
    return 1;
}

static int unblind_branch_outputs(BENCH *b, const BRANCH *br,
                                  BIGNUM *plain[LANES])
{
    int lane;

    for (lane = 0; lane < LANES; lane++) {
        if (!BN_BLINDING_invert(plain[lane], br->blind[lane], b->ctx))
            return 0;
    }
    return 1;
}

static int recombine(BENCH *b, BIGNUM *out[LANES])
{
    const BIGNUM *p = b->pbr.mod;
    const BIGNUM *q = b->qbr.mod;
    const BIGNUM *n = NULL, *e = NULL, *d = NULL;
    const BIGNUM *dmp1 = NULL, *dmq1 = NULL, *iqmp = NULL;
    int lane;

    RSA_get0_key(b->rsa, &n, &e, &d);
    RSA_get0_crt_params(b->rsa, &dmp1, &dmq1, &iqmp);
    if (n == NULL || iqmp == NULL)
        return 0;

    for (lane = 0; lane < LANES; lane++) {
        if (!BN_mod_sub(b->h[lane], b->mp[lane], b->mq[lane], p, b->ctx)
            || !BN_mod_mul(b->h[lane], b->h[lane], iqmp, p, b->ctx)
            || !BN_mul(b->tmp[lane], b->h[lane], q, b->ctx)
            || !BN_mod_add(out[lane], b->tmp[lane], b->mq[lane], n, b->ctx))
            return 0;
        b->sink ^= (unsigned int)BN_num_bits(out[lane])
                << ((lane & 7) + 16);
    }
    return 1;
}

static int run_rsaz29_x8_core(BENCH *b, BIGNUM *const input[LANES],
                              BIGNUM *out[LANES], int branch_blind)
{
    if (!prepare_branch_inputs(b, &b->qbr, input, b->cq, b->cq_mont,
                               branch_blind))
        return 0;
    modexp_sve(b, &b->qbr);
    if (!finish_branch_outputs(b, &b->qbr, b->mq_mont, b->mq))
        return 0;
    if (branch_blind && !unblind_branch_outputs(b, &b->qbr, b->mq))
        return 0;

    if (!prepare_branch_inputs(b, &b->pbr, input, b->cp, b->cp_mont,
                               branch_blind))
        return 0;
    modexp_sve(b, &b->pbr);
    if (!finish_branch_outputs(b, &b->pbr, b->mp_mont, b->mp))
        return 0;
    if (branch_blind && !unblind_branch_outputs(b, &b->pbr, b->mp))
        return 0;

    return recombine(b, out);
}

static int run_rsaz29_x8(BENCH *b)
{
    return run_rsaz29_x8_core(b, b->ct, b->opt, 0);
}

static int run_rsaz29_x8_blinded(BENCH *b)
{
    return run_rsaz29_x8_core(b, b->ct, b->opt_blind, 1);
}

static int verify_results(BENCH *b)
{
    int lane;
    const BIGNUM *dmp1 = NULL, *dmq1 = NULL, *iqmp = NULL;

    if (!run_native_default(b) || !run_native_no_blinding(b)
        || !run_rsaz29_x8(b) || !run_rsaz29_x8_blinded(b))
        return 0;

    for (lane = 0; lane < LANES; lane++) {
        if (BN_cmp(b->native[lane], b->msg[lane]) != 0
            || BN_cmp(b->native_nb[lane], b->msg[lane]) != 0
            || BN_cmp(b->opt[lane], b->msg[lane]) != 0
            || BN_cmp(b->opt_blind[lane], b->msg[lane]) != 0
            || BN_cmp(b->opt[lane], b->native_nb[lane]) != 0) {
            BIGNUM *refp = BN_new();
            BIGNUM *refq = BN_new();

            fprintf(stderr, "verification failed at lane %d\n", lane);
            fprintf(stderr, "msg bits=%d opt bits=%d opt_blind bits=%d native bits=%d\n",
                    BN_num_bits(b->msg[lane]), BN_num_bits(b->opt[lane]),
                    BN_num_bits(b->opt_blind[lane]),
                    BN_num_bits(b->native_nb[lane]));
            RSA_get0_crt_params(b->rsa, &dmp1, &dmq1, &iqmp);
            if (refp != NULL && refq != NULL && dmp1 != NULL && dmq1 != NULL
                && BN_mod_exp_mont_consttime(refq, b->cq[lane], dmq1,
                                             b->qbr.mod, b->ctx,
                                             b->qbr.mont)
                && BN_mod_exp_mont_consttime(refp, b->cp[lane], dmp1,
                                             b->pbr.mod, b->ctx,
                                             b->pbr.mont)) {
                fprintf(stderr,
                        "branch cmp: q=%d p=%d, bits q opt/ref=%d/%d, p opt/ref=%d/%d\n",
                        BN_cmp(b->mq[lane], refq), BN_cmp(b->mp[lane], refp),
                        BN_num_bits(b->mq[lane]), BN_num_bits(refq),
                        BN_num_bits(b->mp[lane]), BN_num_bits(refp));
            }
            BN_free(refq);
            BN_free(refp);
            return 0;
        }
    }
    return 1;
}

static int bench_loop(BENCH *b, int iters, int (*fn)(BENCH *), uint64_t *ns)
{
    uint64_t start;
    int i;

    for (i = 0; i < WARMUP_ITERS; i++) {
        if (!fn(b))
            return 0;
    }

    start = now_ns();
    for (i = 0; i < iters; i++) {
        if (!fn(b))
            return 0;
    }
    *ns = now_ns() - start;
    return 1;
}

int main(int argc, char **argv)
{
    BENCH bench = { 0 };
    uint64_t native_ns = 0;
    uint64_t native_nb_ns = 0;
    uint64_t rsaz29_ns = 0;
    uint64_t rsaz29_blind_ns = 0;
    uint64_t single_ns = 0;
    int iters = parse_iters(argc, argv);
    const char *mode = argc > 2 ? argv[2] : "all";
    const char *single_label = NULL;
    int (*single_fn)(BENCH *) = NULL;
    int single_mode;
    int ret = EXIT_FAILURE;

    if (iters <= 0)
        return EXIT_FAILURE;

    single_mode = mode_to_runner(mode, &single_fn, &single_label);
    if (single_mode < 0)
        return EXIT_FAILURE;

    if (!prepare_bench(&bench)) {
        fprintf(stderr, "rsa2048_private_rsaz29_x8_bench: setup failed\n");
        ERR_print_errors_fp(stderr);
        goto err;
    }

    if (!verify_results(&bench)) {
        fprintf(stderr, "rsa2048_private_rsaz29_x8_bench: verify failed\n");
        ERR_print_errors_fp(stderr);
        goto err;
    }
    printf("correctness=PASS\n");

    if (single_mode > 0) {
        if (!bench_loop(&bench, iters, single_fn, &single_ns)) {
            fprintf(stderr,
                    "rsa_private_rsaz29_x8_bench: benchmark failed\n");
            ERR_print_errors_fp(stderr);
            goto err;
        }

        printf("rsa%d_private_rsaz29_x8_bench iterations=%d lanes=%d mode=%s\n",
               RSA_BITS, iters, LANES, mode);
        printf("%s=%.2f\n", single_label, (double)single_ns / iters);
        printf("sink=%u\n", bench.sink);
        ret = EXIT_SUCCESS;
        goto err;
    }

    if (!bench_loop(&bench, iters, run_native_default, &native_ns)
        || !bench_loop(&bench, iters, run_native_no_blinding, &native_nb_ns)
        || !bench_loop(&bench, iters, run_rsaz29_x8, &rsaz29_ns)
        || !bench_loop(&bench, iters, run_rsaz29_x8_blinded,
                       &rsaz29_blind_ns)) {
        fprintf(stderr, "rsa_private_rsaz29_x8_bench: benchmark failed\n");
        ERR_print_errors_fp(stderr);
        goto err;
    }

    printf("rsa%d_private_rsaz29_x8_bench iterations=%d lanes=%d\n", RSA_BITS,
           iters, LANES);
    printf("native_default_seq8_rsa_private_ns=%.2f\n",
           (double)native_ns / iters);
    printf("native_no_blind_seq8_rsa_private_ns=%.2f\n",
           (double)native_nb_ns / iters);
    printf("rsaz29_x8_rsa_private_math_ns=%.2f\n",
           (double)rsaz29_ns / iters);
    printf("rsaz29_x8_rsa_private_blinded_ns=%.2f\n",
           (double)rsaz29_blind_ns / iters);
    printf("math_speedup_vs_native_default=%.4f\n",
           (double)native_ns / rsaz29_ns);
    printf("math_speedup_vs_native_no_blind=%.4f\n",
           (double)native_nb_ns / rsaz29_ns);
    printf("blinded_speedup_vs_native_default=%.4f\n",
           (double)native_ns / rsaz29_blind_ns);
    printf("blinded_speedup_vs_native_no_blind=%.4f\n",
           (double)native_nb_ns / rsaz29_blind_ns);
    printf("sink=%u\n", bench.sink);
    ret = EXIT_SUCCESS;

err:
    free_bench(&bench);
    return ret;
}
