{ SHA-256 block compression. The caller owns buffering, padding and length.
  Neither compressor may run before its CPU features have been checked. }

{$IFDEF CPUAARCH64}
function GetAuxVal(const ATag: PtrUInt): PtrUInt;
  cdecl; external 'c' name 'getauxval';

function SHA256CPUAvailable: Boolean;
const
  AT_HWCAP = 16;
  HWCAP_SHA2 = PtrUInt(1) shl 6;
begin
  Result := (GetAuxVal(AT_HWCAP) and HWCAP_SHA2) <> 0;
end;

procedure SHA256CompressInstructions(const AState, ABlock, ARounds: Pointer);
  cdecl; assembler; nostackframe;
asm
  // AAPCS64: x0 = state, x1 = message block, x2 = round constants.
  // FPC 3.2.x cannot encode these vector operands. Each word is annotated.
  .long 0x3dc00010 // ldr q16, [x0]
  .long 0x3dc00411 // ldr q17, [x0, #16]
  // Load and byte-swap the first 16 message words.
  .long 0x3dc00020 // ldr q0, [x1]
  .long 0x3dc00421 // ldr q1, [x1, #16]
  .long 0x3dc00822 // ldr q2, [x1, #32]
  .long 0x3dc00c23 // ldr q3, [x1, #48]
  .long 0x6e200800 // rev32 v0.16b, v0.16b
  .long 0x6e200821 // rev32 v1.16b, v1.16b
  .long 0x6e200842 // rev32 v2.16b, v2.16b
  .long 0x6e200863 // rev32 v3.16b, v3.16b
  .long 0x4eb01e04 // mov v4.16b, v16.16b
  .long 0x4eb11e25 // mov v5.16b, v17.16b
  mov x3, #4
.LSHA256Rounds:
  // Four groups of four rounds, rotating the message schedule through v0..v3.
  .long 0x3dc00046 // ldr q6, [x2, #0]
  .long 0x4ea084c6 // add v6.4s, v6.4s, v0.4s
  .long 0x4ea41c87 // mov v7.16b, v4.16b
  .long 0x5e0640a4 // sha256h q4, q5, v6.4s
  .long 0x5e0650e5 // sha256h2 q5, q7, v6.4s
  .long 0x5e282820 // sha256su0 v0.4s, v1.4s
  .long 0x5e036040 // sha256su1 v0.4s, v2.4s, v3.4s
  .long 0x3dc00446 // ldr q6, [x2, #16]
  .long 0x4ea184c6 // add v6.4s, v6.4s, v1.4s
  .long 0x4ea41c87 // mov v7.16b, v4.16b
  .long 0x5e0640a4 // sha256h q4, q5, v6.4s
  .long 0x5e0650e5 // sha256h2 q5, q7, v6.4s
  .long 0x5e282841 // sha256su0 v1.4s, v2.4s
  .long 0x5e006061 // sha256su1 v1.4s, v3.4s, v0.4s
  .long 0x3dc00846 // ldr q6, [x2, #32]
  .long 0x4ea284c6 // add v6.4s, v6.4s, v2.4s
  .long 0x4ea41c87 // mov v7.16b, v4.16b
  .long 0x5e0640a4 // sha256h q4, q5, v6.4s
  .long 0x5e0650e5 // sha256h2 q5, q7, v6.4s
  .long 0x5e282862 // sha256su0 v2.4s, v3.4s
  .long 0x5e016002 // sha256su1 v2.4s, v0.4s, v1.4s
  .long 0x3dc00c46 // ldr q6, [x2, #48]
  .long 0x4ea384c6 // add v6.4s, v6.4s, v3.4s
  .long 0x4ea41c87 // mov v7.16b, v4.16b
  .long 0x5e0640a4 // sha256h q4, q5, v6.4s
  .long 0x5e0650e5 // sha256h2 q5, q7, v6.4s
  .long 0x5e282803 // sha256su0 v3.4s, v0.4s
  .long 0x5e026023 // sha256su1 v3.4s, v1.4s, v2.4s
  add x2, x2, #64
  subs x3, x3, #1
  b.ne .LSHA256Rounds
  // Feed the resulting state back into the saved initial state.
  .long 0x4eb08484 // add v4.4s, v4.4s, v16.4s
  .long 0x4eb184a5 // add v5.4s, v5.4s, v17.4s
  .long 0x3d800004 // str q4, [x0]
  .long 0x3d800405 // str q5, [x0, #16]
end;
{$ELSE}
const
  SHA256_BYTE_SHUFFLE: array[0..15] of Byte =
    (3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12);

{$PUSH}{$ASMMODE INTEL}
procedure SHA256CompressInstructions(const AState, ABlock, ARounds,
  AByteShuffle: Pointer);
  cdecl; assembler; nostackframe;
