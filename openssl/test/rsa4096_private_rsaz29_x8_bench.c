/*
 * RSA4096 private CRT x8 benchmark using the radix28 SVE2 kernels.
 *
 * The shared benchmark body is parameterized by RSA_BITS.  RSA4096 uses
 * 2048-bit CRT branches, i.e. 74 radix28 digits and 410 fixed-window steps.
 */
#define RSA_BITS 4096
#include "rsa2048_private_rsaz29_x8_bench.c"
