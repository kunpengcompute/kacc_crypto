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
import re

root = Path(os.environ["OPENSSL_DIR"])

def replace_once(path, old, new):
    text = path.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"anchor not found in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1))

def remove_all(path, old):
    text = path.read_text()
    if old in text:
        path.write_text(text.replace(old, ""))

def replace_if_present(path, old, new):
    text = path.read_text()
    if old in text and new not in text:
        path.write_text(text.replace(old, new))

def insert_after(path, anchor, addition):
    text = path.read_text()
    if addition in text:
        return
    if anchor not in text:
        raise SystemExit(f"anchor not found in {path}: {anchor!r}")
    path.write_text(text.replace(anchor, anchor + addition, 1))

def insert_before_regex(path, pattern, addition, marker):
    text = path.read_text()
    if marker in text:
        return
    match = re.search(pattern, text, re.M)
    if match is None:
        raise SystemExit(f"anchor pattern not found in {path}: {pattern}")
    path.write_text(text[:match.start()] + addition + text[match.start():])

def replace_braced_if(path, condition, replacement, marker):
    text = path.read_text()
    if marker in text:
        return
    start = text.find(condition)
    if start < 0:
        raise SystemExit(f"condition not found in {path}: {condition!r}")
    line_start = text.rfind("\n", 0, start) + 1
    brace = text.find("{", start)
    if brace < 0:
        raise SystemExit(f"opening brace not found in {path}: {condition!r}")

    depth = 0
    end = None
    for idx in range(brace, len(text)):
        ch = text[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                end = idx + 1
                while end < len(text) and text[end] in " \t":
                    end += 1
                if end < len(text) and text[end] == "\n":
                    end += 1
                break
    if end is None:
        raise SystemExit(f"closing brace not found in {path}: {condition!r}")

    path.write_text(text[:line_start] + replacement + text[end:])

def add_to_assignment(path, var, token, fallback_value=None):
    text = path.read_text()
    if token in text:
        return
    pattern = re.compile(rf"^(\s*{re.escape(var)}=)([^\n]*)$", re.M)
    match = pattern.search(text)
    if match is None:
        alt = re.search(r"^(\s*\$MODESASM_[A-Za-z0-9_]*=)([^\n]*(?:aes-gcm-armv8_64\.S|ghashv8-armx\.S)[^\n]*)$", text, re.M)
        if alt is not None:
            line = alt.group(0)
            new_line = line + f" {token}"
            path.write_text(text[:alt.start()] + new_line + text[alt.end():])
            return
        if fallback_value is None:
            raise SystemExit(f"assignment not found in {path}: {var}")
        anchor = "  # Now that we have defined all the arch specific variables"
        if anchor not in text:
            anchor = "  IF[$MODESASM_{- $target{asm_arch} -}]"
        if anchor not in text:
            raise SystemExit(f"assignment not found in {path}: {var}")
        path.write_text(text.replace(anchor, f"  {var}={fallback_value}\n{anchor}", 1))
        return
    line = match.group(0)
    new_line = line + f" {token}"
    path.write_text(text[:match.start()] + new_line + text[match.end():])

def add_common_source_before_marker(path, source, marker):
    text = path.read_text()
    if source in text:
        return
    lines = text.splitlines(True)
    offset = 0
    block_start = None
    block_end = None
    for line in lines:
        line_end = offset + len(line)
        if block_start is None and line.startswith("$COMMON="):
            block_start = offset
            block_end = line_end
            if not line.rstrip("\n").rstrip().endswith("\\"):
                break
        elif block_start is not None:
            block_end = line_end
            if not line.rstrip("\n").rstrip().endswith("\\"):
                break
        offset = line_end
    if block_start is None or block_end is None:
        raise SystemExit(f"$COMMON assignment not found in {path}")
    common = text[block_start:block_end]
    marker_match = re.search(
        rf"(?<![A-Za-z0-9_]){re.escape(marker)}(?![A-Za-z0-9_])",
        common,
    )
    if marker_match is None:
        raise SystemExit(f"marker not found in $COMMON assignment in {path}: {marker!r}")
    insert_at = block_start + marker_match.start()
    path.write_text(text[:insert_at] + source + " " + text[insert_at:])

def patch_armv9_sve2_armcap(root):
    arm_arch = root / "crypto/arm_arch.h"
    text = arm_arch.read_text()
    if "ARMV9_SVE2" not in text:
        anchor = "# define ARMV8_CPUID     (1<<7)\n"
        if anchor not in text:
            raise SystemExit(f"ARMV8_CPUID anchor not found in {arm_arch}")
        text = text.replace(
            anchor,
            anchor
            + "# define ARMV8_SVE        (1<<13)\n"
            + "# define ARMV9_SVE2       (1<<14)\n",
            1,
        )
        arm_arch.write_text(text)

    armcap = root / "crypto/armcap.c"
    text = armcap.read_text()
    if "KACC_HWCAP2_SVE2" not in text:
        anchor = "#  define HWCAP_CE_SHA512        (1 << 21)\n"
        if anchor not in text:
            raise SystemExit(f"HWCAP_CE_SHA512 anchor not found in {armcap}")
        text = text.replace(
            anchor,
            anchor
            + "#  define KACC_HWCAP2             AT_HWCAP2\n"
            + "#  define KACC_HWCAP2_SVE2        (1 << 1)\n",
            1,
        )
    if "OPENSSL_armcap_P |= ARMV9_SVE2" not in text:
        anchor = (
            "        if (hwcap & HWCAP_CPUID)\n"
            "            OPENSSL_armcap_P |= ARMV8_CPUID;\n"
        )
        if anchor not in text:
            raise SystemExit(f"ARMV8_CPUID setup anchor not found in {armcap}")
        text = text.replace(
            anchor,
            anchor
            + "\n"
            + "        if (getauxval(KACC_HWCAP2) & KACC_HWCAP2_SVE2)\n"
            + "            OPENSSL_armcap_P |= ARMV9_SVE2;\n",
            1,
        )
    armcap.write_text(text)

def add_source_before_marker(path, source, marker):
    text = path.read_text()
    if source in text:
        return
    pattern = re.compile(rf"(?<![A-Za-z0-9_]){re.escape(marker)}(?![A-Za-z0-9_])")
    match = pattern.search(text)
    if match is None:
        raise SystemExit(f"marker not found in {path}: {marker!r}")
    text = text[:match.start()] + source + " " + text[match.start():]
    path.write_text(text)

def insert_aarch64_gcm_platform(path):
    text = path.read_text()
    if "ARMV9_SVE2_AES_GCM_CAPABLE" in text:
        return

    decrypt_re = re.compile(
        r"^[ \t]*#[ \t]*define[ \t]+AES_gcm_decrypt[ \t]+"
        r"armv8_aes_gcm_decrypt[ \t]*\n",
        re.M,
    )
    decrypt_match = decrypt_re.search(text)
    if decrypt_match is None:
        raise SystemExit(f"AES_gcm_decrypt define not found in {path}")

    pos = decrypt_match.end()
    ghash_field = "gcm.funcs.ghash" if "gcm.funcs.ghash" in text else "gcm.ghash"
    macro_re = re.compile(r"^[ \t]*#[ \t]*define[ \t]+AES_GCM_ASM\([^\n]*\).*\n", re.M)
    macro_match = macro_re.search(text, pos)
    block_end = text.find("# endif", pos)
    if block_end < 0:
        block_end = text.find("#endif", pos)
    if macro_match is None or (block_end >= 0 and macro_match.start() > block_end):
        compat = (
            "#define AES_GCM_ASM(gctx) (((gctx)->ctr == aes_v8_ctr32_encrypt_blocks) "
            f"&& (gctx)->{ghash_field} == gcm_ghash_v8)\n"
        )
        text = text[:pos] + compat + text[pos:]
        pos += len(compat)
    else:
        pos = macro_match.end()
        while pos >= 2 and text[pos - 2] == "\\":
            next_newline = text.find("\n", pos)
            if next_newline < 0:
                raise SystemExit(f"unterminated AES_GCM_ASM macro in {path}")
            pos = next_newline + 1

    addition = (
        "#define ARMV9_SVE2_AES_GCM_CAPABLE \\\n"
        "    ((OPENSSL_armcap_P & ARMV8_AES) && (OPENSSL_armcap_P & ARMV8_PMULL) \\\n"
        "     && (OPENSSL_armcap_P & ARMV9_SVE2))\n"
        "#define AES_GCM_SVE2_ENC_BYTES 8192\n"
        "#define AES_GCM_SVE2_DEC_BYTES 8192\n"
        "void armv9_sve2_aes_gcm_precompute(const u128 Htable[16],\n"
        "    u128 pairtab[1024]);\n"
        "size_t armv9_sve2_aes_gcm_encrypt(const unsigned char *in,\n"
        "    unsigned char *out, size_t len, const void *key,\n"
        "    unsigned char ivec[16], u64 *Xi, const u128 pairtab[1024]);\n"
        "size_t armv9_sve2_aes_gcm_decrypt(const unsigned char *in,\n"
        "    unsigned char *out, size_t len, const void *key,\n"
        "    unsigned char ivec[16], u64 *Xi, const u128 pairtab[1024]);\n"
    )
    path.write_text(text[:pos] + addition + text[pos:])

patch_armv9_sve2_armcap(root)

build_info = root / "crypto/modes/build.info"
add_to_assignment(
    build_info,
    "$MODESASM_aarch64",
    "ghash-sve2-armv8_64.S",
    "ghashv8-armx.S aes-gcm-armv8_64.S ghash-sve2-armv8_64.S",
)
add_common_source_before_marker(build_info, "gcm-sve2-armv8.c", "$MODESASM")
insert_after(
    build_info,
    "INCLUDE[gcm128.o]=..\n",
    "INCLUDE[gcm-sve2-armv8.o]=..\n",
)
insert_after(
    build_info,
    "INCLUDE[aes-gcm-armv8_64.o]=..\n",
    "GENERATE[ghash-sve2-armv8_64.S]=asm/ghash-sve2-armv8_64.pl\nINCLUDE[ghash-sve2-armv8_64.o]=..\n",
)

aes_platform = root / "include/crypto/aes_platform.h"
insert_aarch64_gcm_platform(aes_platform)

cipher_aes_gcm_h = root / "providers/implementations/ciphers/cipher_aes_gcm.h"
old_sve2_gcm_struct = (
    "#if defined(OPENSSL_CPUID_OBJ) && defined(__aarch64__)\n"
    "        struct {\n"
    "            u128 *pairtab;\n"
    "            unsigned int pairtab_ready;\n"
    "        } sve2_gcm;\n"
    "#endif\n"
)
new_sve2_gcm_struct = (
    "#if defined(OPENSSL_CPUID_OBJ) && defined(__aarch64__)\n"
    "        struct {\n"
    "            u128 *pairtab;\n"
    "            u128 pairtab_htable[16];\n"
    "            unsigned int pairtab_ready;\n"
    "        } sve2_gcm;\n"
    "#endif\n"
)
replace_if_present(cipher_aes_gcm_h, old_sve2_gcm_struct, new_sve2_gcm_struct)
insert_after(
    cipher_aes_gcm_h,
    "        int dummy;\n",
    new_sve2_gcm_struct,
)

cipher_aes_gcm_c = root / "providers/implementations/ciphers/cipher_aes_gcm.c"
insert_after(
    cipher_aes_gcm_c,
    """    if (dctx != NULL && dctx->base.gcm.key != NULL)
        dctx->base.gcm.key = &dctx->ks.ks;
""",
    """#if defined(OPENSSL_CPUID_OBJ) && defined(__aarch64__)
    if (dctx != NULL && ctx->plat.sve2_gcm.pairtab != NULL) {
        dctx->plat.sve2_gcm.pairtab = OPENSSL_memdup(
            ctx->plat.sve2_gcm.pairtab, sizeof(u128) * 1024);
        if (dctx->plat.sve2_gcm.pairtab == NULL) {
            OPENSSL_clear_free(dctx, sizeof(*dctx));
            return NULL;
        }
    }
#endif
""",
)
insert_after(
    cipher_aes_gcm_c,
    """    PROV_AES_GCM_CTX *ctx = (PROV_AES_GCM_CTX *)vctx;

""",
    """#if defined(OPENSSL_CPUID_OBJ) && defined(__aarch64__)
    if (ctx != NULL)
        OPENSSL_clear_free(ctx->plat.sve2_gcm.pairtab, sizeof(u128) * 1024);
#endif
""",
)

gcm_hw = root / "providers/implementations/ciphers/cipher_aes_gcm_hw.c"
old_sve2_pairtab_func = """#if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
static const u128 *aes_gcm_sve2_pairtab(PROV_GCM_CTX *ctx)
{
    PROV_AES_GCM_CTX *actx = (PROV_AES_GCM_CTX *)ctx;

    if (actx->plat.sve2_gcm.pairtab == NULL) {
        actx->plat.sve2_gcm.pairtab = OPENSSL_zalloc(sizeof(u128) * 1024);
        if (actx->plat.sve2_gcm.pairtab == NULL)
            return NULL;
        actx->plat.sve2_gcm.pairtab_ready = 0;
    }
    if (!actx->plat.sve2_gcm.pairtab_ready) {
        armv9_sve2_aes_gcm_precompute(ctx->gcm.Htable,
                                      actx->plat.sve2_gcm.pairtab);
        actx->plat.sve2_gcm.pairtab_ready = 1;
    }
    return actx->plat.sve2_gcm.pairtab;
}
#endif

"""
remove_all(gcm_hw, old_sve2_pairtab_func)
insert_after(
    gcm_hw,
    "#include \"internal/deprecated.h\"\n",
    "#include <string.h>\n",
)
insert_after(
    gcm_hw,
    """    return 1;
}

""",
    """#if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
static const u128 *aes_gcm_sve2_pairtab(PROV_GCM_CTX *ctx)
{
    PROV_AES_GCM_CTX *actx = (PROV_AES_GCM_CTX *)ctx;

    if (actx->plat.sve2_gcm.pairtab == NULL) {
        actx->plat.sve2_gcm.pairtab = OPENSSL_zalloc(sizeof(u128) * 1024);
        if (actx->plat.sve2_gcm.pairtab == NULL)
            return NULL;
        actx->plat.sve2_gcm.pairtab_ready = 0;
    }
    if (!actx->plat.sve2_gcm.pairtab_ready
            || memcmp(actx->plat.sve2_gcm.pairtab_htable, ctx->gcm.Htable,
                      sizeof(actx->plat.sve2_gcm.pairtab_htable)) != 0) {
        armv9_sve2_aes_gcm_precompute(ctx->gcm.Htable,
                                      actx->plat.sve2_gcm.pairtab);
        memcpy(actx->plat.sve2_gcm.pairtab_htable, ctx->gcm.Htable,
               sizeof(actx->plat.sve2_gcm.pairtab_htable));
        actx->plat.sve2_gcm.pairtab_ready = 1;
    }
    return actx->plat.sve2_gcm.pairtab;
}
#endif

""",
)
remove_all(
    gcm_hw,
    """#if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
    actx->plat.sve2_gcm.pairtab_ready = 0;
#endif
""",
)
replace_braced_if(
    gcm_hw,
    "if (len >= AES_GCM_ENC_BYTES && AES_GCM_ASM(ctx))",
    """# if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
            if (len >= AES_GCM_SVE2_ENC_BYTES && ARMV9_SVE2_AES_GCM_CAPABLE
                && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;
                const u128 *pairtab;

                if (CRYPTO_gcm128_encrypt(&ctx->gcm, in, out, res))
                    return 0;

                pairtab = aes_gcm_sve2_pairtab(ctx);
                bulk = armv9_sve2_aes_gcm_encrypt(in + res, out + res,
                    len - res, ctx->gcm.key, ctx->gcm.Yi.c,
                    ctx->gcm.Xi.u, pairtab);

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
    "AES_GCM_SVE2_ENC_BYTES",
)
replace_braced_if(
    gcm_hw,
    "if (len >= AES_GCM_DEC_BYTES && AES_GCM_ASM(ctx))",
    """# if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
            if (len >= AES_GCM_SVE2_DEC_BYTES && ARMV9_SVE2_AES_GCM_CAPABLE
                && AES_GCM_ASM(ctx)) {
                size_t res = (16 - ctx->gcm.mres) % 16;
                const u128 *pairtab;

                if (CRYPTO_gcm128_decrypt(&ctx->gcm, in, out, res))
                    return 0;

                pairtab = aes_gcm_sve2_pairtab(ctx);
                bulk = armv9_sve2_aes_gcm_decrypt(in + res, out + res,
                    len - res, ctx->gcm.key, ctx->gcm.Yi.c,
                    ctx->gcm.Xi.u, pairtab);

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
    "AES_GCM_SVE2_DEC_BYTES",
)

armv8_inc = root / "providers/implementations/ciphers/cipher_aes_gcm_hw_armv8.inc"
armv8_addition = """#if defined(ARMV9_SVE2_AES_GCM_CAPABLE)
    actx->plat.sve2_gcm.pairtab_ready = 0;
#endif
"""
remove_all(armv8_inc, armv8_addition)
PY
