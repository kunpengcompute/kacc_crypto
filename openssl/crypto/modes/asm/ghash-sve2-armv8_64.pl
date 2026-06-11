#! /usr/bin/env perl
# Copyright 2026 The OpenSSL Project Authors. All Rights Reserved.
#
# Licensed under the Apache License 2.0 (the "License").  You may not use
# this file except in compliance with the License.  You can obtain a copy
# in the file LICENSE in the source distribution or at
# https://www.openssl.org/source/license.html

use strict;
use warnings;

my $output = $#ARGV >= 0 && $ARGV[$#ARGV] =~ m|\.\w+$| ? pop : undef;
my $flavour = $#ARGV >= 0 && $ARGV[0] !~ m|\.| ? shift : undef;

$0 =~ m/(.*[\/\\])[^\/\\]+$/;
my $dir = $1 || "./";
my $xlate;

foreach ("${dir}arm-xlate.pl", "${dir}../../perlasm/arm-xlate.pl") {
    if (-f $_) {
        $xlate = $_;
        last;
    }
}
die "can't locate arm-xlate.pl" if !$xlate;

open OUT, "| \"$^X\" $xlate $flavour \"$output\""
    or die "can't call $xlate: $!";
*STDOUT = *OUT;

sub load_idx {
    my ($label, $reg) = @_;

    return <<___;
    adrp    x4, $label
    add     x4, x4, :lo12:$label
    ld1d    {$reg.d}, p0/z, [x4]
___
}

