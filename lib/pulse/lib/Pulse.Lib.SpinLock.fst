(*
   Copyright 2023 Microsoft Research

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

module Pulse.Lib.SpinLock

open Pulse.Lib.Pervasives
open Pulse.Lib.CancellableInvariant

module U32 = FStar.UInt32
module B = Pulse.Lib.Box
module GR = Pulse.Lib.GhostReference

let lock_inv_aux (r:B.box U32.t) (gr:GR.ref U32.t) (v:vprop) : (w:vprop { is_big v ==> is_big w })  =
  exists* i p. B.pts_to r #1.0R i **
               GR.pts_to gr #p i **
               (if i = 0ul then v else emp) **
               pure ((i == 0ul ==> p == 1.0R) /\
                     (i =!= 0ul ==> p == 0.5R)) 

let lock_inv (r:B.box U32.t) (gr:GR.ref U32.t) (v:vprop) : vprop =
  lock_inv_aux r gr v

let is_big_lock_inv (r:B.box U32.t) (gr:GR.ref U32.t) (v:vprop)
  : Lemma (is_big v ==> is_big (lock_inv r gr v)) = ()

noeq
type lock = {
  r : B.box U32.t;
  gr : GR.ref U32.t;
  i : cinv;
}

let lock_alive l #p v =
  inv (iref_of l.i) (cinv_vp l.i (lock_inv l.r l.gr v)) ** active p l.i

let lock_acquired l = GR.pts_to l.gr #0.5R 1ul

```pulse
fn new_lock (v:vprop { is_big v })
  requires v
  returns l:lock
  ensures lock_alive l v
{
  let r = B.alloc 0ul;
  let gr = GR.alloc 0ul;
  rewrite v as (if 0ul = 0ul then v else emp);
  fold (lock_inv_aux r gr v);
  fold (lock_inv r gr v);
  is_big_lock_inv r gr v;
  let i = new_cancellable_invariant (lock_inv r gr v);
  let l = { r; gr; i };
  rewrite each r as l.r;
  rewrite each gr as l.gr;
  rewrite each i as l.i;
  fold (lock_alive l #1.0R v);
  l
}
```

```pulse
fn rec acquire (#v:vprop) (#p:perm) (l:lock)
  requires lock_alive l #p v
  ensures v **  lock_alive l #p v ** lock_acquired l
{
  unfold (lock_alive l #p v);
  let b =
    with_invariants (iref_of l.i)
      returns b:bool
      ensures inv (iref_of l.i) (cinv_vp l.i (lock_inv l.r l.gr v)) **
              active p l.i **
              (if b then v ** GR.pts_to l.gr #0.5R 1ul else emp) {
      unpack_cinv_vp l.i;
      unfold lock_inv;
      unfold lock_inv_aux;
      let b = cas_box l.r 0ul 1ul;
      if b {
        elim_cond_true _ _ _;
        GR.(l.gr := 1ul);
        GR.share2 l.gr;
        rewrite emp as (if (1ul = 0ul) then v else emp);
        fold (lock_inv_aux l.r l.gr v);
        fold (lock_inv l.r l.gr v);
        pack_cinv_vp l.i;
        assert (cinv_vp l.i (lock_inv l.r l.gr v) **
                active p l.i **
                GR.pts_to l.gr #0.5R 1ul **
                v);
        let b = true;
        rewrite (v ** GR.pts_to l.gr #0.5R 1ul)
             as (if b then v ** GR.pts_to l.gr #0.5R 1ul else emp);
        b
      } else {
        elim_cond_false _ _ _;
        fold (lock_inv_aux l.r l.gr v);
        fold (lock_inv l.r l.gr v);
        pack_cinv_vp l.i;
        assert (cinv_vp l.i (lock_inv l.r l.gr v) **
                active p l.i);
        let b = false;
        rewrite emp as
                (if b then v ** GR.pts_to l.gr #0.5R 1ul else emp);
        b
      }
    };

  if b {
    rewrite (if b then v ** GR.pts_to l.gr #0.5R 1ul else emp) as
            (v ** GR.pts_to l.gr #0.5R 1ul);
    fold (lock_alive l #p v);
    fold (lock_acquired l)
  } else {
    rewrite (if b then v ** GR.pts_to l.gr #0.5R 1ul else emp) as
            emp;
    fold (lock_alive l #p v);
    acquire l
  }
}
```

```pulse
fn release (#v:vprop) (#p:perm) (l:lock)
  requires lock_alive l #p v ** lock_acquired l ** v
  ensures lock_alive l #p v
{
  unfold (lock_alive l #p v);
  unfold (lock_acquired l);

  with_invariants (iref_of l.i)
    returns _:unit
    ensures inv (iref_of l.i) (cinv_vp l.i (lock_inv l.r l.gr v)) **
            active p l.i {
    unpack_cinv_vp l.i;
    unfold (lock_inv l.r l.gr v);
    unfold (lock_inv_aux l.r l.gr v);
    GR.pts_to_injective_eq l.gr;
    GR.gather2 l.gr;
    rewrite (if (1ul = 0ul) then v else emp) as emp;
    write_atomic_box l.r 0ul;
    GR.(l.gr := 0ul);
    fold (lock_inv_aux l.r l.gr v);
    fold (lock_inv l.r l.gr v);
    pack_cinv_vp l.i;
  };

  fold (lock_alive l #p v)
}
```

```pulse
ghost
fn share (#v:vprop) (#p:perm) (l:lock)
  requires lock_alive l #p v
  ensures lock_alive l #(p /. 2.0R) v ** lock_alive l #(p /. 2.0R) v
{
  unfold (lock_alive l #p v);
  Pulse.Lib.CancellableInvariant.share l.i;
  dup_inv (iref_of l.i) (cinv_vp l.i (lock_inv l.r l.gr v));  // make this arg implicit
  fold (lock_alive l #(p /. 2.0R) v);
  fold (lock_alive l #(p /. 2.0R) v)
} 
```

let share2 #v l = share #v #1.0R l

```pulse
ghost
fn gather (#v:vprop) (#p1 #p2 :perm) (l:lock)
  requires lock_alive l #p1 v ** lock_alive l #p2 v
  ensures lock_alive l #(p1 +. p2) v
{
  unfold (lock_alive l #p1 v);
  unfold (lock_alive l #p2 v);
  Pulse.Lib.CancellableInvariant.gather #p1 #p2 l.i;
  fold (lock_alive l #(p1 +. p2) v);
  drop_ (inv _ _)
} 
```

let gather2 #v l = gather #v #0.5R #0.5R l

```pulse
fn free (#v:vprop) (l:lock)
  requires lock_alive l #1.0R v ** lock_acquired l
  ensures emp
{
  unfold (lock_alive l #1.0R v);
  unfold (lock_acquired l);
  cancel l.i;
  unfold (lock_inv l.r l.gr v);
  unfold (lock_inv_aux l.r l.gr v);
  B.free l.r;
  GR.gather l.gr;
  GR.free l.gr;
  rewrite (if (1ul = 0ul) then v else emp) as emp
}
```

```pulse
ghost
fn lock_alive_inj
  (l:lock) (#p1 #p2 :perm) (#v1 #v2 :vprop)
  requires lock_alive l #p1 v1 ** lock_alive l #p2 v2
  ensures  lock_alive l #p1 v1 ** lock_alive l #p2 v1
{
  unfold (lock_alive l #p1 v1);
  unfold (lock_alive l #p2 v2);
  invariant_name_identifies_invariant
    (iref_of l.i) (iref_of l.i);
  assert (
    pure (
      cinv_vp l.i (lock_inv l.r l.gr v1)
      ==
      cinv_vp l.i (lock_inv l.r l.gr v2)
    )
  );
  fold (lock_alive l #p1 v1);
  fold (lock_alive l #p2 v1);
}
```
