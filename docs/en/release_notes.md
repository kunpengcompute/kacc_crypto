# Release Notes

<!-- md-trans-meta sourceCommit=0ec0da89a39ac267eb2a0479fa4844cc52cc6637 translatedAt=2026-09-02T03:39:13.076Z pushedAt=2026-09-03T00:40:29.440Z -->

## Version Requirements

### Product Versions

<a name="table62675726"></a>

<table><tbody><tr id="row41561572"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.1.1"><p id="p11044137"><a name="p11044137"></a><a name="p11044137"></a>Product Name</p></th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.1.1 "><p id="p1597721693713"><a name="p1597721693713"></a><a name="p1597721693713"></a>Kunpeng BoostKit</p></td>
</tr>
<tr id="row24726251"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.2.1"><p id="p56669300"><a name="p56669300"></a><a name="p56669300"></a>Product Version</p></th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.2.1 "><p id="p11923034"><a name="p11923034"></a><a name="p11923034"></a><span id="text14311218114"><a name="text14311218114"></a><a name="text14311218114"></a>26.2.RC1</span></p></td>
</tr>
<tr id="row1930811171892"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.3.1"><p id="p2030912172097"><a name="p2030912172097"></a><a name="p2030912172097"></a>Software Name</p></th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.3.1 "><p id="p1730912179911"><a name="p1730912179911"></a><a name="p1730912179911"></a><span id="text17191017111119"><a name="text17191017111119"></a><a name="text17191017111119"></a>KACC_Crypto</span></p></td>
</tr>
<tr id="row19308111718"><th class="firstcol" valign="top" width="42.17%" id="mcps1.1.3.3.1"><p id="p2030912172097"><a name="p2030912172097"></a><a name="p2030912172097"></a>Software Version</p></th>
<td class="cellrowborder" valign="top" width="57.830000000000005%" headers="mcps1.1.3.3.1 "><p id="p1730912179911"><a name="p1730912179911"></a><a name="p1730912179911"></a><span id="text17191017111119"><a name="text17191017111119"></a><a name="text17191017111119"></a>V1.1.0</span></p></td>
</tr>
</tbody>
</table>

### Hardware Versions

| Item | Description |
| --- | --- |
| Processor | Kunpeng 950 |
| Architecture | AArch64 |
| Acceleration capabilities | SVE2 AES, SVE2, PMULL, and Armv8 AES |
| External accelerator device | No external accelerator cards required |

### OS Version

| Software Version | OS | Dependency Version |
| --- | --- | --- |
| V1.1.0 | AArch64 Linux | OpenSSL 3.0.16 source tree, GCC/Clang, make, perl |

> ![icon note](public_sys-resources/icon-note.gif) **Note:**
>
>- The actual applicable scope depends on whether the integration script matches the target OpenSSL source anchors and whether the target machine supports the corresponding instruction capabilities.
>- OpenSSL versions and OSs not on the list require separate verification.

## Important Notes

- The current AES-XTS hot path is tuned for machines with an SVE vector length of 256 bits. Machines with other vector lengths require separate verification.
- AES-GCM enters the SVE2 path only for input lengths of 8,192 bytes and more. The Armv8/NEON path is intentionally retained for small packets.
- The AES-GCM provider context caches `pairtab[1024]` to reduce repeated GHASH precomputation overhead in large requests.
- RSA is currently verified through an independent benchmark for RSA2048/RSA4096 private-key CRT mathematical operations. It is not transparently dispatched through the public OpenSSL RSA APIs.
- The integration scripts modify OpenSSL files at source anchors. The anchor points may need to be adjusted when the target OpenSSL version differs significantly.

## V1.1.0

### Change Description

**New Features**

| Feature | Change Description |
| --- | --- |
| AES-XTS | Added an AArch64 SVE2 AES-XTS stream implementation, covering AES-128/192/256 XTS encryption and decryption. |
| AES-GCM | Added an SVE2 AES-CTR and GHASH fused computation path for large input lengths, supporting AES-128/192/256 GCM encryption and decryption. |
| RSA | Added SVE2 x8 Montgomery multiply, square, and gather kernels, and provided RSA2048/RSA4096 benchmarks. |

**Modified Features**

| Feature | Change Description |
| --- | --- |
| AES-GCM | Updated the SVE2 GCM API to use the precomputed `pairtab` and manage the cache lifecycle in the provider context. |
| AES-GCM | Added kernel selection for AES-128/AES-256 decryption with 16KB-level prefetching. |
| RSA | Parameterized the RSA benchmark to support RSA2048 and RSA4096 key sizes. |
| RSA | Added the `RSA_BENCH_BITS=2048\|4096` parameter to `apply_and_test_rsa.sh`. |
| RSA | Added the `RSA_BENCH_LINK=auto\|static\|shared` and `OPENSSL_LIB` parameters to `apply_and_test_rsa.sh` to support linking against the OpenSSL dynamic library. |

**Removed Features**

None

### Resolved Issues

None

### Known Issues

| Trouble Ticket No. | Symptom | Impact Scope | Workaround |
| --- | --- | --- | --- |
| NA-001 | The AES-XTS hot path is not a generic implementation of variable vector lengths. | Machines with non-256-bit SVE vector lengths | Use the open-source path in unverified environments or provide a dedicated implementation for the target vector length. |
| NA-002 | RSA is currently verified through an independent benchmark. | Scenarios where applications call the OpenSSL RSA APIs | Enable transparent optimization after adding OpenSSL internal dispatch or batch interfaces. |
| NA-003 | The integration scripts depend on source anchors in OpenSSL. | OpenSSL source trees that differ significantly from the verified version | Use a matching version or manually adapt the scripts based on the anchors reported in the error messages. |

## Related Documentation

### V1.1.0 Documentation

| Document Name | Description |
| --- | --- |
| Quick Start | Describes how to quickly complete source code acquisition, OpenSSL build, optimized code integration, and basic verification. |
| Installation Guide | Describes environment requirements, and the steps of integrating, compiling, and testing the AES-XTS, AES-GCM, and RSA optimization algorithms. |
| User Guide | Describes the entry points, parameters, and verification methods for AES-XTS, AES-GCM, and RSA optimization. |
| Release Notes | Describes the version mapping, capability scope, precautions, and known issues of KACC_Crypto. |

### Obtaining Documentation

Visit the [open-source repository](https://gitcode.com/boostkit/kacc_crypto) to view or download related documents.
