/*
 * SVE2 AES-GCM dispatch helpers for AArch64.
 *
 * The hot assembly kernel consumes a 512-block GHASH pair table.  OpenSSL
 * already keeps the base Htable in GCM128_CONTEXT, so the provider fast path
 * passes that table here and avoids recomputing the GHASH key itself.
 */

#include <string.h>

#include <openssl/aes.h>
#include "crypto/modes.h"

#if defined(OPENSSL_CPUID_OBJ) && defined(__aarch64__)
# include "crypto/aes_platform.h"
# include "crypto/arm_arch.h"

# define GCM_SVE2_WINDOW_BYTES 8192
/*
 * The prefetching decrypt kernel is intentionally narrow: unit and nginx
 * tests showed it helps 16KB-class decrypt records, while encrypt and larger
 * buffers are better left on the non-prefetch kernels.
 */
# define GCM_SVE2_DEC_PREFETCH_BYTES 16384
# define GCM_SVE2_DEC_PREFETCH_LIMIT 32768
# define GCM_SVE2_PAIRTAB_ELEMS 1024

extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_12_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_14_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_12_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_pf_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);
extern size_t gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_pf_asm(
    const unsigned char *in, unsigned char *out, size_t len, u64 Xi[2],
    const AES_KEY *key, const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
    const unsigned char ivec[16]);

static uint32_t gcm_sve2_get_be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
           | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static void gcm_sve2_put_be32(unsigned char *p, uint32_t v)
{
    p[0] = (unsigned char)(v >> 24);
    p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8);
    p[3] = (unsigned char)v;
}

static void gcm_sve2_advance_ctr(unsigned char ivec[16], size_t blocks)
{
    uint32_t ctr = gcm_sve2_get_be32(ivec + 12);

    gcm_sve2_put_be32(ivec + 12, ctr + (uint32_t)blocks);
}

static void gcm_sve2_clmul64(uint64_t out[2], uint64_t a, uint64_t b)
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

static void gcm_sve2_xor128(uint64_t out[2], const uint64_t a[2],
                            const uint64_t b[2])
{
    out[0] = a[0] ^ b[0];
    out[1] = a[1] ^ b[1];
}

static void gcm_sve2_ext8(uint64_t out[2], const uint64_t a[2],
                          const uint64_t b[2])
{
    out[0] = a[1];
    out[1] = b[0];
}

static void gcm_sve2_mul_hpow(u128 *out, const u128 *a, const u128 *b)
{
    const uint64_t c2[2] = { 0xc200000000000000ULL, 0 };
    uint64_t ap[2], bp[2], xl[2], xm[2], xh[2];
    uint64_t t0[2], t1[2], t2[2], result[2];
    uint64_t amid, bmid;

    memcpy(ap, a, sizeof(ap));
    memcpy(bp, b, sizeof(bp));
    gcm_sve2_clmul64(xl, ap[0], bp[0]);
    gcm_sve2_clmul64(xh, ap[1], bp[1]);
    amid = ap[0] ^ ap[1];
    bmid = bp[0] ^ bp[1];
    gcm_sve2_clmul64(xm, amid, bmid);

    gcm_sve2_ext8(t1, xl, xh);
    gcm_sve2_xor128(t2, xl, xh);
    gcm_sve2_xor128(xm, xm, t1);
    gcm_sve2_xor128(xm, xm, t2);
    gcm_sve2_clmul64(t2, xl[0], c2[0]);

    xh[0] = xm[1];
    xm[1] = xl[0];
    gcm_sve2_xor128(xl, xm, t2);

    gcm_sve2_ext8(t2, xl, xl);
    gcm_sve2_clmul64(t0, xl[0], c2[0]);
    gcm_sve2_xor128(t2, t2, xh);
    gcm_sve2_xor128(result, t0, t2);
    memcpy(out, result, sizeof(*out));
}

static void gcm_sve2_precompute_pairtab(const u128 htable[16],
                                        u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS])
{
    u128 hpow[513];
    size_t i, j;

    memset(hpow, 0, sizeof(hpow));
    hpow[1] = htable[0];
    for (i = 2; i <= 512; i++)
        gcm_sve2_mul_hpow(&hpow[i], &hpow[i - 1], &hpow[1]);

    memset(pairtab, 0, sizeof(u128) * GCM_SVE2_PAIRTAB_ELEMS);
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

void armv9_sve2_aes_gcm_precompute(const u128 htable[16],
                                   u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS])
{
    gcm_sve2_precompute_pairtab(htable, pairtab);
}

