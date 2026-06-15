// Fixed-VL=256 SVE2 radix29 x8 fused Montgomery AMM kernels.
//
// These kernels are the retained RSA2048 private CRT multi-buffer candidate:
// eight independent 1024-bit CRT branches are represented as 29-bit digits in
// SVE2 lanes, using delayed carry and fused Montgomery reduction.  Earlier
// radix32/radix52/native64 probes are intentionally not included in this
// product overlay.
//
// ABI:
//   x0 = out SoA uint32_t[36][8]
//   x1 = a   SoA uint32_t[36][8]
//   x2 = b   SoA uint32_t[36][8]
//   x3 = m   SoA uint32_t[36][8]
//   x4 = n0_b uint64_t[4] for lanes 0/2/4/6
//   x5 = n0_t uint64_t[4] for lanes 1/3/5/7
//
// Shape:
//   T is stored as two redundant uint64_t[96][4] arrays on the stack.
//   t_b holds lanes 0/2/4/6; t_t holds lanes 1/3/5/7.
//   The Montgomery schedule is fused:
//     T += A * b[i]
//     q = low29(T[i]) * n0 mod 2^29
//     T += q * M
//     T[i + 1] += T[i] >> 29
//   Carry propagation is delayed until the final output normalize.

    .text
    .arch armv8.6-a+sve2
    .align  4
    .global amm29_fused_lazy_sve2_x8_handasm
    .type   amm29_fused_lazy_sve2_x8_handasm, %function

    .macro PROD_STEP idx
    ld1d    {z1.d}, p0/z, [x9, #\idx, mul vl]
    ld1d    {z0.d}, p0/z, [x10, #\idx, mul vl]
    ld1w    {z2.s}, p0/z, [x8, #\idx, mul vl]
    umlalb  z1.d, z2.s, z6.s
    umlalt  z0.d, z2.s, z6.s
    st1d    {z1.d}, p0, [x9, #\idx, mul vl]
    st1d    {z0.d}, p0, [x10, #\idx, mul vl]
    .endm

    .macro PROD_STEP_X2 idx0, idx1
    ld1d    {z1.d}, p0/z, [x9, #\idx0, mul vl]
    ld1d    {z0.d}, p0/z, [x10, #\idx0, mul vl]
    ld1d    {z3.d}, p0/z, [x9, #\idx1, mul vl]
    ld1d    {z4.d}, p0/z, [x10, #\idx1, mul vl]
    ld1w    {z2.s}, p0/z, [x8, #\idx0, mul vl]
    ld1w    {z5.s}, p0/z, [x8, #\idx1, mul vl]
    umlalb  z1.d, z2.s, z6.s
    umlalt  z0.d, z2.s, z6.s
    umlalb  z3.d, z5.s, z6.s
    umlalt  z4.d, z5.s, z6.s
    st1d    {z1.d}, p0, [x9, #\idx0, mul vl]
    st1d    {z0.d}, p0, [x10, #\idx0, mul vl]
    st1d    {z3.d}, p0, [x9, #\idx1, mul vl]
    st1d    {z4.d}, p0, [x10, #\idx1, mul vl]
    .endm

    .macro RED_STEP idx
    ld1d    {z1.d}, p0/z, [x9, #\idx, mul vl]
    ld1d    {z0.d}, p0/z, [x10, #\idx, mul vl]
    ld1w    {z2.s}, p0/z, [x8, #\idx, mul vl]
    umlalb  z1.d, z2.s, z5.s
    umlalt  z0.d, z2.s, z5.s
    st1d    {z1.d}, p0, [x9, #\idx, mul vl]
    st1d    {z0.d}, p0, [x10, #\idx, mul vl]
    .endm

    .macro RED_STEP_X2 idx0, idx1
    ld1d    {z1.d}, p0/z, [x9, #\idx0, mul vl]
    ld1d    {z0.d}, p0/z, [x10, #\idx0, mul vl]
    ld1d    {z3.d}, p0/z, [x9, #\idx1, mul vl]
    ld1d    {z4.d}, p0/z, [x10, #\idx1, mul vl]
    ld1w    {z2.s}, p0/z, [x8, #\idx0, mul vl]
    ld1w    {z7.s}, p0/z, [x8, #\idx1, mul vl]
    umlalb  z1.d, z2.s, z5.s
    umlalt  z0.d, z2.s, z5.s
    umlalb  z3.d, z7.s, z5.s
    umlalt  z4.d, z7.s, z5.s
    st1d    {z1.d}, p0, [x9, #\idx0, mul vl]
    st1d    {z0.d}, p0, [x10, #\idx0, mul vl]
    st1d    {z3.d}, p0, [x9, #\idx1, mul vl]
    st1d    {z4.d}, p0, [x10, #\idx1, mul vl]
    .endm

    .macro PROD8
    PROD_STEP_X2 0, 1
    PROD_STEP_X2 2, 3
    PROD_STEP_X2 4, 5
    PROD_STEP_X2 6, 7
    .endm

    .macro RED8
    RED_STEP_X2 0, 1
    RED_STEP_X2 2, 3
    RED_STEP_X2 4, 5
    RED_STEP_X2 6, 7
    .endm

amm29_fused_lazy_sve2_x8_handasm:
    sub     sp, sp, #0x1000
    sub     sp, sp, #0x300
    stp     x29, x30, [sp]
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    ptrue   p0.b, all
    mov     x21, x0                     // out
    mov     x22, x1                     // a
    mov     x23, x2                     // b
    mov     x24, x3                     // m
    mov     x25, #32                    // SoA slot stride

    add     x19, sp, #0x80
    add     x19, x19, #0x3f
    and     x19, x19, #0xffffffffffffffc0
    add     x20, x19, #0x900            // t_t = t_b + 72 * 32

    mov     x26, x4                     // n0_b
    mov     x28, x5                     // n0_t

    // Clear contiguous t_b/t_t.  The libc memset path uses target-tuned ZVA.
    mov     x0, x19
    mov     w1, #0
    mov     x2, #0x1200
    bl      memset

    ptrue   p0.b, all

    // Pack n0_b/n0_t into 8 32-bit lanes: [b0,t0,b1,t1,...].
    ld1d    {z30.d}, p0/z, [x26]
    ld1d    {z31.d}, p0/z, [x28]
    uzp1    z30.s, z30.s, z30.s
    uzp1    z31.s, z31.s, z31.s
    zip1    z29.s, z30.s, z31.s

    mov     x27, x23                    // b[i]
    mov     x14, x19                    // &t_b[i]
    mov     x15, x20                    // &t_t[i]
    mov     w28, #36

    .p2align 3
.Louter29:
    ld1w    {z6.s}, p0/z, [x27]         // b[i]

    // Product contribution: T[i+j] += a[j] * b[i].
    mov     x8, x22                     // a[j]
    mov     x9, x14                     // t_b[i+j]
    mov     x10, x15                    // t_t[i+j]
    PROD8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    PROD8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    PROD8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    PROD8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    PROD_STEP_X2 0, 1
    PROD_STEP_X2 2, 3

    // q = low29(T[i]) * n0 mod 2^29.
    ld1d    {z1.d}, p0/z, [x14]         // bottom lanes
    ld1d    {z0.d}, p0/z, [x15]         // top lanes
    movprfx z2, z1
    and     z2.d, z2.d, #0x1fffffff
    movprfx z3, z0
    and     z3.d, z3.d, #0x1fffffff
    uzp1    z2.s, z2.s, z2.s
    uzp1    z3.s, z3.s, z3.s
    zip1    z5.s, z2.s, z3.s
    mul     z5.s, p0/m, z5.s, z29.s
    and     z5.s, z5.s, #0x1fffffff

    // Reduction contribution: T[i+j] += m[j] * q.
    mov     x8, x24                     // m[j]
    mov     x9, x14
    mov     x10, x15
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED_STEP_X2 0, 1
    RED_STEP_X2 2, 3

    // Drop T[i] and inject its high part into T[i+1].
    ld1d    {z1.d}, p0/z, [x14]
    ld1d    {z0.d}, p0/z, [x15]
    add     x9, x14, #32
    add     x10, x15, #32
    ld1d    {z2.d}, p0/z, [x9]
    ld1d    {z3.d}, p0/z, [x10]
    usra    z2.d, z1.d, #29
    usra    z3.d, z0.d, #29
    st1d    {z2.d}, p0, [x9]
    st1d    {z3.d}, p0, [x10]

    add     x27, x27, #32
    add     x14, x14, #32
    add     x15, x15, #32
    subs    w28, w28, #1
    b.ne    .Louter29

    // Final normalize and pack t[36..71] to out.
    add     x14, x19, #0x480            // 36 * 32
    add     x15, x20, #0x480
    mov     x16, x21
    mov     z6.d, #0                    // carry_b
    mov     z7.d, #0                    // carry_t
    mov     w28, #36

    .p2align 3
.Lout29:
    ld1d    {z1.d}, p0/z, [x14]
    ld1d    {z0.d}, p0/z, [x15]
    add     z1.d, z1.d, z6.d
    add     z0.d, z0.d, z7.d
    movprfx z2, z1
    and     z2.d, z2.d, #0x1fffffff
    movprfx z3, z0
    and     z3.d, z3.d, #0x1fffffff
    uzp1    z2.s, z2.s, z2.s
    uzp1    z3.s, z3.s, z3.s
    zip1    z2.s, z2.s, z3.s
    st1w    {z2.s}, p0, [x16]
    lsr     z6.d, z1.d, #29
    lsr     z7.d, z0.d, #29
    add     x14, x14, #32
    add     x15, x15, #32
    add     x16, x16, #32
    subs    w28, w28, #1
    b.ne    .Lout29

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp]
    add     sp, sp, #0x300
    add     sp, sp, #0x1000
    ret

    .size amm29_fused_lazy_sve2_x8_handasm, .-amm29_fused_lazy_sve2_x8_handasm

    .align  4
    .global amm29_fused_sqr_lazy_sve2_x8_handasm
    .type   amm29_fused_sqr_lazy_sve2_x8_handasm, %function

// ABI:
//   x0 = out SoA uint32_t[36][8]
//   x1 = a   SoA uint32_t[36][8]
//   x2 = m   SoA uint32_t[36][8]
//   x3 = n0_b uint64_t[4]
//   x4 = n0_t uint64_t[4]
amm29_fused_sqr_lazy_sve2_x8_handasm:
    sub     sp, sp, #0x1000
    sub     sp, sp, #0x300
    stp     x29, x30, [sp]
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    ptrue   p0.b, all
    mov     x21, x0                     // out
    mov     x22, x1                     // a
    mov     x24, x2                     // m
    mov     x26, x3                     // n0_b
    mov     x28, x4                     // n0_t

    add     x19, sp, #0x80
    add     x19, x19, #0x3f
    and     x19, x19, #0xffffffffffffffc0
    add     x20, x19, #0x900            // t_t = t_b + 72 * 32

    mov     x0, x19
    mov     w1, #0
    mov     x2, #0x1200
    bl      memset

    ptrue   p0.b, all

    ld1d    {z30.d}, p0/z, [x26]
    ld1d    {z31.d}, p0/z, [x28]
    uzp1    z30.s, z30.s, z30.s
    uzp1    z31.s, z31.s, z31.s
    zip1    z29.s, z30.s, z31.s

    mov     x27, x22                    // a[i]
    mov     x14, x19                    // &t_b[i]
    mov     x15, x20                    // &t_t[i]
    mov     x12, x19                    // &t_b[2*i]
    mov     x13, x20                    // &t_t[2*i]
    mov     w28, #36                    // outer countdown
    mov     w25, #35                    // cross countdown = 35 - i

    .p2align 3
.Lsqr_outer29:
    ld1w    {z6.s}, p0/z, [x27]         // a[i]

    // Diagonal term: T[2*i] += a[i] * a[i].
    ld1d    {z1.d}, p0/z, [x12]
    ld1d    {z0.d}, p0/z, [x13]
    umlalb  z1.d, z6.s, z6.s
    umlalt  z0.d, z6.s, z6.s
    st1d    {z1.d}, p0, [x12]
    st1d    {z0.d}, p0, [x13]

    cbz     w25, .Lsqr_after_product29

    // Cross terms: for j>i, T[i+j] += 2 * a[i] * a[j].
    add     x8, x27, #32                // a[j]
    add     x9, x12, #32                // t_b[i+j]
    add     x10, x13, #32               // t_t[i+j]
    mov     w11, w25
    lsr     w7, w11, #1
    cbz     w7, .Lsqr_cross_tail29
    .p2align 3
.Lsqr_cross2_29:
    ld1w    {z2.s}, p0/z, [x8]
    lsl     z2.s, z2.s, #1
    ld1d    {z1.d}, p0/z, [x9]
    ld1d    {z0.d}, p0/z, [x10]
    umlalb  z1.d, z6.s, z2.s
    umlalt  z0.d, z6.s, z2.s
    st1d    {z1.d}, p0, [x9]
    st1d    {z0.d}, p0, [x10]

    ld1w    {z16.s}, p0/z, [x8, #1, mul vl]
    lsl     z16.s, z16.s, #1
    ld1d    {z19.d}, p0/z, [x9, #1, mul vl]
    ld1d    {z20.d}, p0/z, [x10, #1, mul vl]
    umlalb  z19.d, z6.s, z16.s
    umlalt  z20.d, z6.s, z16.s
    st1d    {z19.d}, p0, [x9, #1, mul vl]
    st1d    {z20.d}, p0, [x10, #1, mul vl]

    add     x8, x8, #64
    add     x9, x9, #64
    add     x10, x10, #64
    subs    w7, w7, #1
    b.ne    .Lsqr_cross2_29

.Lsqr_cross_tail29:
    tbz     w11, #0, .Lsqr_after_product29
    ld1w    {z2.s}, p0/z, [x8]
    lsl     z2.s, z2.s, #1
    ld1d    {z1.d}, p0/z, [x9]
    ld1d    {z0.d}, p0/z, [x10]
    umlalb  z1.d, z6.s, z2.s
    umlalt  z0.d, z6.s, z2.s
    st1d    {z1.d}, p0, [x9]
    st1d    {z0.d}, p0, [x10]

.Lsqr_after_product29:
    // q = low29(T[i]) * n0 mod 2^29.
    ld1d    {z1.d}, p0/z, [x14]
    ld1d    {z0.d}, p0/z, [x15]
    movprfx z2, z1
    and     z2.d, z2.d, #0x1fffffff
    movprfx z3, z0
    and     z3.d, z3.d, #0x1fffffff
    uzp1    z2.s, z2.s, z2.s
    uzp1    z3.s, z3.s, z3.s
    zip1    z5.s, z2.s, z3.s
    mul     z5.s, p0/m, z5.s, z29.s
    and     z5.s, z5.s, #0x1fffffff

    // Fixed 36-step reduction contribution: T[i+j] += m[j] * q.
    mov     x8, x24
    mov     x9, x14
    mov     x10, x15
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED8
    add     x8, x8, #0x100
    add     x9, x9, #0x100
    add     x10, x10, #0x100
    RED_STEP_X2 0, 1
    RED_STEP_X2 2, 3

    // Drop T[i] and inject high part into T[i+1].
    ld1d    {z1.d}, p0/z, [x14]
    ld1d    {z0.d}, p0/z, [x15]
    add     x9, x14, #32
    add     x10, x15, #32
    ld1d    {z2.d}, p0/z, [x9]
    ld1d    {z3.d}, p0/z, [x10]
    usra    z2.d, z1.d, #29
    usra    z3.d, z0.d, #29
    st1d    {z2.d}, p0, [x9]
    st1d    {z3.d}, p0, [x10]

    add     x27, x27, #32
    add     x14, x14, #32
    add     x15, x15, #32
    add     x12, x12, #64
    add     x13, x13, #64
    sub     w25, w25, #1
    subs    w28, w28, #1
    b.ne    .Lsqr_outer29

    // Final normalize and pack t[36..71] to out.
    add     x14, x19, #0x480
    add     x15, x20, #0x480
    mov     x16, x21
    mov     z6.d, #0
    mov     z7.d, #0
    mov     w28, #36

    .p2align 3
.Lsqr_out29:
    ld1d    {z1.d}, p0/z, [x14]
    ld1d    {z0.d}, p0/z, [x15]
    add     z1.d, z1.d, z6.d
    add     z0.d, z0.d, z7.d
    movprfx z2, z1
    and     z2.d, z2.d, #0x1fffffff
    movprfx z3, z0
    and     z3.d, z3.d, #0x1fffffff
    uzp1    z2.s, z2.s, z2.s
    uzp1    z3.s, z3.s, z3.s
    zip1    z2.s, z2.s, z3.s
    st1w    {z2.s}, p0, [x16]
    lsr     z6.d, z1.d, #29
    lsr     z7.d, z0.d, #29
    add     x14, x14, #32
    add     x15, x15, #32
    add     x16, x16, #32
    subs    w28, w28, #1
    b.ne    .Lsqr_out29

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp]
    add     sp, sp, #0x300
    add     sp, sp, #0x1000
    ret

    .size amm29_fused_sqr_lazy_sve2_x8_handasm, .-amm29_fused_sqr_lazy_sve2_x8_handasm

    .align  4
    .global ct_gather_red29_soa_sve_handasm
    .type   ct_gather_red29_soa_sve_handasm, %function

// ABI:
//   x0 = out   SoA uint32_t[36][8]
//   x1 = table uint32_t[32][36][8]
//   w2 = selected table index
ct_gather_red29_soa_sve_handasm:
    ptrue   p0.s, all
    mov     w3, #0                      // entry
    mov     x4, x1                      // current table entry

    .p2align 3
.Lgather_entry:
    eor     w5, w2, w3
    cmp     w5, #0
    csetm   w5, eq
    mov     z31.s, w5
    mov     x6, x0                      // out block pointer
    mov     x7, x4                      // source block pointer
    mov     w8, #9                      // 9 * 4 vectors = 36 limbs
    cbnz    w3, .Lgather_or_loop

    .p2align 3
.Lgather_init_loop:
    ld1w    {z0.s}, p0/z, [x7]
    ld1w    {z1.s}, p0/z, [x7, #1, mul vl]
    ld1w    {z2.s}, p0/z, [x7, #2, mul vl]
    ld1w    {z3.s}, p0/z, [x7, #3, mul vl]
    and     z0.d, z0.d, z31.d
    and     z1.d, z1.d, z31.d
    and     z2.d, z2.d, z31.d
    and     z3.d, z3.d, z31.d
    st1w    {z0.s}, p0, [x6]
    st1w    {z1.s}, p0, [x6, #1, mul vl]
    st1w    {z2.s}, p0, [x6, #2, mul vl]
    st1w    {z3.s}, p0, [x6, #3, mul vl]
    addvl   x7, x7, #4
    addvl   x6, x6, #4
    subs    w8, w8, #1
    b.ne    .Lgather_init_loop
    b       .Lgather_next_entry

    .p2align 3
.Lgather_or_loop:
    ld1w    {z0.s}, p0/z, [x6]
    ld1w    {z1.s}, p0/z, [x6, #1, mul vl]
    ld1w    {z2.s}, p0/z, [x6, #2, mul vl]
    ld1w    {z3.s}, p0/z, [x6, #3, mul vl]
    ld1w    {z4.s}, p0/z, [x7]
    ld1w    {z5.s}, p0/z, [x7, #1, mul vl]
    ld1w    {z6.s}, p0/z, [x7, #2, mul vl]
    ld1w    {z7.s}, p0/z, [x7, #3, mul vl]
    and     z4.d, z4.d, z31.d
    and     z5.d, z5.d, z31.d
    and     z6.d, z6.d, z31.d
    and     z7.d, z7.d, z31.d
    orr     z0.d, z0.d, z4.d
    orr     z1.d, z1.d, z5.d
    orr     z2.d, z2.d, z6.d
    orr     z3.d, z3.d, z7.d
    st1w    {z0.s}, p0, [x6]
    st1w    {z1.s}, p0, [x6, #1, mul vl]
    st1w    {z2.s}, p0, [x6, #2, mul vl]
    st1w    {z3.s}, p0, [x6, #3, mul vl]
    addvl   x7, x7, #4
    addvl   x6, x6, #4
    subs    w8, w8, #1
    b.ne    .Lgather_or_loop

.Lgather_next_entry:
    add     x4, x4, #0x480              // 36 * 8 * sizeof(uint32_t)
    add     w3, w3, #1
    cmp     w3, #32
    b.ne    .Lgather_entry
    ret

    .size ct_gather_red29_soa_sve_handasm, .-ct_gather_red29_soa_sve_handasm