asm
  // System V AMD64: rdi = state, rsi = block, rdx = constants, rcx = shuffle.
  // FPC 3.2.x has no SHA-NI mnemonics. The db instructions are annotated.
  // Rearrange ABCD / EFGH into ABEF / CDGH for SHA256RNDS2.
  movdqu xmm1, [rdi]
  movdqu xmm2, [rdi + 16]
  pshufd xmm1, xmm1, $b1
  pshufd xmm2, xmm2, $1b
  movdqa xmm0, xmm1
  palignr xmm1, xmm2, 8
  pblendw xmm2, xmm0, $f0
  movdqa xmm3, xmm1
  movdqa xmm4, xmm2
  // Load and byte-swap the first 16 message words.
  movdqu xmm9, [rcx]
  movdqu xmm5, [rsi + 0]
  pshufb xmm5, xmm9
  movdqu xmm6, [rsi + 16]
  pshufb xmm6, xmm9
  movdqu xmm7, [rsi + 32]
  pshufb xmm7, xmm9
  movdqu xmm8, [rsi + 48]
  pshufb xmm8, xmm9
  mov ecx, 4
@Rounds:
  // Four groups of four rounds, rotating the message schedule through xmm5..8.
  movdqu xmm0, [rdx + 0]
  paddd xmm0, xmm5
  db $0f, $38, $cb, $d1 // sha256rnds2 xmm2, xmm1
  pshufd xmm0, xmm0, $0e
  db $0f, $38, $cb, $ca // sha256rnds2 xmm1, xmm2
  db $0f, $38, $cc, $ee // sha256msg1 xmm5, xmm6
  movdqa xmm9, xmm8
  palignr xmm9, xmm7, 4
  paddd xmm5, xmm9
  db $41, $0f, $38, $cd, $e8 // sha256msg2 xmm5, xmm8
  movdqu xmm0, [rdx + 16]
  paddd xmm0, xmm6
  db $0f, $38, $cb, $d1 // sha256rnds2 xmm2, xmm1
  pshufd xmm0, xmm0, $0e
  db $0f, $38, $cb, $ca // sha256rnds2 xmm1, xmm2
  db $0f, $38, $cc, $f7 // sha256msg1 xmm6, xmm7
  movdqa xmm9, xmm5
  palignr xmm9, xmm8, 4
  paddd xmm6, xmm9
  db $0f, $38, $cd, $f5 // sha256msg2 xmm6, xmm5
  movdqu xmm0, [rdx + 32]
  paddd xmm0, xmm7
  db $0f, $38, $cb, $d1 // sha256rnds2 xmm2, xmm1
  pshufd xmm0, xmm0, $0e
  db $0f, $38, $cb, $ca // sha256rnds2 xmm1, xmm2
  db $41, $0f, $38, $cc, $f8 // sha256msg1 xmm7, xmm8
  movdqa xmm9, xmm6
  palignr xmm9, xmm5, 4
  paddd xmm7, xmm9
  db $0f, $38, $cd, $fe // sha256msg2 xmm7, xmm6
  movdqu xmm0, [rdx + 48]
  paddd xmm0, xmm8
  db $0f, $38, $cb, $d1 // sha256rnds2 xmm2, xmm1
  pshufd xmm0, xmm0, $0e
  db $0f, $38, $cb, $ca // sha256rnds2 xmm1, xmm2
  db $44, $0f, $38, $cc, $c5 // sha256msg1 xmm8, xmm5
  movdqa xmm9, xmm7
  palignr xmm9, xmm6, 4
  paddd xmm8, xmm9
  db $44, $0f, $38, $cd, $c7 // sha256msg2 xmm8, xmm7
  add rdx, 64
  dec ecx
  jnz @Rounds
  // Feed forward and restore ABCD / EFGH word order.
  paddd xmm1, xmm3
  paddd xmm2, xmm4
  pshufd xmm1, xmm1, $1b
  pshufd xmm2, xmm2, $b1
  movdqa xmm0, xmm1
  pblendw xmm1, xmm2, $f0
  palignr xmm2, xmm0, 8
  movdqu [rdi], xmm1
  movdqu [rdi + 16], xmm2
end;

function SHA256CPUAvailable: Boolean; assembler; nostackframe;
asm
  // CPUID clobbers RBX, which the System V ABI requires us to preserve.
  push rbx
  xor eax, eax
  cpuid
  cmp eax, 7
  jb @No
  mov eax, 1
  cpuid
  // SSSE3 (9) and SSE4.1 (19) cover the shuffle and blend instructions.
  and ecx, $00080200
  cmp ecx, $00080200
  jne @No
  mov eax, 7
  xor ecx, ecx
  cpuid
  bt ebx, 29 // SHA-NI
  setc al
  jmp @Done
@No:
  xor eax, eax
@Done:
  pop rbx
end;
{$POP}
{$ENDIF}

var
  { Set in unit initialization before any thread can hash. }
  SHA256InstructionsAvailable: Boolean;
