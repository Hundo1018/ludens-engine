; ---------------------------------------------------------------------------
; Capability corpus, level 00: pure integer arithmetic, no memory / no runtime.
;
; This is HAND-WRITTEN LLVM IR. Its purpose is to prove that the retarget
; back-half is *source-language independent*: any front-end that emits LLVM IR
; -- Mojo included -- lowers through `llc -march=wasm32` + `wasm-ld` to a .wasm.
; When the Mojo front-end is available, its emitted IR for the equivalent
; functions drops in here unchanged.
;
; No `target datalayout` / `target triple` on purpose: `llc -march=wasm32`
; supplies the wasm32 target defaults, so this file is toolchain-version robust.
; ---------------------------------------------------------------------------

define i32 @add(i32 %a, i32 %b) {
entry:
  %r = add i32 %a, %b
  ret i32 %r
}

; sum of 0..n-1  (a trivial loop: exercises phi nodes / control flow lowering)
define i32 @sum_to(i32 %n) {
entry:
  br label %loop
loop:
  %i   = phi i32 [ 0, %entry ], [ %i.next,   %body ]
  %acc = phi i32 [ 0, %entry ], [ %acc.next, %body ]
  %cond = icmp slt i32 %i, %n
  br i1 %cond, label %body, label %done
body:
  %acc.next = add i32 %acc, %i
  %i.next   = add i32 %i, 1
  br label %loop
done:
  ret i32 %acc
}
