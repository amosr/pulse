(*
   Copyright 2024 Microsoft Research

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)

module PulseCore.Memory
open FStar.Ghost
open FStar.PCM
module PP = PulseCore.Preorder
module PST = PulseCore.PreorderStateMonad
module U = FStar.Universe
module S = FStar.Set
module CM = FStar.Algebra.CommMonoid
/// This module adds memory invariants to the heap to expose the
/// final interface for Pulse's PCM-based memory model.

(**** Basic memory properties *)

(** Abstract type of memories *)
val mem  : Type u#(a + 3)

val is_ghost_action (m0 m1:mem u#a) : prop
let maybe_ghost_action (b:bool) (m0 m1:mem u#a) = b ==> is_ghost_action m0 m1

val ghost_action_preorder (_:unit)
  : Lemma (FStar.Preorder.preorder_rel is_ghost_action)
 
(**
  The memory is built on top of the heap, adding on the memory invariants. However, some of the
  properties exposed for memories need only to talk about the underlying heap, putting aside
  the memory invariants. To avoid exposing the underlying heap in this abstract interface, we
  prefer to relying on this [core_mem] function that returns a new memory sharing the same
  heap with the original memory but without any of the memory invariants.
*)
val core_mem (m:mem u#a) : mem u#a

(**** Separation logic *)

(** The type of separation logic propositions. Based on Steel.Heap.slprop *)
[@@erasable]
val slprop : Type u#(a + 3) //invariant predicates, i --> p, live in u#a+3

[@@erasable]
val big_slprop : Type u#(a + 2) //all other predicates live in u#a+2, e.g., big_pts_to, pts_to
val cm_big_slprop : CM.cm big_slprop
val down (s:slprop u#a) : big_slprop u#a
val up (s:big_slprop u#a) : slprop u#a
let is_big (s:slprop u#a) = s == up (down s) //any slprop that has no invariants in it, satisfies is_big
let big_vprop = s:slprop u#a { is_big s }
val up_big_is_big (b:big_slprop) : Lemma (is_big (up b))
//big slprops can be turned into invariants, but are not otherwise storeable in the heap

[@@erasable]
val small_slprop : Type u#(a + 1) //small slprops are heap storeable; these are the most common ones e.g., pts_to etc
//e.g., one can write `r:BigRef.ref small_slprop` and write `big_pts_to r `
val cm_small_slprop : CM.cm small_slprop
val down2 (s:slprop u#a) : small_slprop u#a
val up2 (s:small_slprop u#a) : slprop u#a
let is_small (s:slprop u#a) = s == up2 (down2 s)
val small_is_also_big (s:slprop)
  : Lemma (is_small s ==> is_big s)
let vprop = s:slprop u#a { is_small s }
val up2_small_is_small (s:small_slprop) : Lemma (is_small (up2 s))

(** Interpreting mem assertions as memory predicates *)
val interp (p:slprop u#a) (m:mem u#a) : prop


(** Equivalence relation on slprops is just equivalence of their interpretations *)
val equiv (p1 p2:slprop u#a) : prop

(**
  An extensional equivalence principle for slprop
 *)

val slprop_extensionality (p q:slprop u#a)
  : Lemma
    (requires p `equiv` q)
    (ensures p == q)

val slprop_equiv_refl (p:slprop)
  : Lemma (p `equiv` p)
          [SMTPat (equiv p p)]
          
(** A memory maps a [ref]erence to its associated value *)
val core_ref : Type u#0

let ref (a:Type u#a) (pcm:pcm a) : Type u#0 = core_ref

(** [null] is a specific reference, that is not associated to any value
*)
val core_ref_null : core_ref

(** [null] is a specific reference, that is not associated to any value
*)
let null (#a:Type u#a) (#pcm:pcm a) : ref a pcm = core_ref_null

val core_ref_is_null (r:core_ref) : b:bool { b <==> r == core_ref_null }

(** Checking whether [r] is the null pointer is decidable through [is_null]
*)
let is_null (#a:Type u#a) (#pcm:pcm a) (r:ref a pcm) : (b:bool{b <==> r == null}) = core_ref_is_null r

(** All the standard connectives of separation logic, based on [Steel.Heap] *)
val emp : vprop u#a
val pure (p:prop) : vprop u#a
val star  (p1 p2:slprop u#a) : slprop u#a
val h_exists (#a:Type u#b) (f: (a -> slprop u#a)) : slprop u#a

(***** Properties of separation logic equivalence *)

// val equiv_symmetric (p1 p2:slprop)
//   : squash (p1 `equiv` p2 ==> p2 `equiv` p1)

// val equiv_extensional_on_star (p1 p2 p3:slprop)
//   : squash (p1 `equiv` p2 ==> (p1 `star` p3) `equiv` (p2 `star` p3))

val emp_unit (p:slprop)
  : Lemma (p `equiv` (p `star` emp))


(** Equivalence of pure propositions is the equivalence of the underlying propositions *)
val pure_equiv (p q:prop)
  : Lemma ((p <==> q) ==> (pure p `equiv` pure q))

(** And the interpretation of pure propositions is their underlying propositions *)

val pure_true_emp (_:unit)
  : Lemma (pure True `equiv` emp)

(***** Properties of the separating conjunction *)
val star_commutative (p1 p2:slprop)
  : Lemma ((p1 `star` p2) `equiv` (p2 `star` p1))

val star_associative (p1 p2 p3:slprop)
  : Lemma ((p1 `star` (p2 `star` p3))
           `equiv`
           ((p1 `star` p2) `star` p3))

val star_congruence (p1 p2 p3 p4:slprop)
  : Lemma (requires p1 `equiv` p3 /\ p2 `equiv` p4)
          (ensures (p1 `star` p2) `equiv` (p3 `star` p4))

val big_star_congruence (p1 p2:big_vprop u#a)
  : Lemma (is_big (p1 `star` p2))

val big_exists_congruence (#a:Type u#a) (p:a -> slprop u#b)
  : Lemma
    (requires forall x. is_big (p x))
    (ensures is_big (h_exists p))

val small_star_congruence (p1 p2:vprop u#a)
  : Lemma (is_small (p1 `star` p2))

val small_exists_congruence (#a:Type u#a) (p:a -> slprop u#b)
  : Lemma
    (requires forall x. is_small (p x))
    (ensures is_small (h_exists p))

val h_exists_equiv (#a:Type) (p q : a -> slprop)
: Lemma
    (requires (forall x. p x `equiv` q x))
    (ensures (h_exists p == h_exists q))


val up_emp_big ()
: Lemma (up cm_big_slprop.unit == emp)
val down_emp_big ()
: Lemma (down emp == cm_big_slprop.unit)
val up_star_big (p q:big_slprop)
: Lemma (up (p `cm_big_slprop.mult` q) == up p `star` up q)
val down_star_big (p q:big_vprop)
: Lemma (down (p `star` q) == down p `cm_big_slprop.mult` down q)

val up2_emp ()
: Lemma (up2 cm_small_slprop.unit == emp)
val down2_emp ()
: Lemma (down2 emp == cm_small_slprop.unit)
val up2_star (p q:small_slprop)
: Lemma (up2 (p `cm_small_slprop.mult` q) == up2 p `star` up2 q)
val down2_star (p q:vprop)
: Lemma (down2 (p `star` q) == down2 p `cm_small_slprop.mult` down2 q)

(**** Memory invariants *)

(** Invariants have a name *)
val iname : eqtype

let inames = erased (S.set iname)

(** This proposition tells us that all the invariants names in [e] are valid in memory [m] *)
val inames_ok (e:inames) (m:mem) : prop

(** The empty set of invariants is always empty *)
val inames_ok_empty (m:mem)
  : Lemma (ensures inames_ok Set.empty m)
          [SMTPat (inames_ok Set.empty m)]

(**
  This separation logic proposition asserts that all the invariants whose names are in [e]
  are in effect and satisfied on the heap inside the memory [m]
*)
val mem_invariant (e:inames) (m:mem u#a) : slprop u#a

val full_mem_pred: mem -> prop
let full_mem = m:mem{full_mem_pred m}

(**** Actions *)

(**
  The preorder along which the memory evolves with every update.
*)
val mem_evolves : FStar.Preorder.preorder full_mem

let _PST 
  (a:Type u#a)
  (maybe_ghost:bool)
  (except:inames)
  (expects:slprop u#m)
  (provides: a -> slprop u#m)
  (frame:slprop u#m)
= PST.pst #(full_mem u#m) a mem_evolves
    (requires fun m0 ->
        inames_ok except m0 /\
        interp (expects `star` frame `star` mem_invariant except m0) m0)
    (ensures fun m0 x m1 ->
        maybe_ghost_action maybe_ghost m0 m1 /\
        inames_ok except m1 /\
        interp (expects `star` frame `star` mem_invariant except m0) m0 /\  //TODO: fix the effect so as not to repeat this
        interp (provides x `star` frame `star` mem_invariant except m1) m1)

// (** An action is just a thunked computation in [MstTot] that takes a frame as argument *)
// let action_except (a:Type u#a) (except:inames) (expects:slprop u#um) (provides: a -> slprop u#um)
//   : Type u#(max a (um + 3)) =
//   frame:slprop -> _MstTot a except expects provides frame

(** An action is just a thunked computation in [MstTot] that takes a frame as argument *)
let _pst_action_except 
    (a:Type u#a)
    (maybe_ghost:bool)
    (except:inames)
    (expects:slprop u#um)
    (provides: a -> slprop u#um)
 : Type u#(max a (um + 3)) 
 = frame:slprop -> _PST a maybe_ghost except expects provides frame

let pst_action_except (a:Type u#a) (except:inames) (expects:slprop u#um) (provides: a -> slprop u#um) =
  _pst_action_except a false except expects provides

let pst_ghost_action_except (a:Type u#a) (except:inames) (expects:slprop u#um) (provides: a -> slprop u#um) =
  _pst_action_except a true except expects provides


(**** Invariants *)

[@@erasable]
val iref : Type0

val iname_of (i:iref) : GTot iname

val inv (i:iref) (p:slprop u#a) : slprop u#a

let live (i:iref) = h_exists (fun p -> inv i p)

let add_inv (e:inames) (i:iref) : inames = S.add (iname_of i) e
let mem_inv (e:inames) (i:iref) : GTot bool = S.mem (iname_of i) e

val dup_inv (e:inames) (i:iref) (p:slprop u#a)
: pst_ghost_action_except unit e 
    (inv i p) 
    (fun _ -> inv i p `star` inv i p)

val new_invariant (e:inames) (p:slprop { is_big p })
  : pst_ghost_action_except iref e
    p
    (fun i -> inv i p)

val with_invariant (#a:Type)
                   (#fp:slprop)
                   (#fp':a -> slprop)
                   (#opened_invariants:inames)
                   (#p:slprop)
                   (#maybe_ghost:bool)
                   (i:iref{not (mem_inv opened_invariants i)})
                   (f:_pst_action_except a maybe_ghost
                        (add_inv opened_invariants i) 
                        (p `star` fp)
                        (fun x -> p `star` fp' x))
  : _pst_action_except a maybe_ghost opened_invariants 
      (inv i p `star` fp)
      (fun x -> inv i p `star` fp' x)


val distinct_invariants_have_distinct_names
      (e:inames)
      (p:slprop u#m)
      (q:slprop u#m { p =!= q })
      (i j: iref)
: pst_ghost_action_except u#0 u#m 
    (squash (iname_of i =!= iname_of j))
    e 
    (inv i p `star` inv j q)
    (fun _ -> inv i p `star` inv j q)

val invariant_name_identifies_invariant
      (e:inames)
      (p q:slprop u#m)
      (i:iref)
      (j:iref { iname_of i == iname_of j } )
: pst_ghost_action_except (squash (p == q /\ i == j)) e
   (inv i p `star` inv j q)
   (fun _ -> inv i p `star` inv j q)
   
let rec all_live (ctx:list iref) =
  match ctx with
  | [] -> emp
  | hd::tl -> live hd `star` all_live tl

let fresh_wrt (ctx:list iref)
              (i:iref)
  = forall i'. List.Tot.memP i' ctx ==> iname_of i' <> iname_of i

val fresh_invariant (e:inames) (p:big_vprop u#m) (ctx:list iref)
  : pst_ghost_action_except (i:iref { fresh_wrt ctx i }) e
       (p `star` all_live ctx)
       (fun i -> inv i p)


(* Some generic actions and combinators *)

val pst_frame (#a:Type)
              (#maybe_ghost:bool)
              (#opened_invariants:inames)
              (#pre:slprop)
              (#post:a -> slprop)
              (frame:slprop)
              ($f:_pst_action_except a maybe_ghost opened_invariants pre post)
  : _pst_action_except a maybe_ghost opened_invariants (pre `star` frame) (fun x -> post x `star` frame)


val witness_h_exists (#opened_invariants:_) (#a:_) (p:a -> slprop)
  : pst_ghost_action_except (erased a) opened_invariants
           (h_exists p)
           (fun x -> p x)

val intro_exists (#opened_invariants:_) (#a:_) (p:a -> slprop) (x:erased a)
  : pst_ghost_action_except unit opened_invariants
           (p x)
           (fun _ -> h_exists p)

val lift_h_exists (#opened_invariants:_) (#a:_) (p:a -> slprop)
  : pst_ghost_action_except unit opened_invariants
           (h_exists p)
           (fun _a -> h_exists #(U.raise_t a) (U.lift_dom p))

val elim_pure (#opened_invariants:_) (p:prop)
  : pst_ghost_action_except (u:unit{p}) opened_invariants (pure p) (fun _ -> emp)

val intro_pure (#opened_invariants:_) (p:prop) (_:squash p)
  : pst_ghost_action_except unit opened_invariants emp (fun _ -> pure p)

val drop (#opened_invariants:_) (p:slprop)
  : pst_ghost_action_except unit opened_invariants p (fun _ -> emp)

let non_info a = x:erased a -> y:a { reveal x == y}

val lift_ghost
      (#a:Type)
      #opened_invariants #p #q
      (ni_a:non_info a)
      (f:erased (pst_ghost_action_except a opened_invariants p q))
  : pst_ghost_action_except a opened_invariants p q

(* Concrete references to "small" types *)
val pts_to (#a:Type u#a) (#pcm:_) (r:ref a pcm) (v:a) : vprop u#a

val sel_action (#a:Type u#a) (#pcm:_) (e:inames) (r:ref a pcm) (v0:erased a)
  : pst_action_except (v:a{compatible pcm v0 v}) e (pts_to r v0) (fun _ -> pts_to r v0)

val upd_action (#a:Type u#a) (#pcm:_) (e:inames)
               (r:ref a pcm)
               (v0:FStar.Ghost.erased a)
               (v1:a {FStar.PCM.frame_preserving pcm v0 v1 /\ pcm.refine v1})
  : pst_action_except unit e (pts_to r v0) (fun _ -> pts_to r v1)

val free_action (#a:Type u#a) (#pcm:pcm a) (e:inames)
                (r:ref a pcm) (x:FStar.Ghost.erased a{FStar.PCM.exclusive pcm x /\ pcm.refine pcm.FStar.PCM.p.one})
  : pst_action_except unit e (pts_to r x) (fun _ -> pts_to r pcm.FStar.PCM.p.one)

(** Splitting a permission on a composite resource into two separate permissions *)
val split_action
  (#a:Type u#a)
  (#pcm:pcm a)
  (e:inames)
  (r:ref a pcm)
  (v0:FStar.Ghost.erased a)
  (v1:FStar.Ghost.erased a{composable pcm v0 v1})
: pst_ghost_action_except unit e
    (pts_to r (v0 `op pcm` v1))
    (fun _ -> pts_to r v0 `star` pts_to r v1)

(** Combining separate permissions into a single composite permission *)
val gather_action
  (#a:Type u#a)
  (#pcm:pcm a)
  (e:inames)
  (r:ref a pcm)
  (v0:FStar.Ghost.erased a)
  (v1:FStar.Ghost.erased a)
: pst_ghost_action_except (squash (composable pcm v0 v1)) e
    (pts_to r v0 `star` pts_to r v1)
    (fun _ -> pts_to r (op pcm v0 v1))

val alloc_action (#a:Type u#a) (#pcm:pcm a) (e:inames) (x:a{pcm.refine x})
: pst_action_except (ref a pcm) e
    emp
    (fun r -> pts_to r x)

val select_refine (#a:Type u#a) (#p:pcm a)
                  (e:inames)
                  (r:ref a p)
                  (x:erased a)
                  (f:(v:a{compatible p x v}
                      -> GTot (y:a{compatible p y v /\
                                  FStar.PCM.frame_compatible p x v y})))
: pst_action_except (v:a{compatible p x v /\ p.refine v}) e
    (pts_to r x)
    (fun v -> pts_to r (f v))

val upd_gen (#a:Type u#a) (#p:pcm a) (e:inames) (r:ref a p) (x y:Ghost.erased a)
            (f:FStar.PCM.frame_preserving_upd p x y)
: pst_action_except unit e
    (pts_to r x)
    (fun _ -> pts_to r y)

val pts_to_not_null_action 
      (#a:Type u#a) (#pcm:pcm a)
      (e:inames)
      (r:erased (ref a pcm))
      (v:Ghost.erased a)
: pst_ghost_action_except (squash (not (is_null r))) e
    (pts_to r v)
    (fun _ -> pts_to r v)

(* Ghost references to "small" types *)
[@@erasable]
val core_ghost_ref : Type0
let ghost_ref (#a:Type u#a) (p:pcm a) : Type0 = core_ghost_ref
val ghost_pts_to (#a:Type u#a) (#p:pcm a) (r:ghost_ref p) (v:a) : vprop u#a

val ghost_alloc
    (#o:_)
    (#a:Type u#a)
    (#pcm:pcm a)
    (x:erased a{pcm.refine x})
: pst_ghost_action_except
    (ghost_ref pcm)
    o
    emp 
    (fun r -> ghost_pts_to r x)

val ghost_read
    #o
    (#a:Type)
    (#p:pcm a)
    (r:ghost_ref p)
    (x:erased a)
    (f:(v:a{compatible p x v}
        -> GTot (y:a{compatible p y v /\
                     FStar.PCM.frame_compatible p x v y})))
: pst_ghost_action_except
    (erased (v:a{compatible p x v /\ p.refine v}))
    o
    (ghost_pts_to r x)
    (fun v -> ghost_pts_to r (f v))

val ghost_write
    #o
    (#a:Type)
    (#p:pcm a)
    (r:ghost_ref p)
    (x y:Ghost.erased a)
    (f:FStar.PCM.frame_preserving_upd p x y)
: pst_ghost_action_except unit o 
    (ghost_pts_to r x)
    (fun _ -> ghost_pts_to r y)

val ghost_share
    #o
    (#a:Type)
    (#pcm:pcm a)
    (r:ghost_ref pcm)
    (v0:FStar.Ghost.erased a)
    (v1:FStar.Ghost.erased a{composable pcm v0 v1})
: pst_ghost_action_except unit o
    (ghost_pts_to r (v0 `op pcm` v1))
    (fun _ -> ghost_pts_to r v0 `star` ghost_pts_to r v1)

val ghost_gather
    #o
    (#a:Type)
    (#pcm:pcm a)
    (r:ghost_ref pcm)
    (v0:FStar.Ghost.erased a)
    (v1:FStar.Ghost.erased a)
: pst_ghost_action_except
    (squash (composable pcm v0 v1)) o
    (ghost_pts_to r v0 `star` ghost_pts_to r v1)
    (fun _ -> ghost_pts_to r (op pcm v0 v1))

(* Concrete references to "big" types *)
val big_pts_to (#a:Type u#(a + 1)) (#pcm:_) (r:ref a pcm) (v:a) : big_vprop u#a

val big_sel_action
      (#a:Type u#(a + 1))
      (#pcm:_)
      (e:inames)
      (r:ref a pcm)
      (v0:erased a)
: pst_action_except (v:a{compatible pcm v0 v}) e
    (big_pts_to r v0)
    (fun _ -> big_pts_to r v0)

val big_upd_action
      (#a:Type u#(a + 1)) (#pcm:_) (e:inames)
      (r:ref a pcm)
      (v0:FStar.Ghost.erased a)
      (v1:a {FStar.PCM.frame_preserving pcm v0 v1 /\ pcm.refine v1})
: pst_action_except unit e
    (big_pts_to r v0)
    (fun _ -> big_pts_to r v1)

val big_free_action
      (#a:Type u#(a + 1))
      (#pcm:pcm a)
      (e:inames)
      (r:ref a pcm)
      (x:FStar.Ghost.erased a{FStar.PCM.exclusive pcm x /\ pcm.refine pcm.FStar.PCM.p.one})
: pst_action_except unit e
    (big_pts_to r x)
    (fun _ -> big_pts_to r pcm.FStar.PCM.p.one)

(** Splitting a permission on a composite resource into two separate permissions *)
val big_split_action
      (#a:Type u#(a + 1))
      (#pcm:pcm a)
      (e:inames)
      (r:ref a pcm)
      (v0:FStar.Ghost.erased a)
      (v1:FStar.Ghost.erased a{composable pcm v0 v1})
: pst_ghost_action_except unit e
    (big_pts_to r (v0 `op pcm` v1))
    (fun _ -> big_pts_to r v0 `star` big_pts_to r v1)

(** Combining separate permissions into a single composite permission *)
val big_gather_action
      (#a:Type u#(a + 1))
      (#pcm:pcm a)
      (e:inames)
      (r:ref a pcm)
      (v0:FStar.Ghost.erased a)
      (v1:FStar.Ghost.erased a)
: pst_ghost_action_except (squash (composable pcm v0 v1)) e
    (big_pts_to r v0 `star` big_pts_to r v1)
    (fun _ -> big_pts_to r (op pcm v0 v1))

val big_alloc_action
      (#a:Type u#(a + 1))
      (#pcm:pcm a)
      (e:inames)
      (x:a{pcm.refine x})
: pst_action_except (ref a pcm) e
    emp
    (fun r -> big_pts_to r x)

val big_select_refine
      (#a:Type u#(a + 1))
      (#p:pcm a)
      (e:inames)
      (r:ref a p)
      (x:erased a)
      (f:(v:a{compatible p x v}
          -> GTot (y:a{compatible p y v /\
                      FStar.PCM.frame_compatible p x v y})))
: pst_action_except (v:a{compatible p x v /\ p.refine v}) e
    (big_pts_to r x)
    (fun v -> big_pts_to r (f v))

val big_upd_gen
    (#a:Type u#(a + 1))
    (#p:pcm a)
    (e:inames)
    (r:ref a p)
    (x y:Ghost.erased a)
    (f:FStar.PCM.frame_preserving_upd p x y)
: pst_action_except unit e
    (big_pts_to r x)
    (fun _ -> big_pts_to r y)

val big_pts_to_not_null_action 
      (#a:Type u#(a + 1))
      (#pcm:pcm a)
      (e:inames)
      (r:erased (ref a pcm))
      (v:Ghost.erased a)
: pst_ghost_action_except (squash (not (is_null r))) e
    (big_pts_to r v)
    (fun _ -> big_pts_to r v)

(* Ghost references to "small" types *)
val big_ghost_pts_to (#a:Type u#(a + 1)) (#p:pcm a) (r:ghost_ref p) (v:a) : big_vprop u#a

val big_ghost_alloc
    (#o:_)
    (#a:Type u#(a + 1))
    (#pcm:pcm a)
    (x:erased a{pcm.refine x})
: pst_ghost_action_except
    (ghost_ref pcm)
    o
    emp 
    (fun r -> big_ghost_pts_to r x)

val big_ghost_read
    #o
    (#a:Type u#(a + 1))
    (#p:pcm a)
    (r:ghost_ref p)
    (x:erased a)
    (f:(v:a{compatible p x v}
        -> GTot (y:a{compatible p y v /\
                     FStar.PCM.frame_compatible p x v y})))
: pst_ghost_action_except
    (erased (v:a{compatible p x v /\ p.refine v}))
    o
    (big_ghost_pts_to r x)
    (fun v -> big_ghost_pts_to r (f v))

val big_ghost_write
    #o
    (#a:Type u#(a + 1))
    (#p:pcm a)
    (r:ghost_ref p)
    (x y:Ghost.erased a)
    (f:FStar.PCM.frame_preserving_upd p x y)
: pst_ghost_action_except unit o 
    (big_ghost_pts_to r x)
    (fun _ -> big_ghost_pts_to r y)

val big_ghost_share
    #o
    (#a:Type u#(a + 1))
    (#pcm:pcm a)
    (r:ghost_ref pcm)
    (v0:FStar.Ghost.erased a)
    (v1:FStar.Ghost.erased a{composable pcm v0 v1})
: pst_ghost_action_except unit o
    (big_ghost_pts_to r (v0 `op pcm` v1))
    (fun _ -> big_ghost_pts_to r v0 `star` big_ghost_pts_to r v1)

val big_ghost_gather
    #o
    (#a:Type u#(a + 1))
    (#pcm:pcm a)
    (r:ghost_ref pcm)
    (v0:FStar.Ghost.erased a)
    (v1:FStar.Ghost.erased a)
: pst_ghost_action_except
    (squash (composable pcm v0 v1)) o
    (big_ghost_pts_to r v0 `star` big_ghost_pts_to r v1)
    (fun _ -> big_ghost_pts_to r (op pcm v0 v1))

