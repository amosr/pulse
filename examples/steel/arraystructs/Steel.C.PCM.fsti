module Steel.C.PCM
module P = FStar.PCM
open FStar.FunctionalExtensionality
open FStar.IndefiniteDescription

val pcm0 (a:Type u#a) : Type u#a

val composable (#a: Type u#a) (p:pcm0 a) (x y:a) : Tot prop

val one (#a: Type) (p: pcm0 a) : Tot a

val op (#a: Type u#a) (p:pcm0 a) (x:a) (y:a{composable p x y}) : Tot a

val op_comm
  (#a: Type u#a)
  (p: pcm0 a)
  (x y: a)
: Lemma
  (requires (composable p x y))
  (ensures (composable p y x /\ op p x y == op p y x))
  [SMTPat (composable p x y)]

val op_assoc_l
  (#a: Type u#a)
  (p: pcm0 a)
  (x y z: a)
: Lemma
  (requires (composable p y z /\ composable p x (op p y z)))
  (ensures (
    composable p x y /\ composable p (op p x y) z /\
    op p x (op p y z) == op p (op p x y) z
  ))
  [SMTPat (composable p y z); SMTPat (composable p x (op p y z))]

val op_assoc_r
  (#a: Type u#a)
  (p: pcm0 a)
  (x y z: a)
: Lemma
  (requires (composable p x y /\ composable p (op p x y) z))
  (ensures (
    composable p y z /\ composable p x (op p y z) /\
    op p x (op p y z) == op p (op p x y) z
  ))
  [SMTPat (composable p x y); SMTPat (composable p (op p x y) z)]

val p_refine (#a: Type) (p: pcm0 a) (x: a) : Tot prop

val pcm_of_fstar_pcm
  (#a: Type)
  (p: P.pcm a)
: Tot (pcm0 a)

val fstar_pcm_of_pcm
  (#a: Type)
  (p: pcm0 a)
: Tot (P.pcm a)

val pcm_of_fstar_pcm_of_pcm
  (#a: Type)
  (p: pcm0 a)
: Lemma
  (pcm_of_fstar_pcm (fstar_pcm_of_pcm p) == p)
  [SMTPat (pcm_of_fstar_pcm (fstar_pcm_of_pcm p))]

val composable_pcm_of_fstar_pcm
  (#a: Type)
  (p: P.pcm a)
  (x y: a)
: Lemma
  ((composable (pcm_of_fstar_pcm p) x y <==> P.composable p x y) /\
    (composable (pcm_of_fstar_pcm p) x y ==> op (pcm_of_fstar_pcm p) x y == P.op p x y))
  [SMTPat (composable (pcm_of_fstar_pcm p) x y)]

val one_pcm_of_fstar_pcm
  (#a: Type)
  (p: P.pcm a)
: Lemma
  (one (pcm_of_fstar_pcm p) == P.one p)
  [SMTPat (one (pcm_of_fstar_pcm p))]

val p_refine_pcm_of_fstar_pcm
  (#a: Type)
  (p: P.pcm a)
  (x: a)
: Lemma
  (p_refine (pcm_of_fstar_pcm p) x <==> p.P.refine x)
  [SMTPat (p_refine (pcm_of_fstar_pcm p) x)]

val composable_fstar_pcm_of_pcm
  (#a: Type)
  (p: pcm0 a)
  (x y: a)
: Lemma
  ((P.composable (fstar_pcm_of_pcm p) x y <==> composable p x y) /\
   (P.composable (fstar_pcm_of_pcm p) x y ==> P.op (fstar_pcm_of_pcm p) x y == op p x y))
  [SMTPat (P.composable (fstar_pcm_of_pcm p) x y)]

val one_fstar_pcm_of_pcm
  (#a: Type)
  (p: pcm0 a)
: Lemma
  (P.one (fstar_pcm_of_pcm p) == one p)
  [SMTPat (P.one (fstar_pcm_of_pcm p))]

val refine_fstar_pcm_of_pcm
  (#a: Type)
  (p: pcm0 a)
  (x: a)
: Lemma
  ((fstar_pcm_of_pcm p).P.refine x <==> p_refine p x)
  [SMTPat ((fstar_pcm_of_pcm p).P.refine x)]

let exclusive (#a:Type u#a) (p:pcm0 a) (x:a) =
  forall (frame:a). composable p x frame ==> frame == one p

let compatible (#a: Type u#a) (pcm:pcm0 a) (x y:a) =
  (exists (frame:a).
    composable pcm x frame /\ op pcm frame x == y
  )

val is_unit (#a: Type u#a) (p:pcm0 a)
  (x:a)
:  Lemma (composable p x (one p) /\
         op p x (one p) == x)

let is_unit_pat (#a: Type u#a) (p:pcm0 a)
  (x:a)
:  Lemma (composable p x (one p) /\
         op p x (one p) == x)
   [SMTPat (composable p x (one p))]
= is_unit p x

val compatible_intro
  (#a: Type u#a)
  (pcm: pcm0 a)
  (x y: a)
  (frame: a)
: Lemma
  (requires (composable pcm x frame /\ op pcm frame x == y))
  (ensures (compatible pcm x y))

val compatible_elim
  (#a: Type u#a)
  (pcm: pcm0 a)
  (x y: a)
: Ghost a
  (requires (compatible pcm x y))
  (ensures (fun frame ->
    composable pcm x frame /\
    op pcm frame x == y
  ))

val compatible_refl
  (#a: Type u#a)
  (pcm: pcm0 a)
  (x: a)
: Lemma
  (compatible pcm x x)

val compatible_fstar_pcm_of_pcm
  (#a: Type u#a)
  (p: pcm0 a)
  (x y: a)
: Lemma
  (P.compatible (fstar_pcm_of_pcm p) x y <==> compatible p x y)
  [SMTPat (P.compatible (fstar_pcm_of_pcm p) x y)]

val compatible_pcm_of_fstar_pcm
  (#a: Type u#a)
  (p: P.pcm a)
  (x y: a)
: Lemma
  (compatible (pcm_of_fstar_pcm p) x y <==> P.compatible p x y)
  [SMTPat (compatible (pcm_of_fstar_pcm p) x y)]

val exclusive_fstar_pcm_of_pcm
  (#a: Type u#a)
  (p: pcm0 a)
  (x: a)
: Lemma
  (P.exclusive (fstar_pcm_of_pcm p) x <==> exclusive p x)
  [SMTPat (P.exclusive (fstar_pcm_of_pcm p) x)]

val exclusive_pcm_of_fstar_pcm
  (#a: Type u#a)
  (p: P.pcm a)
  (x: a)
: Lemma
  (exclusive (pcm_of_fstar_pcm p) x <==> P.exclusive p x)
  [SMTPat (exclusive (pcm_of_fstar_pcm p) x)]

type frame_preserving_upd (#a:Type u#a) (p:pcm0 a) (x y:a) =
  v:a{
    p_refine p v /\
    compatible p x v
  } ->
  v_new:a{
    p_refine p v_new /\
    compatible p y v_new /\
    (forall (frame:a{composable p x frame}).{:pattern composable p x frame}
       composable p y frame /\
       (op p x frame == v ==> op p y frame == v_new))}

val fstar_fpu_of_fpu
  (#a: Type u#a)
  (p: pcm0 a)
  (x y: Ghost.erased a)
  (f: frame_preserving_upd p x y)
: Tot (FStar.PCM.frame_preserving_upd (fstar_pcm_of_pcm p) x y)

let pcm (a: Type) : Tot Type =
  (p: pcm0 a {
    (forall (x:a) (y:a{composable p x y}).{:pattern (composable p x y)}
      op p x y == one p ==> x == one p /\ y == one p) /\ // necessary to lift frame-preserving updates to unions
    (forall (x:a) . {:pattern (p_refine p x)} p_refine p x ==> exclusive p x) /\ // nice to have, but not used yet
    (~ (p_refine p (one p))) // necessary to maintain (refine ==> exclusive) for uninit
  })
