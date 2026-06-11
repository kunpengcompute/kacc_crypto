#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  OPENSSL_DIR=/path/to/openssl ./scripts/install_sve2_gcm_dispatch.sh
  ./scripts/install_sve2_gcm_dispatch.sh /path/to/openssl

Installs the SVE2 AES-GCM prototype sources and wires a runtime SVE2
large-window dispatch into an OpenSSL source tree.  The edits are idempotent:
SVE2-capable machines use the optimized GCM window, other machines keep the
original ARMv8/NEON path.
USAGE
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_dir="${1:-${OPENSSL_DIR:-}}"

if [ -z "${openssl_dir}" ]; then
    usage >&2
    exit 2
fi

if [ ! -d "${openssl_dir}/crypto/modes/asm" ] \
   || [ ! -f "${openssl_dir}/providers/implementations/ciphers/cipher_aes_gcm_hw.c" ]; then
    echo "error: OPENSSL_DIR does not look like an OpenSSL source tree: ${openssl_dir}" >&2
    exit 2
fi

install -m 0644 \
    "${repo_dir}/openssl/crypto/modes/asm/ghash-sve2-armv8_64.pl" \
    "${openssl_dir}/crypto/modes/asm/ghash-sve2-armv8_64.pl"
install -m 0644 \
    "${repo_dir}/openssl/crypto/modes/gcm-sve2-armv8.c" \
    "${openssl_dir}/crypto/modes/gcm-sve2-armv8.c"
install -m 0644 \
    "${repo_dir}/openssl/crypto/modes/asm/gcm_unit_bench.c" \
    "${openssl_dir}/crypto/modes/asm/gcm_unit_bench.c"
install -m 0755 \
    "${repo_dir}/openssl/crypto/modes/asm/run_gcm_unit_bench.sh" \
    "${openssl_dir}/crypto/modes/asm/run_gcm_unit_bench.sh"
install -m 0755 \
    "${repo_dir}/openssl/crypto/modes/asm/run_all_gcm_tests.sh" \
    "${openssl_dir}/crypto/modes/asm/run_all_gcm_tests.sh"
install -m 0755 \
    "${repo_dir}/openssl/crypto/modes/asm/run_gcm_pmu_compare.sh" \
    "${openssl_dir}/crypto/modes/asm/run_gcm_pmu_compare.sh"

OPENSSL_DIR="${openssl_dir}" python3 <<'PY'
from pathlib import Path
import os

root = Path(os.environ["OPENSSL_DIR"])

def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"anchor not found in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1))

def insert_after(path, anchor, addition):
    text = path.read_text()
    if addition in text:
        return
    if anchor not in text:
        raise SystemExit(f"anchor not found in {path}: {anchor!r}")
    path.write_text(text.replace(anchor, anchor + addition, 1))

build_info = root / "crypto/modes/build.info"
replace_once(
    build_info,
    "$MODESASM_aarch64=ghashv8-armx.S aes-gcm-armv8_64.S aes-gcm-armv8-unroll8_64.S\n",
    "$MODESASM_aarch64=ghashv8-armx.S aes-gcm-armv8_64.S aes-gcm-armv8-unroll8_64.S ghash-sve2-armv8_64.S\n",
)
replace_once(
    build_info,
    "        wrap128.c xts128gb.c $MODESASM\n",
    "        wrap128.c xts128gb.c gcm-sve2-armv8.c $MODESASM\n",
)
insert_after(
    build_info,
    "GENERATE[aes-gcm-armv8-unroll8_64.S]=asm/aes-gcm-armv8-unroll8_64.pl\nINCLUDE[aes-gcm-armv8-unroll8_64.o]=..\n",
    "GENERATE[ghash-sve2-armv8_64.S]=asm/ghash-sve2-armv8_64.pl\nINCLUDE[ghash-sve2-armv8_64.o]=..\n",
)

