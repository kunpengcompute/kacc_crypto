#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  OPENSSL_DIR=/path/to/openssl ./scripts/install_sve2_xts_dispatch.sh
  ./scripts/install_sve2_xts_dispatch.sh /path/to/openssl

Installs the SVE2 AES-XTS source files and wires runtime dispatch into an
OpenSSL source tree.  The edits are idempotent.
USAGE
}

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openssl_dir="${1:-${OPENSSL_DIR:-}}"

if [ -z "${openssl_dir}" ]; then
    usage >&2
    exit 2
fi

if [ ! -d "${openssl_dir}/crypto/aes/asm" ]; then
    echo "error: OPENSSL_DIR does not look like an OpenSSL source tree: ${openssl_dir}" >&2
    exit 2
fi

install -m 0644 \
    "${repo_dir}/openssl/crypto/aes/asm/aesv8-armx-sve2.pl" \
    "${openssl_dir}/crypto/aes/asm/aesv8-armx-sve2.pl"
install -m 0644 \
    "${repo_dir}/openssl/crypto/aes/asm/aesv8-armx-sve2.h" \
    "${openssl_dir}/crypto/aes/asm/aesv8-armx-sve2.h"
install -m 0644 \
    "${repo_dir}/openssl/crypto/aes/asm/sve2_unit_tests.c" \
    "${openssl_dir}/crypto/aes/asm/sve2_unit_tests.c"
install -m 0644 \
    "${repo_dir}/openssl/crypto/aes/asm/sve2_performance_test.c" \
    "${openssl_dir}/crypto/aes/asm/sve2_performance_test.c"
install -m 0755 \
    "${repo_dir}/openssl/crypto/aes/asm/run_all_tests.sh" \
    "${openssl_dir}/crypto/aes/asm/run_all_tests.sh"

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

def insert_after(path, anchor, addition):
    text = path.read_text()
    if addition in text:
        return
    if anchor not in text:
        raise SystemExit(f"anchor not found in {path}: {anchor!r}")
    path.write_text(text.replace(anchor, anchor + addition, 1))

def add_to_assignment(path, var, token, fallback_value=None):
    text = path.read_text()
    if token in text:
        return
    pattern = re.compile(rf"^(\s*{re.escape(var)}=)([^\n]*)$", re.M)
    match = pattern.search(text)
    if match is not None:
        line = match.group(0)
        path.write_text(text[:match.start()] + line + f" {token}" + text[match.end():])
        return

    alt = re.search(r"^(\s*\$AESASM_[A-Za-z0-9_]*=)([^\n]*aesv8-armx\.S[^\n]*)$", text, re.M)
    if alt is not None:
        line = alt.group(0)
        path.write_text(text[:alt.start()] + line + f" {token}" + text[alt.end():])
        return

    if fallback_value is None:
        raise SystemExit(f"assignment not found in {path}: {var}")
    anchor = "IF[$AESASM_{- $target{asm_arch} -}]"
    if anchor not in text:
        raise SystemExit(f"assignment not found in {path}: {var}")
    path.write_text(text.replace(anchor, f"{var}={fallback_value}\n{anchor}", 1))

def insert_after_regex(path, pattern, addition, marker):
    text = path.read_text()
    if marker in text:
        return
    match = re.search(pattern, text, re.M)
    if match is None:
        raise SystemExit(f"anchor pattern not found in {path}: {pattern}")
    path.write_text(text[:match.end()] + addition + text[match.end():])

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

patch_armv9_sve2_armcap(root)

build_info = root / "crypto/aes/build.info"
add_to_assignment(
    build_info,
    "$AESASM_aarch64",
    "aesv8-armx-sve2.S",
    "aes_core.c aes_cbc.c aesv8-armx.S aesv8-armx-sve2.S vpaes-armv8.S",
)
insert_after(
    build_info,
    """GENERATE[aesv8-armx.S]=asm/aesv8-armx.pl
INCLUDE[aesv8-armx.o]=..
""",
    """GENERATE[aesv8-armx-sve2.S]=asm/aesv8-armx-sve2.pl
INCLUDE[aesv8-armx-sve2.o]=..
""",
)

aes_platform = root / "include/crypto/aes_platform.h"
insert_after_regex(
    aes_platform,
    r"^[ \t]*#[ \t]*define[ \t]+HWAES_xts_decrypt[ \t]+aes_v8_xts_decrypt[ \t]*\n",
    """#define ARMV9_SVE2_AES_XTS_CAPABLE \\
    ((OPENSSL_armcap_P & ARMV8_AES) && (OPENSSL_armcap_P & ARMV9_SVE2))
void aes_v8_sve2_xts_128_encrypt(const unsigned char *inp,
    unsigned char *out, size_t len,
    const AES_KEY *key1, const AES_KEY *key2,
    const unsigned char iv[16]);
void aes_v8_sve2_xts_128_decrypt(const unsigned char *inp,
    unsigned char *out, size_t len,
    const AES_KEY *key1, const AES_KEY *key2,
    const unsigned char iv[16]);
void aes_v8_sve2_xts_192_encrypt(const unsigned char *inp,
    unsigned char *out, size_t len,
    const AES_KEY *key1, const AES_KEY *key2,
    const unsigned char iv[16]);
void aes_v8_sve2_xts_192_decrypt(const unsigned char *inp,
    unsigned char *out, size_t len,
    const AES_KEY *key1, const AES_KEY *key2,
    const unsigned char iv[16]);
void aes_v8_sve2_xts_256_encrypt(const unsigned char *inp,
    unsigned char *out, size_t len,
    const AES_KEY *key1, const AES_KEY *key2,
    const unsigned char iv[16]);
void aes_v8_sve2_xts_256_decrypt(const unsigned char *inp,
    unsigned char *out, size_t len,
    const AES_KEY *key1, const AES_KEY *key2,
    const unsigned char iv[16]);
""",
    "ARMV9_SVE2_AES_XTS_CAPABLE",
)

xts_hw = root / "providers/implementations/ciphers/cipher_aes_xts_hw.c"
insert_after_regex(
    xts_hw,
    r"^[ \t]*#[ \t]*ifdef[ \t]+HWAES_xts_decrypt\n"
    r"[ \t]*stream_dec[ \t]*=[ \t]*HWAES_xts_decrypt;\n"
    r"^[ \t]*#[ \t]*endif[^\n]*HWAES_xts_decrypt[^\n]*\n",
    """#ifdef ARMV9_SVE2_AES_XTS_CAPABLE
        if (ARMV9_SVE2_AES_XTS_CAPABLE) {
            switch (keylen) {
            case 32:
                stream_enc = aes_v8_sve2_xts_128_encrypt;
                stream_dec = aes_v8_sve2_xts_128_decrypt;
                break;
            case 48:
                stream_enc = aes_v8_sve2_xts_192_encrypt;
                stream_dec = aes_v8_sve2_xts_192_decrypt;
                break;
            case 64:
                stream_enc = aes_v8_sve2_xts_256_encrypt;
                stream_dec = aes_v8_sve2_xts_256_decrypt;
                break;
            default:
                break;
            }
        }
#endif /* ARMV9_SVE2_AES_XTS_CAPABLE */
""",
    "aes_v8_sve2_xts_128_encrypt",
)
PY
