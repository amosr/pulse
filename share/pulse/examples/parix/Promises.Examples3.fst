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

module Promises.Examples3

open Pulse.Lib.Pervasives
open Pulse.Lib.Pledge
open Pulse.Lib.InvList
module GR = Pulse.Lib.GhostReference

assume val done : ref bool
assume val res : ref (option int)
assume val claimed : GR.ref bool

let inv_p : v:vprop { is_big v } =
  exists* (v_done:bool) (v_res:option int) (v_claimed:bool).
       pts_to done #0.5R v_done
    ** pts_to res #0.5R v_res
    ** GR.pts_to claimed #0.5R v_claimed
    ** (if not v_claimed then pts_to res #0.5R v_res else emp)
    ** pure (v_claimed ==> v_done)
    ** pure (v_done ==> Some? v_res)

let goal : vprop =
  exists* v_res. pts_to res #0.5R v_res ** pure (Some? v_res)


```pulse
atomic
fn proof
   (i : iref) (_:unit)
   requires inv i inv_p ** pts_to done #0.5R true ** GR.pts_to claimed #0.5R false
   ensures inv i inv_p ** pts_to done #0.5R true ** goal
   opens add_inv emp_inames i
{
  with_invariants i {
    unfold inv_p;
    with v_done v_res v_claimed.
      assert (pts_to done #0.5R v_done
              ** pts_to res #0.5R v_res
              ** GR.pts_to claimed #0.5R v_claimed
              ** (if not v_claimed then pts_to res #0.5R v_res else emp)
              ** pure (v_claimed ==> v_done)
              ** pure (v_done ==> Some? v_res));

    pts_to_injective_eq #_ #0.5R #0.5R #v_done #true done;
    assert (pure (v_done == true));
    
    GR.gather2 #bool
      claimed
      #false #v_claimed;
    assert (pure (v_claimed == false));

    // NB: this step is very sensitive to ordering
    rewrite ((if not v_claimed then pts_to res #0.5R v_res else emp) ** emp)
         as (pts_to res #0.5R v_res ** (if not true then pts_to res #0.5R v_res else emp));

    GR.op_Colon_Equals claimed true;
    
    fold goal;
    
    GR.share2 #_ claimed;
    
    fold inv_p;
    
    drop_ (GR.pts_to claimed #0.5R true);

    ()
  }
}
```

let is (i:iref) : invlist = [(inv_p <: vprop), i]

let cheat_proof (i:iref)
  : (_:unit) ->
      stt_ghost unit (add_inv emp_inames i)
        (requires pts_to done #0.5R true ** (inv i inv_p ** GR.pts_to claimed #0.5R false))
        (ensures fun _ -> pts_to done #0.5R true ** goal)
  = admit() //proof is atomic, not ghost

// #set-options "--debug SMTQuery"

```pulse
fn setup (_:unit)
   requires pts_to done 'v_done ** pts_to res 'v_res ** GR.pts_to claimed 'v_claimed
   returns i:iref
   ensures pts_to done #0.5R false **
           pledge (add_inv emp_inames i) (pts_to done #0.5R true) goal
{
  done := false;
  res := None;
  GR.op_Colon_Equals claimed false;
  
  share2 #_ done;
  share2 #_ res;
  GR.share2 #_ claimed;
  
  rewrite (pts_to res #0.5R None)
       as (if not false then  pts_to res #0.5R None else emp);
       
  fold inv_p;
  
  let i = new_invariant inv_p;

  make_pledge
    (add_inv emp_inames i)
    (pts_to done #0.5R true) //f
    goal  //v
    (inv i inv_p ** GR.pts_to claimed #0.5R false)  //extra
    (cheat_proof i);

  i
}
```

[@@expect_failure] // block is not atomic/ghost
```pulse
fn worker (i : inv inv_p) (_:unit)
   requires pts_to done #0.5R false
   ensures pts_to done #0.5R true
{
  with_invariants i {
    unfold inv_p;
    with v_done v_res v_claimed.
      assert (pts_to done #0.5R v_done
              ** pts_to res #0.5R v_res
              ** GR.pts_to claimed #0.5R v_claimed
              ** (if not v_claimed then pts_to res #0.5R v_res else emp)
              ** pure (v_claimed ==> v_done)
              ** pure (v_done ==> Some? v_res));

    gather2 #_ done #false #v_done;
    assert (pts_to done false);
    
    assert (pure (not v_claimed)); // contrapositive from v_done=false

    rewrite (if not v_claimed then pts_to res #0.5R v_res else emp)
         as pts_to res #0.5R v_res;
         
    gather2 #_ res #v_res #v_res;
    assert (pts_to res v_res);
    
    
    (* The main sketchy part here: two steps! But we see how
    to fix this by either:
      - Adding a lock and a ghost bool reference
      - Using a monotonic reference for the result, so once we
        set it to Some we know it must remain so. This allows
        to not have a lock for this. It would be two with_invariant
        steps.
    *)
    res := Some 42;
    done := true;
    
    share2 #_ res;

    rewrite (pts_to res #0.5R (Some 42))
        as (if not v_claimed then pts_to res #0.5R (Some 42) else emp);
        
    share2 #_ done;
    
    fold inv_p;

    ()
  };
}
```
