module LowStar.RST.Loops

open LowStar.Resource
open LowStar.RST
module HS = FStar.HyperStack
module AR = LowStar.RST.Array
module A = LowStar.Array
module U32 = FStar.UInt32
open FStar.Mul

inline_for_extraction
val while
  (res:resource)
  (inv: (selector res -> Type0))
  (guard: (selector res -> GTot bool))
  (test: (unit -> RST bool
    res
    (fun _ -> res)
    (requires fun old -> inv old)
    (ensures fun old b modern ->
      b == guard old /\
      old res == modern res)
  ))
  (body: (unit -> RST unit
    res
    (fun _ -> res)
    (requires fun old -> guard old /\ inv old)
    (ensures fun old _ modern -> inv modern)
  ))
  : RST unit
    res
    (fun _ -> res)
    (requires fun old -> inv old)
    (ensures fun _ _ modern -> inv modern /\ ~(guard modern))

inline_for_extraction
val for
  (start:U32.t)
  (finish:U32.t{U32.v finish >= U32.v start})
  (context: resource)
  (loop_inv: (selector context -> nat -> Type0))
  (f:(i:U32.t{U32.(v start <= v i /\ v i < v finish)} -> RST unit
    (context)
    (fun _ -> context)
    (requires (fun old -> loop_inv old (U32.v i)))
    (ensures (fun old _ modern -> U32.(loop_inv old (v i) /\ loop_inv modern (v i + 1))))
  ))
  : RST unit
    (context)
    (fun _ -> context)
    (requires (fun old -> loop_inv old (U32.v start)))
    (ensures (fun _ _ modern -> loop_inv modern (U32.v finish)))