aes_platform = root / "include/crypto/aes_platform.h"
insert_after(
    aes_platform,
    "#define AES_GCM_ASM(gctx) (((gctx)->ctr == aes_v8_ctr32_encrypt_blocks_unroll12_eor3 || (gctx)->ctr == aes_v8_ctr32_encrypt_blocks) && (gctx)->gcm.funcs.ghash == gcm_ghash_v8)\n",
    "#define ARMV9_SVE2_AES_GCM_CAPABLE \\\n"
    "    ((OPENSSL_armcap_P & ARMV8_AES) && (OPENSSL_armcap_P & ARMV8_PMULL) \\\n"
    "     && (OPENSSL_armcap_P & ARMV9_SVE2))\n"
    "#define AES_GCM_SVE2_ENC_BYTES 8192\n"
    "#define AES_GCM_SVE2_DEC_BYTES 8192\n"
    "size_t armv9_sve2_aes_gcm_encrypt(const unsigned char *in,\n"
    "    unsigned char *out, size_t len, const void *key,\n"
    "    unsigned char ivec[16], u64 *Xi, const u128 Htable[16]);\n"
    "size_t armv9_sve2_aes_gcm_decrypt(const unsigned char *in,\n"
    "    unsigned char *out, size_t len, const void *key,\n"
    "    unsigned char ivec[16], u64 *Xi, const u128 Htable[16]);\n",
)

gcm_hw = root / "providers/implementations/ciphers/cipher_aes_gcm_hw.c"
replace_once(
    gcm_hw,
    """            if (len >= AES_GCM_ENC_BYTES && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;

                if (CRYPTO_gcm128_encrypt(&ctx->gcm, in, out, res))
                    return 0;

                bulk = AES_gcm_encrypt(in + res, out + res, len - res,
                    ctx->gcm.key,
                    ctx->gcm.Yi.c, ctx->gcm.Xi.u);

                ctx->gcm.len.u[1] += bulk;
                bulk += res;
            }
""",
    """# if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
            if (len >= AES_GCM_SVE2_ENC_BYTES && ARMV9_SVE2_AES_GCM_CAPABLE
                && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;

                if (CRYPTO_gcm128_encrypt(&ctx->gcm, in, out, res))
                    return 0;

                bulk = armv9_sve2_aes_gcm_encrypt(in + res, out + res,
                    len - res, ctx->gcm.key, ctx->gcm.Yi.c,
                    ctx->gcm.Xi.u, ctx->gcm.Htable);

                ctx->gcm.len.u[1] += bulk;
                bulk += res;
            } else
# endif
            if (len >= AES_GCM_ENC_BYTES && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;

                if (CRYPTO_gcm128_encrypt(&ctx->gcm, in, out, res))
                    return 0;

                bulk = AES_gcm_encrypt(in + res, out + res, len - res,
                    ctx->gcm.key,
                    ctx->gcm.Yi.c, ctx->gcm.Xi.u);

                ctx->gcm.len.u[1] += bulk;
                bulk += res;
            }
""",
)
replace_once(
    gcm_hw,
    """            if (len >= AES_GCM_DEC_BYTES && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;

                if (CRYPTO_gcm128_decrypt(&ctx->gcm, in, out, res))
                    return 0;

                bulk = AES_gcm_decrypt(in + res, out + res, len - res,
                    ctx->gcm.key,
                    ctx->gcm.Yi.c, ctx->gcm.Xi.u);

                ctx->gcm.len.u[1] += bulk;
                bulk += res;
            }
""",
    """# if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
            if (len >= AES_GCM_SVE2_DEC_BYTES && ARMV9_SVE2_AES_GCM_CAPABLE
                && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;

                if (CRYPTO_gcm128_decrypt(&ctx->gcm, in, out, res))
                    return 0;

                bulk = armv9_sve2_aes_gcm_decrypt(in + res, out + res,
                    len - res, ctx->gcm.key, ctx->gcm.Yi.c,
                    ctx->gcm.Xi.u, ctx->gcm.Htable);

                ctx->gcm.len.u[1] += bulk;
                bulk += res;
            } else
# endif
            if (len >= AES_GCM_DEC_BYTES && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;

                if (CRYPTO_gcm128_decrypt(&ctx->gcm, in, out, res))
                    return 0;

                bulk = AES_gcm_decrypt(in + res, out + res, len - res,
                    ctx->gcm.key,
                    ctx->gcm.Yi.c, ctx->gcm.Xi.u);

                ctx->gcm.len.u[1] += bulk;
                bulk += res;
            }
""",
)
PY
