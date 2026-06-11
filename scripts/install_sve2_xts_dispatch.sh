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

build_info = root / "crypto/aes/build.info"
replace_once(
    build_info,
    """  $AESASM_aarch64=\\
        aes_core.c aes_cbc.c aesv8-armx.S bsaes-armv8.S vpaes-armv8.S \\
        aes-sha1-armv8.S aes-sha256-armv8.S aes-sha512-armv8.S
""",
    """  $AESASM_aarch64=\\
        aes_core.c aes_cbc.c aesv8-armx.S aesv8-armx-sve2.S \\
        bsaes-armv8.S vpaes-armv8.S aes-sha1-armv8.S \\
        aes-sha256-armv8.S aes-sha512-armv8.S
""",
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
insert_after(
    aes_platform,
    """#define HWAES_xts_encrypt aes_v8_xts_encrypt
#define HWAES_xts_decrypt aes_v8_xts_decrypt
""",
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
)

xts_hw = root / "providers/implementations/ciphers/cipher_aes_xts_hw.c"
insert_after(
    xts_hw,
    """#ifdef HWAES_xts_decrypt
        stream_dec = HWAES_xts_decrypt;
#endif /* HWAES_xts_decrypt */
""",
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
)
PY
