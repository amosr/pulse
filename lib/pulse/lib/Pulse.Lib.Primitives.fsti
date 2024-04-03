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

module Pulse.Lib.Primitives

open PulseCore.Observability
open Pulse.Lib.Core
open PulseCore.FractionalPermission
open Pulse.Main
open Pulse.Lib.Reference
open FStar.Ghost

module U32 = FStar.UInt32
module B = Pulse.Lib.Box

/// This module provides primitive atomic operations that are not
/// meant to be extracted to C (since they are intended to be
/// implemented by handwritten C code.) Thus, please use Karamel
/// option `-library Pulse.Lib.Primitives`

val read_atomic (r:ref U32.t) (#n:erased U32.t) (#p:perm)
  : stt_atomic U32.t #Observable emp_inames
    (pts_to r #p n)
    (fun x -> pts_to r #p n ** pure (reveal n == x))

val write_atomic (r:ref U32.t) (x:U32.t) (#n:erased U32.t)
  : stt_atomic unit #Observable emp_inames
        (pts_to r n) 
        (fun _ -> pts_to r (hide x))

val cas (r:ref U32.t) (u v:U32.t) (#i:erased U32.t)
  : stt_atomic bool #Observable emp_inames 
    (pts_to r i)
    (fun b ->
      cond b (pts_to r v ** pure (reveal i == u)) 
             (pts_to r i))

val read_atomic_box (r:B.box U32.t) (#n:erased U32.t) (#p:perm)
  : stt_atomic U32.t emp_inames
    (B.pts_to r #p n)
    (fun x -> B.pts_to r #p n ** pure (reveal n == x))

val write_atomic_box (r:B.box U32.t) (x:U32.t) (#n:erased U32.t)
  : stt_atomic unit emp_inames
        (B.pts_to r n) 
        (fun _ -> B.pts_to r (hide x))

val cas_box (r:B.box U32.t) (u v:U32.t) (#i:erased U32.t)
  : stt_atomic bool #Observable emp_inames 
    (B.pts_to r i)
    (fun b ->
      cond b (B.pts_to r v ** pure (reveal i == u)) 
             (B.pts_to r i))