static int gcm_sve2_capable(void)
{
    return (OPENSSL_armcap_P & ARMV8_AES) != 0
           && (OPENSSL_armcap_P & ARMV8_PMULL) != 0
           && (OPENSSL_armcap_P & ARMV9_SVE2) != 0;
}

static size_t gcm_sve2_call_kernel(int enc, const unsigned char *in,
                                   unsigned char *out, size_t len,
                                   u64 Xi[2], const AES_KEY *key,
                                   const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS],
                                   const unsigned char ivec[16])
{
    switch (key->rounds) {
    case 10:
        if (!enc && len >= GCM_SVE2_DEC_PREFETCH_BYTES
            && len < GCM_SVE2_DEC_PREFETCH_LIMIT)
            return gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_pf_asm(
                in, out, len, Xi, key, pairtab, ivec);
        return enc
            ? gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm(
                  in, out, len, Xi, key, pairtab, ivec)
            : gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_10_asm(
                  in, out, len, Xi, key, pairtab, ivec);
    case 12:
        return enc
            ? gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_12_asm(
                  in, out, len, Xi, key, pairtab, ivec)
            : gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_12_asm(
                  in, out, len, Xi, key, pairtab, ivec);
    case 14:
        if (!enc && len >= GCM_SVE2_DEC_PREFETCH_BYTES
            && len < GCM_SVE2_DEC_PREFETCH_LIMIT)
            return gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_pf_asm(
                in, out, len, Xi, key, pairtab, ivec);
        return enc
            ? gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_14_asm(
                  in, out, len, Xi, key, pairtab, ivec)
            : gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_14_asm(
                  in, out, len, Xi, key, pairtab, ivec);
    default:
        return 0;
    }
}

static size_t gcm_sve2_aes_gcm_crypt(int enc, const unsigned char *in,
                                     unsigned char *out, size_t len,
                                     const void *key, unsigned char ivec[16],
                                     u64 Xi[2],
                                     const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS])
{
    const AES_KEY *aes_key = (const AES_KEY *)key;
    size_t align_bytes = len - len % 16;
    size_t done;

    if (!gcm_sve2_capable() || pairtab == NULL
        || align_bytes < GCM_SVE2_WINDOW_BYTES)
        return enc ? armv8_aes_gcm_encrypt(in, out, len, key, ivec, Xi)
                   : armv8_aes_gcm_decrypt(in, out, len, key, ivec, Xi);

    done = gcm_sve2_call_kernel(enc, in, out, align_bytes, Xi, aes_key,
                                pairtab, ivec);
    if (done == 0)
        return enc ? armv8_aes_gcm_encrypt(in, out, len, key, ivec, Xi)
                   : armv8_aes_gcm_decrypt(in, out, len, key, ivec, Xi);

    gcm_sve2_advance_ctr(ivec, done / 16);
    if (done < align_bytes) {
        size_t tail = enc
            ? armv8_aes_gcm_encrypt(in + done, out + done, align_bytes - done,
                                    key, ivec, Xi)
            : armv8_aes_gcm_decrypt(in + done, out + done, align_bytes - done,
                                    key, ivec, Xi);
        done += tail;
    }

    return done;
}

size_t armv9_sve2_aes_gcm_encrypt(const unsigned char *in, unsigned char *out,
                                  size_t len, const void *key,
                                  unsigned char ivec[16], u64 *Xi,
                                  const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS])
{
    return gcm_sve2_aes_gcm_crypt(1, in, out, len, key, ivec, Xi, pairtab);
}

size_t armv9_sve2_aes_gcm_decrypt(const unsigned char *in, unsigned char *out,
                                  size_t len, const void *key,
                                  unsigned char ivec[16], u64 *Xi,
                                  const u128 pairtab[GCM_SVE2_PAIRTAB_ELEMS])
{
    return gcm_sve2_aes_gcm_crypt(0, in, out, len, key, ivec, Xi, pairtab);
}
#endif
