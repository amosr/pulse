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

module Pulse.Checker.AssertWithBinders

open Pulse.Syntax
open Pulse.Typing
open Pulse.Checker.Base
open Pulse.Elaborate.Pure
open Pulse.Typing.Env

module L = FStar.List.Tot
module T = FStar.Tactics.V2
module R = FStar.Reflection.V2
module RT = FStar.Reflection.Typing
module PC = Pulse.Checker.Pure
module P = Pulse.Syntax.Printer
module N = Pulse.Syntax.Naming
module PS = Pulse.Checker.Prover.Substs
module Prover = Pulse.Checker.Prover
module Env = Pulse.Typing.Env
open Pulse.Show
module RU = Pulse.RuntimeUtils

let is_host_term (t:R.term) = not (R.Tv_Unknown? (R.inspect_ln t))

let debug_log = Pulse.Typing.debug_log "with_binders"

let option_must (f:option 'a) (msg:string) : T.Tac 'a =
  match f with
  | Some x -> x
  | None -> T.fail msg

let rec refl_abs_binders (t:R.term) (acc:list binder) : T.Tac (list binder) =
  let open R in
  match inspect_ln t with
  | Tv_Abs b body ->
    let {sort; ppname} = R.inspect_binder b in
    refl_abs_binders body
     ((mk_binder_ppname sort (mk_ppname ppname (RU.range_of_term t)))::acc)
  | _ -> L.rev acc  

let infer_binder_types (g:env) (bs:list binder) (v:vprop)
  : T.Tac (list binder) =
  match bs with
  | [] -> []
  | _ ->
    let v_rng = Pulse.RuntimeUtils.range_of_term v in
    let g = push_context g "infer_binder_types" v_rng in
    let as_binder (b:binder) : R.binder =
      let open R in
      let bv : binder_view = 
        { sort = b.binder_ty;
          ppname = b.binder_ppname.name;
          qual = Q_Explicit;
          attrs = [] } in
      pack_binder bv
    in
    let abstraction = 
      L.fold_right 
        (fun b (tv:term) -> 
         let b = as_binder b in
         R.pack_ln (R.Tv_Abs b tv))
        bs
        v
    in
    let inst_abstraction, _ = PC.instantiate_term_implicits g (wr abstraction v_rng) in
    refl_abs_binders inst_abstraction []

let rec open_binders (g:env) (bs:list binder) (uvs:env { disjoint uvs g }) (v:term) (body:st_term)
  : T.Tac (uvs:env { disjoint uvs g } & term & st_term) =

  match bs with
  | [] -> (| uvs, v, body |)
  | b::bs ->
    // these binders are only lax checked so far
    let _ = PC.check_universe (push_env g uvs) b.binder_ty in
    let x = fresh (push_env g uvs) in
    let ss = [ RT.DT 0 (tm_var {nm_index=x;nm_ppname=b.binder_ppname}) ] in
    let bs = L.mapi (fun i b ->
      assume (i >= 0);
      subst_binder b (shift_subst_n i ss)) bs in
    let v = subst_term v (shift_subst_n (L.length bs) ss) in
    let body = subst_st_term body (shift_subst_n (L.length bs) ss) in
    open_binders g bs (push_binding uvs x b.binder_ppname b.binder_ty) v body

let closing (bs:list (ppname & var & typ)) : subst =
  L.fold_right (fun (_, x, _) (n, ss) ->
    n+1,
    (RT.ND x n)::ss
  ) bs (0, []) |> snd

let rec close_binders (bs:list (ppname & var & typ))
  : Tot (list binder) (decreases L.length bs) =
  match bs with
  | [] -> []
  | (name, x, t)::bs ->
    let bss = L.mapi (fun n (n1, x1, t1) ->
      assume (n >= 0);
      n1, x1, subst_term t1 [RT.ND x n]) bs in
    let b = mk_binder_ppname t name in
    assume (L.length bss == L.length bs);
    b::(close_binders bss)

let unfold_defs (g:env) (defs:option (list string)) (t:term) 
  : T.Tac term
  = let head, _ = T.collect_app t in
    match R.inspect_ln head with
    | R.Tv_FVar fv
    | R.Tv_UInst fv _ -> (
        let head = String.concat "." (R.inspect_fv fv) in
        let fully = 
          match defs with
          | Some defs -> defs
          | None -> []
        in
        let rt = RU.unfold_def (fstar_env g) head fully t in
        option_must rt
          (Printf.sprintf "unfolding %s returned None" (T.term_to_string t))
      )
    | _ ->
      fail g (Some (RU.range_of_term t))
        (Printf.sprintf "Cannot unfold %s, the head is not an fvar" (T.term_to_string t))

let check_unfoldable g (v:term) : T.Tac unit =
  match inspect_term v with
  | Tm_FStar _ -> ()
  | _ -> 
   fail g 
      (Some (Pulse.RuntimeUtils.range_of_term v))
      (Printf.sprintf "`fold` and `unfold` expect a single user-defined predicate as an argument, \
                        but %s is a primitive term that cannot be folded or unfolded"
                        (P.term_to_string v))

let visit_and_rewrite (p: (R.term & R.term)) (t:term) : T.Tac term =
  let open FStar.Reflection.V2.TermEq in
  let lhs, rhs = p in
  let visitor (t:R.term) : T.Tac R.term =
    if term_eq t lhs then rhs else t
  in
  match R.inspect_ln lhs with
  | R.Tv_Var n -> (
    let nv = R.inspect_namedv n in
    assume (is_host_term rhs);
    subst_term t [RT.NT nv.uniq (wr rhs (Pulse.RuntimeUtils.range_of_term t))]
    ) 
  | _ -> FStar.Tactics.Visit.visit_tm visitor t
    
let visit_and_rewrite_conjuncts (p: (R.term & R.term)) (tms:list term) : T.Tac (list term) =
  T.map (visit_and_rewrite p) tms

let visit_and_rewrite_conjuncts_all (p: list (R.term & R.term)) (goal:term) : T.Tac (term & term) =
  let tms = Pulse.Typing.Combinators.vprop_as_list goal in
  let tms' = T.fold_left (fun tms p -> visit_and_rewrite_conjuncts p tms) tms p in
  assume (L.length tms' == L.length tms);
  let lhs, rhs =
    T.fold_left2 
      (fun (lhs, rhs) t t' ->  
        if eq_tm t t' then lhs, rhs
        else (t::lhs, t'::rhs))
      ([], [])
      tms tms'
  in
  Pulse.Typing.Combinators.list_as_vprop lhs,
  Pulse.Typing.Combinators.list_as_vprop rhs
  

let disjoint (dom:list var) (cod:Set.set var) =
  L.for_all (fun d -> not (Set.mem d cod)) dom

let rec as_subst (p : list (term & term)) 
                 (out:list subst_elt)
                 (domain:list var)
                 (codomain:Set.set var)
  : option (list subst_elt) =
  match p with
  | [] -> 
    if disjoint domain codomain
    then Some out
    else None
  | (e1, e2)::p -> (
    match R.inspect_ln e1 with
    | R.Tv_Var n -> (
      let nv = R.inspect_namedv n in
      as_subst p 
        (RT.NT nv.uniq e2::out) 
        (nv.uniq ::domain )
        (Set.union codomain (freevars e2))
    ) 
    | _ -> None
  )



let rewrite_all (g:env) (p: list (term & term)) (t:term) : T.Tac (term & term) =
  match as_subst p [] [] Set.empty with
  | Some s ->
    t, subst_term t s
  | _ ->
    let p : list (R.term & R.term) = 
      T.map 
        (fun (e1, e2) -> 
          (fst (Pulse.Checker.Pure.instantiate_term_implicits g e1)),
          (fst (Pulse.Checker.Pure.instantiate_term_implicits g e2)))
        p
    in
    let lhs, rhs = visit_and_rewrite_conjuncts_all p t in
    debug_log g (fun _ -> Printf.sprintf "Rewrote %s to %s" (P.term_to_string lhs) (P.term_to_string rhs));
    lhs, rhs

let check_renaming 
    (g:env)
    (pre:term)
    (st:st_term { 
        match st.term with
        | Tm_ProofHintWithBinders { hint_type = RENAME _ } -> true
        | _ -> false
    })
: T.Tac st_term
= let Tm_ProofHintWithBinders ht = st.term in
  let { hint_type=RENAME { pairs; goal }; binders=bs; t=body } = ht in
  match bs, goal with
  | _::_, None ->
   //if there are binders, we must have a goal
    fail g (Some st.range) "A renaming with binders must have a goal (with xs. rename ... in goal)"

  | _::_, Some goal -> 
   //rewrite it as
   // with bs. assert goal;
   // rename [pairs] in goal;
   // ...
   let body = {st with term = Tm_ProofHintWithBinders { ht with binders = [] }} in
   { st with term = Tm_ProofHintWithBinders { hint_type=ASSERT { p = goal }; binders=bs; t=body } }

  | [], None ->
    // if there is no goal, take the goal to be the full current pre
    let lhs, rhs = rewrite_all g pairs pre in
    let t = { st with term = Tm_Rewrite { t1 = lhs; t2 = rhs } } in
    { st with term = Tm_Bind { binder = as_binder tm_unit; head = t; body } }

  | [], Some goal -> (
      let goal, _ = PC.instantiate_term_implicits g goal in
      let lhs, rhs = rewrite_all g pairs goal in
      let t = { st with term = Tm_Rewrite { t1 = lhs; t2 = rhs } } in
      { st with term = Tm_Bind { binder = as_binder tm_unit; head = t; body } }
  )

let check_wild
      (g:env)
      (pre:term)
      (st:st_term { head_wild st })
: T.Tac st_term
= let Tm_ProofHintWithBinders ht = st.term in
  let { binders=bs; t=body } = ht in
  match bs with
  | [] ->
    fail g (Some st.range) "A wildcard must have at least one binder"

  | _ ->
    let vprops = Pulse.Typing.Combinators.vprop_as_list pre in
    let ex, rest = List.Tot.partition (fun (v:vprop) ->
                                       let vv = inspect_term v in
                                       Tm_ExistsSL? vv) vprops in
    match ex with
    | []
    | _::_::_ ->
      fail g (Some st.range) "Binding names with a wildcard requires exactly one existential quantifier in the goal"
    | [ex] ->
      let k = List.Tot.length bs in
      let rec peel_binders (n:nat) (t:term) : T.Tac st_term =
        if n = 0
        then (
          let ex_body = t in
          { st with term = Tm_ProofHintWithBinders { ht with hint_type = ASSERT { p = ex_body } }}
        )
        else (
          match inspect_term t with
          | Tm_ExistsSL u b body -> peel_binders (n-1) body
          | _ -> 
            fail g (Some st.range)
               (Printf.sprintf "Expected an existential quantifier with at least %d binders; but only found %s with %d binders"
                  k (show ex) (k - n))
        )
      in
      peel_binders k ex

//
// v is a partially applied vprop with type t
// add uvars for the remaining arguments
//
let rec add_rem_uvs (g:env) (t:typ) (uvs:env { Env.disjoint g uvs }) (v:vprop)
  : T.Tac (uvs:env { Env.disjoint g uvs } & vprop) =
  match is_arrow t with
  | None -> (| uvs, v |)
  | Some (b, qopt, c) ->
    let x = fresh (push_env g uvs) in
    let ct = open_comp_nv c (b.binder_ppname, x) in
    let uvs = Env.push_binding uvs x b.binder_ppname b.binder_ty in
    let v = tm_pureapp v qopt (tm_var {nm_index = x; nm_ppname = b.binder_ppname}) in 
    add_rem_uvs g (comp_res ct) uvs v

let check
  (g:env)
  (pre:term)
  (pre_typing:tot_typing g pre tm_vprop)
  (post_hint:post_hint_opt g)
  (res_ppname:ppname)
  (st:st_term { Tm_ProofHintWithBinders? st.term })
  (check:check_t)

  : T.Tac (checker_result_t g pre post_hint) =

  let g = push_context g "check_assert" st.range in

  let Tm_ProofHintWithBinders { hint_type; binders=bs; t=body } = st.term in

  match hint_type with
  | WILD ->
    let st = check_wild g pre st in
    check g pre pre_typing post_hint res_ppname st

  | SHOW_PROOF_STATE r ->
    let open FStar.Stubs.Pprint in
    let open Pulse.PP in
    let msg = [
      text "Current context:" ^^
            indent (pp (VPropEquiv.canon_vprop pre))
    ] in
    fail_doc_env true g (Some r) msg
  | RENAME { pairs; goal } ->
    let st = check_renaming g pre st in
    check g pre pre_typing post_hint res_ppname st

  | REWRITE { t1; t2 } -> (
    match bs with
    | [] -> 
      let t = { st with term = Tm_Rewrite { t1; t2 } } in
      check g pre pre_typing post_hint res_ppname 
          { st with term = Tm_Bind { binder = as_binder tm_unit; head = t; body } } 
    | _ ->
      let t = { st with term = Tm_Rewrite { t1; t2 } } in
      let body = { st with term = Tm_Bind { binder = as_binder tm_unit; head = t; body } } in
      let st = { st with term = Tm_ProofHintWithBinders { hint_type = ASSERT { p = t1 }; binders = bs; t = body } } in
      check g pre pre_typing post_hint res_ppname st
  )
  
  | ASSERT { p = v } ->
    FStar.Tactics.BreakVC.break_vc(); // Some stabilization
    let bs = infer_binder_types g bs v in
    let (| uvs, v_opened, body_opened |) = open_binders g bs (mk_env (fstar_env g)) v body in
    let v, body = v_opened, body_opened in
    let (| v, d |) = PC.check_vprop (push_env g uvs) v in
    let (| g1, nts, _, pre', k_frame |) = Prover.prove pre_typing uvs d in
    //
    // No need to check effect labels for the uvs solution here,
    //   since we are checking the substituted body anyway,
    //   if some of them are ghost when they shouldn't be,
    //   it will get caught
    //
    let (| x, x_ty, pre'', g2, k |) =
      check g1 (tm_star (PS.nt_subst_term v nts) pre')
              (RU.magic ()) 
              post_hint res_ppname (PS.nt_subst_st_term body nts) in
    (| x, x_ty, pre'', g2, k_elab_trans k_frame k |)


  | UNFOLD { names; p=v }
  | FOLD { names; p=v } ->

    let (| uvs, v_opened, body_opened |) =
      let bs = infer_binder_types g bs v in
      open_binders g bs (mk_env (fstar_env g)) v body in

    check_unfoldable g v;

    let v_opened, t_rem = PC.instantiate_term_implicits (push_env g uvs) v_opened in

    let uvs, v_opened =
      let (| uvs_rem, v_opened |) =
        add_rem_uvs (push_env g uvs) t_rem (mk_env (fstar_env g)) v_opened in
      push_env uvs uvs_rem, v_opened in

    let lhs, rhs =
      match hint_type with      
      | UNFOLD _ ->
        v_opened,
        unfold_defs (push_env g uvs) None v_opened
      | FOLD { names=ns } -> 
        unfold_defs (push_env g uvs) ns v_opened,
        v_opened in

    let uvs_bs = uvs |> bindings_with_ppname |> L.rev in
    let uvs_closing = uvs_bs |> closing in
    let lhs = subst_term lhs uvs_closing in
    let rhs = subst_term rhs uvs_closing in
    let body = subst_st_term body_opened uvs_closing in
    let bs = close_binders uvs_bs in
    let rw = { term = Tm_Rewrite { t1 = lhs;
                                   t2 = rhs };
               range = st.range;
               effect_tag = as_effect_hint STT_Ghost } in
    let st = { term = Tm_Bind { binder = as_binder (wr (`unit) st.range);
                                head = rw; body };
               range = st.range;
               effect_tag = body.effect_tag } in

    let st =
      match bs with
      | [] -> st
      | _ ->
        { term = Tm_ProofHintWithBinders { hint_type = ASSERT { p = lhs };
                                           binders = bs;
                                           t = st };
          range = st.range;
          effect_tag = st.effect_tag } in
    check g pre pre_typing post_hint res_ppname st