sub save_zregs {
    my $ret = <<___;
    addvl   sp, sp, #-8
    st1b    {z8.b},  p0, [sp]
    st1b    {z9.b},  p0, [sp, #1, mul vl]
    st1b    {z10.b}, p0, [sp, #2, mul vl]
    st1b    {z11.b}, p0, [sp, #3, mul vl]
    st1b    {z12.b}, p0, [sp, #4, mul vl]
    st1b    {z13.b}, p0, [sp, #5, mul vl]
    st1b    {z14.b}, p0, [sp, #6, mul vl]
    st1b    {z15.b}, p0, [sp, #7, mul vl]
___
    return $ret;
}

sub restore_zregs {
    my $ret = <<___;
    ptrue   p0.b
    ld1b    {z8.b},  p0/z, [sp]
    ld1b    {z9.b},  p0/z, [sp, #1, mul vl]
    ld1b    {z10.b}, p0/z, [sp, #2, mul vl]
    ld1b    {z11.b}, p0/z, [sp, #3, mul vl]
    ld1b    {z12.b}, p0/z, [sp, #4, mul vl]
    ld1b    {z13.b}, p0/z, [sp, #5, mul vl]
    ld1b    {z14.b}, p0/z, [sp, #6, mul vl]
    ld1b    {z15.b}, p0/z, [sp, #7, mul vl]
    addvl   sp, sp, #8
___
    return $ret;
}
sub reduce_acc_stage_eor3_custom {
    my ($stage, $xl, $xm, $xh, $xc2, $idx_swap, $idx_lh, $idx_xh, $idx_xm) = @_;
    my $ret = "";

    if ($stage >= 1) {
        $ret .= <<___;
    mov     z24.d, $xl.d
    mov     z25.d, $xh.d
    tbl     z26.d, {z24.d, z25.d}, $idx_lh.d
    eor     z27.d, $xl.d, $xh.d
    eor3    $xm.d, $xm.d, z26.d, z27.d
___
    }
    if ($stage >= 2) {
        $ret .= <<___;
    pmullb  z26.q, $xl.d, $xc2.d
    mov     z24.d, $xm.d
    mov     z25.d, $xh.d
    tbl     $xh.d, {z24.d, z25.d}, $idx_xh.d
    mov     z24.d, $xm.d
    mov     z25.d, $xl.d
    tbl     $xm.d, {z24.d, z25.d}, $idx_xm.d
    eor     $xl.d, $xm.d, z26.d
___
    }
    if ($stage >= 3) {
        $ret .= <<___;
    tbl     z26.d, {$xl.d}, $idx_swap.d
    pmullb  $xl.q, $xl.d, $xc2.d
    eor3    $xl.d, $xl.d, z26.d, $xh.d
    tbl     $xl.d, {$xl.d}, $idx_swap.d
___
    }
    return $ret;
}
sub aes128_encrypt_4z {
    my ($z0, $z1, $z2, $z3, $consume, $final_xor, $before_final) = @_;
    my $ret = "";
    $final_xor = 1 if !defined($final_xor);

    for (my $r = 0; $r < 9; $r++) {
        my $rk = "z" . (8 + $r);
        $ret .= <<___;
    aese    $z0.b, $z0.b, $rk.b
    aesmc   $z0.b, $z0.b
___
        $ret .= $consume->($r, "after_aesmc0") if defined($consume);
        $ret .= <<___;
    aese    $z1.b, $z1.b, $rk.b
    aesmc   $z1.b, $z1.b
___
        $ret .= $consume->($r, "after_aesmc1") if defined($consume);
        $ret .= <<___;
    aese    $z2.b, $z2.b, $rk.b
    aesmc   $z2.b, $z2.b
___
        $ret .= $consume->($r, "after_aesmc2") if defined($consume);
        $ret .= <<___;
    aese    $z3.b, $z3.b, $rk.b
    aesmc   $z3.b, $z3.b
___
        $ret .= $consume->($r, "after_aesmc3") if defined($consume);
    }

    $ret .= $before_final->() if defined($before_final);
    $ret .= <<___;
    aese    $z0.b, $z0.b, z17.b
    aese    $z1.b, $z1.b, z17.b
    aese    $z2.b, $z2.b, z17.b
    aese    $z3.b, $z3.b, z17.b
___
    if ($final_xor) {
        $ret .= <<___;
    eor     $z0.d, $z0.d, z18.d
    eor     $z1.d, $z1.d, z18.d
    eor     $z2.d, $z2.d, z18.d
    eor     $z3.d, $z3.d, z18.d
___
    }

    return $ret;
}

sub load_aes_round_key_z {
    my ($zreg, $off) = @_;
    return <<___;
    mov     x7, #$off
    ld1rqb  {$zreg.b}, p0/z, [x9, x7]
___
}

sub aes_encrypt_4z_rounds {
    my ($z0, $z1, $z2, $z3, $rounds, $consume, $final_xor, $before_final) = @_;
    my $ret = "";
    $final_xor = 1 if !defined($final_xor);
    my $final_round_key = "z5";
    my $final_xor_key = "z6";

    return aes128_encrypt_4z($z0, $z1, $z2, $z3, $consume, $final_xor,
                             $before_final)
        if $rounds == 10;

    for (my $r = 0; $r < 9; $r++) {
        my $rk = "z" . (8 + $r);
        $ret .= <<___;
    aese    $z0.b, $z0.b, $rk.b
    aesmc   $z0.b, $z0.b
___
        $ret .= $consume->($r, "after_aesmc0") if defined($consume);
        $ret .= <<___;
    aese    $z1.b, $z1.b, $rk.b
    aesmc   $z1.b, $z1.b
___
        $ret .= $consume->($r, "after_aesmc1") if defined($consume);
        $ret .= <<___;
    aese    $z2.b, $z2.b, $rk.b
    aesmc   $z2.b, $z2.b
___
        $ret .= $consume->($r, "after_aesmc2") if defined($consume);
        $ret .= <<___;
    aese    $z3.b, $z3.b, $rk.b
    aesmc   $z3.b, $z3.b
___
        $ret .= $consume->($r, "after_aesmc3") if defined($consume);
    }

    for (my $r = 9; $r < $rounds - 1; $r++) {
        my $rk;
        if ($r == 9) {
            $rk = "z17";
        } elsif ($r == 10) {
            $rk = "z18";
        } elsif ($rounds == 14 && $r == 11) {
            $rk = "z19";
        } elsif ($rounds == 14 && $r == 12) {
            $rk = "z20";
        } else {
            $rk = "z27";
            $ret .= load_aes_round_key_z($rk, $r * 16);
        }
        $ret .= <<___;
    aese    $z0.b, $z0.b, $rk.b
    aesmc   $z0.b, $z0.b
___
        $ret .= $consume->($r, "after_aesmc0") if defined($consume);
        $ret .= <<___;
    aese    $z1.b, $z1.b, $rk.b
    aesmc   $z1.b, $z1.b
___
        $ret .= $consume->($r, "after_aesmc1") if defined($consume);
        $ret .= <<___;
    aese    $z2.b, $z2.b, $rk.b
    aesmc   $z2.b, $z2.b
___
        $ret .= $consume->($r, "after_aesmc2") if defined($consume);
        $ret .= <<___;
    aese    $z3.b, $z3.b, $rk.b
    aesmc   $z3.b, $z3.b
___
        $ret .= $consume->($r, "after_aesmc3") if defined($consume);
    }

    $ret .= $before_final->() if defined($before_final);
    $ret .= <<___;
    aese    $z0.b, $z0.b, $final_round_key.b
    aese    $z1.b, $z1.b, $final_round_key.b
    aese    $z2.b, $z2.b, $final_round_key.b
    aese    $z3.b, $z3.b, $final_round_key.b
___
    if ($final_xor) {
        $ret .= <<___;
    eor     $z0.d, $z0.d, $final_xor_key.d
    eor     $z1.d, $z1.d, $final_xor_key.d
    eor     $z2.d, $z2.d, $final_xor_key.d
    eor     $z3.d, $z3.d, $final_xor_key.d
___
    }

    return $ret;
}
sub make_ctr8_regs_fused {
    my $ret = "";
    my @regs = ("z0", "z1", "z2", "z3");
    my @offs = (0, 2, 4, 6);

    $ret .= "    mov     z27.b, #0\n";
    for (my $i = 0; $i < 4; $i++) {
        my $reg = $regs[$i];
        my $off = $offs[$i];
        if ($off == 0) {
            $ret .= "    mov     z22.s, w8\n";
        } else {
            $ret .= "    add     w7, w8, #$off\n";
            $ret .= "    mov     z22.s, w7\n";
        }
        $ret .= <<___;
    add     $reg.s, z20.s, z22.s
    revb    $reg.s, p0/m, $reg.s
    sel     $reg.s, p1, $reg.s, z27.s
    orr     $reg.d, z19.d, $reg.d
___
    }

    $ret .= "    add     w8, w8, #8\n";
    return $ret;
}
sub ghash_hpow512_pairtab_accum2_z {
    my ($zreg0, $zreg1, $label, $with_xi, $xi_cmp) = @_;
    $xi_cmp = 32 if !defined($xi_cmp);
    my $ret = <<___;
    ld1d    {z24.d}, p0/z, [x14]
    ld1d    {z25.d}, p0/z, [x14, #1, mul vl]
    revb    $zreg0.d, p0/m, $zreg0.d
___
    if ($with_xi) {
        $ret .= <<___;
    cmp     x17, #$xi_cmp
    b.ne    .L${label}_noxi
    eor     $zreg0.d, $zreg0.d, z31.d
.L${label}_noxi:
___
    }
    $ret .= <<___;
    tbl     $zreg0.d, {$zreg0.d}, z4.d
    tbl     z26.d, {$zreg0.d}, z4.d
    eor     z26.d, z26.d, $zreg0.d
    pmullb  z21.q, $zreg0.d, z24.d
    pmullt  z22.q, $zreg0.d, z24.d
    pmullb  z27.q, z26.d, z25.d

    ld1d    {z24.d}, p0/z, [x14, #2, mul vl]
    ld1d    {z25.d}, p0/z, [x14, #3, mul vl]
    revb    $zreg1.d, p0/m, $zreg1.d
    tbl     $zreg1.d, {$zreg1.d}, z4.d
    tbl     z26.d, {$zreg1.d}, z4.d
    eor     z26.d, z26.d, $zreg1.d
    pmullb  z25.q, z26.d, z25.d
    pmullb  z26.q, $zreg1.d, z24.d
    pmullt  z24.q, $zreg1.d, z24.d
    eor3    z28.d, z28.d, z21.d, z26.d
    eor3    z30.d, z30.d, z22.d, z24.d
    eor3    z29.d, z29.d, z27.d, z25.d
    add     x14, x14, #128
___
    return $ret;
}
sub ghash_hpow512_pairtab_accum2_tmpnorm_z {
    my ($zreg0, $zreg1, $label, $with_xi, $xi_cmp) = @_;
    $xi_cmp = 32 if !defined($xi_cmp);
    my $ret = <<___;
    ld1d    {z24.d}, p0/z, [x14]
    ld1d    {z25.d}, p0/z, [x14, #1, mul vl]
    revb    $zreg0.d, p0/m, $zreg0.d
___
    if ($with_xi) {
        $ret .= <<___;
    cmp     x17, #$xi_cmp
    b.ne    .L${label}_noxi
    eor     $zreg0.d, $zreg0.d, z31.d
.L${label}_noxi:
___
    }
    $ret .= <<___;
    tbl     z26.d, {$zreg0.d}, z4.d
    eor     $zreg0.d, $zreg0.d, z26.d
    pmullb  z21.q, z26.d, z24.d
    pmullt  z22.q, z26.d, z24.d
    pmullb  z27.q, $zreg0.d, z25.d

    ld1d    {z24.d}, p0/z, [x14, #2, mul vl]
    ld1d    {z25.d}, p0/z, [x14, #3, mul vl]
    revb    $zreg1.d, p0/m, $zreg1.d
    tbl     z26.d, {$zreg1.d}, z4.d
    eor     $zreg1.d, $zreg1.d, z26.d
    pmullb  z25.q, $zreg1.d, z25.d
    pmullb  z23.q, z26.d, z24.d
    pmullt  z24.q, z26.d, z24.d
    eor3    z28.d, z28.d, z21.d, z23.d
    eor3    z30.d, z30.d, z22.d, z24.d
    eor3    z29.d, z29.d, z27.d, z25.d
    add     x14, x14, #128
___
    return $ret;
}
sub ctr32_ghash_hpow512_pairtab2_eor3_fused_probe {
    my $ret = <<___;

.globl  gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_fused_asm
.type   gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_fused_asm,%function
.align  4
gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_fused_asm:
    AARCH64_VALID_CALL_TARGET
    cntb    x7
    cmp     x7, #32
    b.ne    .Lctrghh512pt2e3_ret0
    cmp     x2, #8192
    b.lo    .Lctrghh512pt2e3_ret0
    ldr     w7, [x4, #240]
    cmp     w7, #10
    b.ne    .Lctrghh512pt2e3_ret0

    ptrue   p0.b, all
    ptrue   p1.s, vl4
    ptrue   p2.d, vl2
___
    $ret .= save_zregs();
    $ret .= <<___;
    mov     x7, #0
    ld1rqb  {z8.b}, p0/z, [x4, x7]
    mov     x7, #16
    ld1rqb  {z9.b}, p0/z, [x4, x7]
    mov     x7, #32
    ld1rqb  {z10.b}, p0/z, [x4, x7]
    mov     x7, #48
    ld1rqb  {z11.b}, p0/z, [x4, x7]
    mov     x7, #64
    ld1rqb  {z12.b}, p0/z, [x4, x7]
    mov     x7, #80
    ld1rqb  {z13.b}, p0/z, [x4, x7]
    mov     x7, #96
    ld1rqb  {z14.b}, p0/z, [x4, x7]
    mov     x7, #112
    ld1rqb  {z15.b}, p0/z, [x4, x7]
    mov     x7, #128
    ld1rqb  {z16.b}, p0/z, [x4, x7]
    mov     x7, #144
    ld1rqb  {z17.b}, p0/z, [x4, x7]
    mov     x7, #160
    ld1rqb  {z18.b}, p0/z, [x4, x7]
___
    $ret .= load_idx(".Lidx_swap", "z4");
    $ret .= load_idx(".Lidx_lh", "z5");
    $ret .= load_idx(".Lidx_xh", "z6");
    $ret .= load_idx(".Lidx_xm", "z7");
    $ret .= <<___;
    mov     x7, #0xc2
    lsl     x7, x7, #56
    dup     z23.d, x7

    movi    v2.4s, #0
    ld1     {v2.s}[0], [x6]
    ldp     s1, s0, [x6, #4]
    ins     v2.s[1], v1.s[0]
    ins     v2.s[2], v0.s[0]
    dup     z19.q, z2.q[0]

    index   z20.s, #0, #1
    movprfx z21, z20
    and     z21.s, z21.s, #0x3
    cmpeq   p1.s, p0/z, z21.s, #3
    lsr     z20.s, z20.s, #2
    mov     z27.b, #0

    ldr     w8, [x6, #12]
    rev     w8, w8

    ld1d    {z31.d}, p2/z, [x3]
    revb    z31.d, p0/m, z31.d

    mov     x10, x0
    mov     x11, x1
    mov     x12, x2
    mov     x13, x5
    mov     x15, #0
    mov     x16, #8192

.Lctrghh512pt2e3_window:
    eor     z28.d, z28.d, z28.d
    eor     z29.d, z29.d, z29.d
    eor     z30.d, z30.d, z30.d
    mov     x14, x13
    mov     x17, #32

.Lctrghh512pt2e3_loop:
___
    $ret .= make_ctr8_regs_fused();
    $ret .= aes128_encrypt_4z("z0", "z1", "z2", "z3", undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $ret .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, z18.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_z("z0", "z1",
                                           "ctrghh512pt2e3_a_0", 1);
    $ret .= ghash_hpow512_pairtab_accum2_z("z2", "z3",
                                           "ctrghh512pt2e3_a_1", 0);
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___
    $ret .= make_ctr8_regs_fused();
    $ret .= aes128_encrypt_4z("z0", "z1", "z2", "z3", undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $ret .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, z18.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_z("z0", "z1",
                                           "ctrghh512pt2e3_b_0", 0);
    $ret .= ghash_hpow512_pairtab_accum2_z("z2", "z3",
                                           "ctrghh512pt2e3_b_1", 0);
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
    subs    x17, x17, #1
    b.ne    .Lctrghh512pt2e3_loop

___
    $ret .= reduce_acc_stage_eor3_custom(3, "z28", "z29", "z30", "z23",
                                         "z4", "z5", "z6", "z7");
    $ret .= <<___;
    mov     z24.d, z28.d
    ext     z24.b, z24.b, z24.b, #16
    eor     z31.d, z28.d, z24.d
    mov     z24.b, #0
    sel     z31.d, p2, z31.d, z24.d

    sub     x12, x12, x16
    cmp     x12, x16
    b.hs    .Lctrghh512pt2e3_window

    mov     z24.d, z31.d
    revb    z24.d, p0/m, z24.d
    st1d    {z24.d}, p2, [x3]
    mov     x0, x15
___
    $ret .= restore_zregs();
    $ret .= <<___;
    ret

.Lctrghh512pt2e3_ret0:
    mov     x0, xzr
    ret
.size   gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_fused_asm,.-gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_fused_asm
___
    return $ret;
}

sub emit_ctrghh512pt2e3_two_batches {
    my ($prefix, $with_xi, $xi_cmp) = @_;
    my $ret = "";

    $ret .= make_ctr8_regs_fused();
    $ret .= aes128_encrypt_4z("z0", "z1", "z2", "z3", undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $ret .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, z18.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_z("z0", "z1",
                                           "${prefix}_a_0", $with_xi,
                                           $xi_cmp);
    $ret .= ghash_hpow512_pairtab_accum2_z("z2", "z3",
                                           "${prefix}_a_1", 0);
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___
    $ret .= make_ctr8_regs_fused();
    $ret .= aes128_encrypt_4z("z0", "z1", "z2", "z3", undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $ret .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, z18.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_z("z0", "z1",
                                           "${prefix}_b_0", 0);
    $ret .= ghash_hpow512_pairtab_accum2_z("z2", "z3",
                                           "${prefix}_b_1", 0);
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___

    return $ret;
}

sub emit_ctrghh512pt2e3_ctrtpl_tmpnorm_two_batches {
    my ($prefix, $with_xi, $xi_cmp, $rounds) = @_;
    my $ret = "";
    $rounds = 10 if !defined($rounds);
    my $xor_key = $rounds == 10 ? "z18" : "z6";

    $ret .= gen_ctr8_patch("x6", "w8");
    $ret .= "    add     w8, w8, #8\n";
    $ret .= load_ctr4_from_buf("x6", "z0", "z1", "z2", "z3");
    $ret .= aes_encrypt_4z_rounds("z0", "z1", "z2", "z3", $rounds,
                                  undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $ret .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, $xor_key.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z0", "z1",
                                                   "${prefix}_a_0", $with_xi,
                                                   $xi_cmp);
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z2", "z3",
                                                   "${prefix}_a_1", 0);
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___
    $ret .= gen_ctr8_patch("x5", "w8");
    $ret .= "    add     w8, w8, #8\n";
    $ret .= load_ctr4_from_buf("x5", "z0", "z1", "z2", "z3");
    $ret .= aes_encrypt_4z_rounds("z0", "z1", "z2", "z3", $rounds,
                                  undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $ret .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, $xor_key.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z0", "z1",
                                                   "${prefix}_b_0", 0);
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z2", "z3",
                                                   "${prefix}_b_1", 0);
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___

    return $ret;
}

sub emit_ctrghh512pt2e3_ctrtpl_tmpnorm_dec_two_batches {
    my ($prefix, $with_xi, $xi_cmp, $rounds) = @_;
    my $ret = "";
    $rounds = 10 if !defined($rounds);
    my $xor_key = $rounds == 10 ? "z18" : "z6";

    for (my $i = 0; $i < 4; $i++) {
        $ret .= <<___;
    ld1b    {z$i.b}, p0/z, [x10, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z0", "z1",
                                                   "${prefix}_a_0", $with_xi,
                                                   $xi_cmp);
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z2", "z3",
                                                   "${prefix}_a_1", 0);
    $ret .= gen_ctr8_patch("x6", "w8");
    $ret .= "    add     w8, w8, #8\n";
    $ret .= load_ctr4_from_buf("x6", "z0", "z1", "z2", "z3");
    $ret .= aes_encrypt_4z_rounds("z0", "z1", "z2", "z3", $rounds,
                                  undef, 0, \&preload_xor4_from_input);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        my $in = "z" . (24 + $i);
        $ret .= <<___;
    eor3    $z.d, $z.d, $xor_key.d, $in.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___

    for (my $i = 0; $i < 4; $i++) {
        $ret .= <<___;
    ld1b    {z$i.b}, p0/z, [x10, #$i, mul vl]
___
    }
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z0", "z1",
                                                   "${prefix}_b_0", 0);
    $ret .= ghash_hpow512_pairtab_accum2_tmpnorm_z("z2", "z3",
                                                   "${prefix}_b_1", 0);
    $ret .= gen_ctr8_patch("x5", "w8");
    $ret .= "    add     w8, w8, #8\n";
    $ret .= load_ctr4_from_buf("x5", "z0", "z1", "z2", "z3");
    $ret .= aes_encrypt_4z_rounds("z0", "z1", "z2", "z3", $rounds,
                                  undef, 0, \&preload_xor4_from_input);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        my $in = "z" . (24 + $i);
        $ret .= <<___;
    eor3    $z.d, $z.d, $xor_key.d, $in.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $ret .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___

    return $ret;
}

sub ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_probe {
    my $ret = ctr32_ghash_hpow512_pairtab2_eor3_fused_probe();

    $ret =~ s/gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_fused_asm/gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm/g;
    $ret =~ s/ctrghh512pt2e3/ctrghh512pt2e3ctn/g;

    my $after_save = <<___;
    mov     x7, #0
    ld1rqb  {z8.b}, p0/z, [x4, x7]
___
    my $after_save_new = <<___;
    sub     sp, sp, #256
    mov     x7, #0
    ld1rqb  {z8.b}, p0/z, [x4, x7]
___
    $ret =~ s/\Q$after_save\E/$after_save_new/
        or die "failed to add ctrtpl stack";

    my $after_ptrs = <<___;
    mov     x13, x5
    mov     x15, #0
    mov     x16, #8192
___
    my $after_ptrs_new = <<___;
    mov     x13, x5
    ldr     x14, [x6]
    ldr     w15, [x6, #8]
    mov     x6, sp
    add     x5, sp, #128
___
    $after_ptrs_new .= init_ctr8_template("x6");
    $after_ptrs_new .= init_ctr8_template("x5");
    $after_ptrs_new .= <<___;
    mov     x15, #0
    mov     x16, #8192
___
    $ret =~ s/\Q$after_ptrs\E/$after_ptrs_new/
        or die "failed to add ctrtpl templates";

    my $old = <<___;
.Lctrghh512pt2e3ctn_loop:
___
    $old .= make_ctr8_regs_fused();
    $old .= aes128_encrypt_4z("z0", "z1", "z2", "z3", undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $old .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, z18.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $old .= ghash_hpow512_pairtab_accum2_z("z0", "z1",
                                           "ctrghh512pt2e3ctn_a_0", 1);
    $old .= ghash_hpow512_pairtab_accum2_z("z2", "z3",
                                           "ctrghh512pt2e3ctn_a_1", 0);
    $old .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
___
    $old .= make_ctr8_regs_fused();
    $old .= aes128_encrypt_4z("z0", "z1", "z2", "z3", undef, 0);
    for (my $i = 0; $i < 4; $i++) {
        my $z = "z$i";
        $old .= <<___;
    ld1b    {z26.b}, p0/z, [x10, #$i, mul vl]
    eor3    $z.d, $z.d, z18.d, z26.d
    st1b    {$z.b}, p0, [x11, #$i, mul vl]
___
    }
    $old .= ghash_hpow512_pairtab_accum2_z("z0", "z1",
                                           "ctrghh512pt2e3ctn_b_0", 0);
    $old .= ghash_hpow512_pairtab_accum2_z("z2", "z3",
                                           "ctrghh512pt2e3ctn_b_1", 0);
    $old .= <<___;
    add     x10, x10, #128
    add     x11, x11, #128
    add     x15, x15, #128
    subs    x17, x17, #1
    b.ne    .Lctrghh512pt2e3ctn_loop
___
    my $new = <<___;
.Lctrghh512pt2e3ctn_loop:
___
    $new .= emit_ctrghh512pt2e3_ctrtpl_tmpnorm_two_batches(
        "ctrghh512pt2e3ctn", 1);
    $new .= <<___;
    subs    x17, x17, #1
    b.ne    .Lctrghh512pt2e3ctn_loop
___
    $ret =~ s/\Q$old\E/$new/ or die "failed to patch ctrtpl loop";

    my $reduce = reduce_acc_stage_eor3_custom(3, "z28", "z29", "z30",
                                              "z23", "z4", "z5", "z6",
                                              "z7");
    my $restore_rc = <<___;
    mov     x7, #0xc2
    lsl     x7, x7, #56
    dup     z23.d, x7
___
    $ret =~ s/\Q$reduce\E/$restore_rc$reduce/
        or die "failed to restore ctrtpl rc";

    my $before_restore = <<___;
    mov     x0, x15
___
    my $before_restore_new = <<___;
    mov     x0, x15
    add     sp, sp, #256
___
    $ret =~ s/\Q$before_restore\E/$before_restore_new/
        or die "failed to restore ctrtpl stack";

    return $ret;
}

sub ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_rounds_probe {
    my ($rounds) = @_;
    my $label = "ctrghh512pt2e3ctn${rounds}";
    my $ret = ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_probe();

    $ret =~ s/gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm/gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_${rounds}_asm/g;
    $ret =~ s/ctrghh512pt2e3ctn/$label/g;

    my $round_check_old = <<___;
    ldr     w7, [x4, #240]
    cmp     w7, #10
    b.ne    .L${label}_ret0
___
    my $round_check_new = <<___;
    ldr     w7, [x4, #240]
    cmp     w7, #$rounds
    b.ne    .L${label}_ret0
___
    $ret =~ s/\Q$round_check_old\E/$round_check_new/
        or die "failed to patch ctrtpl rounds $rounds";

    my $save_key_old = <<___;
    mov     x7, #160
    ld1rqb  {z18.b}, p0/z, [x4, x7]
___
    my $save_key_new = <<___;
    mov     x7, #160
    ld1rqb  {z18.b}, p0/z, [x4, x7]
    mov     x9, x4
___
    $ret =~ s/\Q$save_key_old\E/$save_key_new/
        or die "failed to save key pointer for rounds $rounds";

    if ($rounds != 10) {
        my $window_old = <<___;
    mov     x16, #8192

.L${label}_window:
___
        my $window_new = <<___;
    mov     x16, #8192
    mov     x7, #@{[($rounds - 1) * 16]}
    ld1rqb  {z5.b}, p0/z, [x9, x7]
    mov     x7, #@{[$rounds * 16]}
    ld1rqb  {z6.b}, p0/z, [x9, x7]
___
        if ($rounds == 14) {
            $window_new .= <<___;
    mov     x7, #176
    ld1rqb  {z19.b}, p0/z, [x9, x7]
    mov     x7, #192
    ld1rqb  {z20.b}, p0/z, [x9, x7]
___
        }
        $window_new .= <<___;

.L${label}_window:
___
        $ret =~ s/\Q$window_old\E/$window_new/
            or die "failed to preload aes keys";
    }

    my $old = emit_ctrghh512pt2e3_ctrtpl_tmpnorm_two_batches($label, 1,
                                                             undef, 10);
    my $new = emit_ctrghh512pt2e3_ctrtpl_tmpnorm_two_batches($label, 1,
                                                             undef, $rounds);
    $ret =~ s/\Q$old\E/$new/
        or die "failed to patch ctrtpl aes rounds $rounds";

    if ($rounds != 10) {
        my $old_reduce = reduce_acc_stage_eor3_custom(3, "z28", "z29", "z30",
                                                      "z23", "z4", "z5",
                                                      "z6", "z7");
        my $new_reduce = load_idx(".Lidx_lh", "z21");
        $new_reduce .= load_idx(".Lidx_xh", "z22");
        $new_reduce .= reduce_acc_stage_eor3_custom(3, "z28", "z29", "z30",
                                                    "z23", "z4", "z21",
                                                    "z22", "z7");
        $ret =~ s/\Q$old_reduce\E/$new_reduce/
            or die "failed to reload reduce indexes for rounds $rounds";
    }

    return $ret;
}

sub ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_rounds_probe {
    my ($rounds) = @_;
    my $label = "ctrghh512pt2e3ctnd${rounds}";
    my $ret = ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_probe();

    $ret =~ s/gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_asm/gcm_sve2_ctr32_ghash_hpow512_pairtab2_eor3_ctrtpl_tmpnorm_fused_dec_${rounds}_asm/g;
    $ret =~ s/ctrghh512pt2e3ctn/$label/g;

    my $round_check_old = <<___;
    ldr     w7, [x4, #240]
    cmp     w7, #10
    b.ne    .L${label}_ret0
___
    my $round_check_new = <<___;
