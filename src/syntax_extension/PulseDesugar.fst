module PulseDesugar
open FStar.Compiler.Effect
module Sugar = PulseSugar
module SW = PulseSyntaxWrapper
module A = FStar.Parser.AST
module D = FStar.Syntax.DsEnv
module ToSyntax = FStar.ToSyntax.ToSyntax
open FStar.Ident
open FStar.List.Tot
module S = FStar.Syntax.Syntax
module L = FStar.Compiler.List
module U = FStar.Syntax.Util
module TcEnv = FStar.TypeChecker.Env
module SS = FStar.Syntax.Subst
module R = FStar.Compiler.Range
module BU = FStar.Compiler.Util
module P =  FStar.Syntax.Print

let err a = nat -> either a error & nat

let (let?) (f:err 'a) (g: 'a -> ML (err 'b)) =
  fun ctr ->
    match f ctr with
    | Inl a, ctr -> g a ctr
    | Inr e, ctr -> Inr e, ctr

let return (x:'a) : err 'a = fun ctr -> Inl x, ctr

let fail #a (message:string) (range:R.range) : err a =
  fun ctr -> Inr (Some (message, range)), ctr

let fail_if (b:bool) (message:string) (range:R.range) : err unit =
  if b then fail message range else return ()

// Fail without logging another error
let just_fail (#a:Type) () : err a =
  fun ctr -> Inr None, ctr

let next_ctr : err nat = fun ctr -> Inl (ctr + 1), ctr + 1

let rec map_err (f:'a -> err 'b) (l:list 'a)
  : err (list 'b)
  = match l with
    | [] -> return []
    | hd::tl ->
      let? hd = f hd in
      let? tl = map_err f tl in
      return (hd :: tl)


let rec fold_err (f:'b -> 'a -> err 'b) (l:list 'a) (x:'b)
  : err 'b
  = match l with
    | [] -> return x
    | hd::tl ->
      let? x = f x hd in
      fold_err f tl x

let map_err_opt (f : 'a -> err 'b) (o:option 'a) : err (option 'b) =
  match o with
  | None -> return None
  | Some v -> let? v' = f v in return (Some v')

let as_term (t:S.term)
  : SW.term
  = match t.n with
    | S.Tm_unknown ->
      SW.tm_unknown t.pos
    | _ -> 
      SW.tm_expr t t.pos

type env_t = { 
  tcenv: TcEnv.env;
  local_refs: list ident
}


let push_bv env x =
  let dsenv, bv = D.push_bv env.tcenv.dsenv x in
  let tcenv = { env.tcenv with dsenv = dsenv } in
  let env = { env with tcenv } in
  env, bv

let rec push_bvs env xs =
  match xs with
  | [] -> env, []
  | x::xs ->
    let env, bv = push_bv env x in
    let env, bvs = push_bvs env xs in
    env, bv::bvs

let push_namespace env lid =
  let dsenv = D.push_namespace env.tcenv.dsenv lid in
  let tcenv = { env.tcenv with dsenv } in
  let env = {env with tcenv} in
  env
  
let desugar_const (c:FStar.Const.sconst) : SW.constant =
  SW.inspect_const c

let r_ = FStar.Compiler.Range.dummyRange
open FStar.List.Tot
#push-options "--warn_error -272" //intentional top-level effects
let admit_lid = Ident.lid_of_path ["Prims"; "admit"] r_
let pulse_lib_core_lid l = Ident.lid_of_path (["Pulse"; "Lib"; "Core"]@[l]) r_
let pulse_lib_ref_lid l = Ident.lid_of_path (["Pulse"; "Lib"; "Reference"]@[l]) r_
let prims_exists_lid = Ident.lid_of_path ["Prims"; "l_Exists"] r_
let prims_forall_lid = Ident.lid_of_path ["Prims"; "l_Forall"] r_
let exists_lid = pulse_lib_core_lid "op_exists_Star"
let star_lid = pulse_lib_core_lid "op_Star_Star"
let emp_lid = pulse_lib_core_lid "emp"
let pure_lid = pulse_lib_core_lid "pure"
let stt_lid = pulse_lib_core_lid "stt"
let assign_lid = pulse_lib_ref_lid "op_Colon_Equals"
let stt_ghost_lid = pulse_lib_core_lid "stt_ghost"
let stt_atomic_lid = pulse_lib_core_lid "stt_atomic"
let op_colon_equals_lid r = Ident.lid_of_path ["op_Colon_Equals"] r
let op_array_assignment_lid r = Ident.lid_of_path ["op_Array_Assignment"] r
let op_bang_lid = pulse_lib_ref_lid "op_Bang"
#pop-options
let read (x:ident) = 
  let open A in
  let range = Ident.range_of_id x in
  let level = Un in
  let head : A.term = {tm = Var op_bang_lid; range; level} in
  let arg = {tm = Var (Ident.lid_of_ids [x]); range; level} in
  {tm = App (head, arg, Nothing); range; level}

let stapp_assignment assign_lid (args:list S.term) (last_arg:S.term) (r:_)
  : SW.st_term
  = let head_fv = S.lid_as_fv assign_lid None in
    let head = S.fv_to_tm head_fv in
    let app = 
      L.fold_left 
        (fun head (arg:S.term) ->
          S.mk_Tm_app head [(arg, None)] arg.pos)
        head args
    in
    SW.(tm_st_app (tm_expr app r) None (as_term last_arg) r)

let resolve_lid (env:env_t) (lid:lident)
  : err lident
  = match D.try_lookup_lid env.tcenv.dsenv lid with
    | None -> fail (BU.format1 "Name %s not found" (Ident.string_of_lid lid)) (Ident.range_of_lid lid)
    | Some t ->
      match (SS.compress t).n with
      | S.Tm_fvar fv -> return (S.lid_of_fv fv)
      | _ -> fail (BU.format2 "Name %s resolved unexpectedly to %s" (Ident.string_of_lid lid) (P.term_to_string t))
                  (Ident.range_of_lid lid)

let ret (s:S.term) = SW.(tm_return (as_term s) s.pos)

type admit_or_return_t =
  | STTerm : SW.st_term -> admit_or_return_t
  | Return : S.term -> admit_or_return_t

let st_term_of_admit_or_return (t:admit_or_return_t) : SW.st_term =
  match t with
  | STTerm t -> t
  | Return t -> ret t

let admit_or_return (env:env_t) (s:S.term)
  : admit_or_return_t
  = let r = s.pos in
    let head, args = U.head_and_args_full s in
    match head.n with
    | S.Tm_fvar fv -> (
      if S.fv_eq_lid fv admit_lid
      then STTerm (SW.tm_admit r) 
      else Return s
    )
    | _ -> Return s

let prepend_ctx_issue (c : Pprint.document) (i : Errors.issue) : Errors.issue =
  { i with issue_msg = c :: i.issue_msg }


let tosyntax' (env:env_t) (t:A.term)
  : err S.term
  = try 
      return (ToSyntax.desugar_term env.tcenv.dsenv t)
    with 
      | e -> 
        match FStar.Errors.issue_of_exn e with
        | Some i ->
          let i = prepend_ctx_issue (Pprint.arbitrary_string "Failed to desugar Pulse term") i in
          FStar.Errors.add_issues [i];
          just_fail ()

        | None -> 
          fail (BU.format2 "Failed to desugar Pulse term %s\nUnexpected exception: %s\n"
                             (A.term_to_string t)
                             (SW.print_exn e))
                t.range

let tosyntax (env:env_t) (t:A.term)
  : err S.term
  = let? s = tosyntax' env t in
    return s

let desugar_term (env:env_t) (t:A.term)
  : err SW.term 
  = let? s = tosyntax env t in
    return (as_term s)
  
let desugar_term_opt (env:env_t) (t:option A.term)
  : err SW.term
  = match t with
    | None -> return (SW.tm_unknown FStar.Compiler.Range.dummyRange)
    | Some e -> desugar_term env e

let rec interpret_vprop_constructors (env:env_t) (v:S.term)
  : err SW.term
  = let head, args = U.head_and_args_full v in
    match head.n, args with
    | S.Tm_fvar fv, [(l, _)]
      when S.fv_eq_lid fv pure_lid ->
      let res = SW.tm_pure (as_term l) v.pos in
      return res
    
    | S.Tm_fvar fv, []
      when S.fv_eq_lid fv emp_lid ->
      return <| SW.tm_emp v.pos
      
    | S.Tm_fvar fv, [(l, _); (r, _)]
      when S.fv_eq_lid fv star_lid ->
      let? l = interpret_vprop_constructors env l in
      let? r = interpret_vprop_constructors env r in
      return <| SW.tm_star l r v.pos

    | S.Tm_fvar fv, [(l, _)]
      when S.fv_eq_lid fv exists_lid -> (
        match (SS.compress l).n with
        | S.Tm_abs {bs=[b]; body } ->
          let b = SW.mk_binder b.S.binder_bv.ppname (as_term b.S.binder_bv.sort) in
          let? body = interpret_vprop_constructors env body in
          return <| SW.tm_exists b body v.pos
        | _ ->
          return <| as_term v
      )
      
    | S.Tm_fvar fv, [(l, _)]
      when S.fv_eq_lid fv prims_exists_lid
      ||   S.fv_eq_lid fv prims_forall_lid -> (
      fail "exists/forall are prop connectives; you probably meant to use exists*/forall*" v.pos  
      )

    | _ ->
      return <| as_term v
  
let desugar_vprop (env:env_t) (v:Sugar.vprop)
  : err SW.vprop
  = match v.v with
    | Sugar.VPropTerm t -> 
      let? t = tosyntax env t in
      interpret_vprop_constructors env t

let mk_totbind b s1 s2 r : SW.st_term =
  SW.tm_totbind b s1 s2 r

let mk_bind b s1 s2 r : SW.st_term = 
  SW.tm_bind b s1 s2 r

let explicit_rvalues (env:env_t) (s:Sugar.stmt)
  : Sugar.stmt
  = s

let qual = option SW.qualifier
let as_qual (q:A.aqual) : qual =
  match q with
  | Some A.Implicit -> SW.as_qual true
  | _ -> SW.as_qual false

let resolve_names (env:env_t) (ns:option (list lident)) 
  : err (option (list lident))
  = match ns with
    | None -> return None
    | Some ns -> let? ns = map_err (resolve_lid env) ns in return (Some ns)

let desugar_hint_type (env:env_t) (ht:Sugar.hint_type)
  : err SW.hint_type
  = let open Sugar in
    match ht with
    | ASSERT vp ->
      let? vp = desugar_vprop env vp in
      return (SW.mk_assert_hint_type vp)
    | UNFOLD (ns, vp) -> 
      let? vp = desugar_vprop env vp in
      let? ns = resolve_names env ns in
      let ns = BU.map_opt ns (L.map FStar.Ident.string_of_lid) in
      return (SW.mk_unfold_hint_type ns vp)
    | FOLD (ns, vp) -> 
      let? vp = desugar_vprop env vp in
      let? ns = resolve_names env ns in
      let ns = BU.map_opt ns (L.map FStar.Ident.string_of_lid) in
      return (SW.mk_fold_hint_type ns vp)
    | RENAME (pairs, goal) ->
      let? pairs =
        map_err 
          (fun (t1, t2) ->
            let? t1 = desugar_term env t1 in
            let? t2 = desugar_term env t2 in
            return (t1, t2))
          pairs
      in
      let? goal = map_err_opt (desugar_vprop env) goal in
      return (SW.mk_rename_hint_type pairs goal)
    | REWRITE (t1, t2) ->
      let? t1 = desugar_vprop env t1 in
      let? t2 = desugar_vprop env t2 in
      return (SW.mk_rewrite_hint_type t1 t2)

// FIXME
// should just mimic let resolve_lid
let desugar_datacon (env:env_t) (l:lid) : err SW.fv =
  let rng = Ident.range_of_lid l in
  let t = A.mk_term (A.Name l) rng A.Expr in
  let? tt = tosyntax env t in
  let? sfv =
    match (SS.compress tt).n with
    | S.Tm_fvar fv -> return fv
    | S.Tm_uinst ({n = S.Tm_fvar fv}, _) -> return fv
    | _ -> fail (BU.format1 "Not a datacon? %s" (Ident.string_of_lid l)) rng
  in
  return (SW.mk_fv (S.lid_of_fv sfv) rng)

(* s has already been transformed with explicit dereferences for r-values *)
let rec desugar_stmt (env:env_t) (s:Sugar.stmt)
  : err SW.st_term
  = let open SW in
    let open Sugar in
    match s.s with
    | Expr { e } -> 
      let? tm = tosyntax env e in
      return (st_term_of_admit_or_return (admit_or_return env tm))

    | Assignment { lhs; value } ->
      let? lhs = tosyntax env lhs in
      let? rhs = tosyntax env value in
      let? assignment_lid = resolve_lid env (op_colon_equals_lid s.range) in
      return (stapp_assignment assignment_lid [lhs] rhs s.range)

    | ArrayAssignment { arr; index; value } ->
      let? arr = tosyntax env arr in
      let? index = tosyntax env index in
      let? value = tosyntax env value in      
      let? array_assignment_lid = resolve_lid env (op_array_assignment_lid s.range) in
      return (stapp_assignment array_assignment_lid [arr;index] value s.range)
    
    | Sequence { s1={s=Open l}; s2 } ->
      let env = push_namespace env l in
      desugar_stmt env s2

    | Sequence { s1={s=LetBinding lb}; s2 } ->
      desugar_bind env lb s2 s.range

    | ProofHintWithBinders _ ->
      desugar_proof_hint_with_binders env s None s.range

    | Sequence { s1; s2 } when ProofHintWithBinders? s1.s ->
      desugar_proof_hint_with_binders env s1 (Some s2) s.range

    | Sequence { s1; s2 } -> 
      desugar_sequence env s1 s2 s.range
      
    | Block { stmt } ->
      desugar_stmt env stmt

    | If { head; join_vprop; then_; else_opt } -> 
      let? head = desugar_term env head in
      let? join_vprop =
        match join_vprop with
        | None -> return None
        | Some t -> 
          let? vp = desugar_vprop env t in
          return (Some vp)
      in
      let? then_ = desugar_stmt env then_ in
      let? else_ = 
        match else_opt with
        | None -> 
          return (tm_return (tm_expr S.unit_const R.dummyRange) R.dummyRange)
        | Some e -> 
          desugar_stmt env e
      in
      return (SW.tm_if head join_vprop then_ else_ s.range)

    | Match { head; returns_annot; branches } ->
      let? head = desugar_term env head in
      let? returns_annot = map_err_opt (desugar_vprop env) returns_annot in
      let? branches = map_err (desugar_branch env) branches in
      return (SW.tm_match head returns_annot branches s.range)

    | While { guard; id; invariant; body } ->
      let? guard = desugar_stmt env guard in
      let? invariant = 
        let env, bv = push_bv env id in
        let? inv = desugar_vprop env invariant in
        return (SW.close_term inv bv.index)
      in
      let? body = desugar_stmt env body in
      return (SW.tm_while guard (id, invariant) body s.range)

    | Introduce { vprop; witnesses } -> (
      let? vp = desugar_vprop env vprop in
      fail_if (not (SW.is_tm_exists vp)) "introduce expects an existential formula" s.range ;?
      let? witnesses = map_err (desugar_term env) witnesses in
      return (SW.tm_intro_exists vp witnesses s.range)
    )

    | Parallel { p1; p2; q1; q2; b1; b2 } ->
      let? p1 = desugar_vprop env p1 in
      let? p2 = desugar_vprop env p2 in
      let? q1 = desugar_vprop env q1 in
      let? q2 = desugar_vprop env q2 in      
      let? b1 = desugar_stmt env b1 in
      let? b2 = desugar_stmt env b2 in
      return (SW.tm_par p1 p2 q1 q2 b1 b2 s.range)

    | Rewrite { p1; p2 } ->
      let? p1 = desugar_vprop env p1 in
      let? p2 = desugar_vprop env p2 in
      return (SW.tm_rewrite p1 p2 s.range)
      
    | LetBinding _ -> 
      fail "Terminal let binding" s.range

    | WithInvariants { names=n1::names; body; returns_ } ->
      let? n1 = tosyntax env n1 in
      let? names = map_err (tosyntax env) names in
      let? body = desugar_stmt env body in
      let? returns_ = map_err_opt (desugar_vprop env) returns_ in
      (* the returns_ goes only to the outermost with_inv *)
      let tt = L.fold_right (fun nm body -> let nm : term = tm_expr nm s.range in SW.tm_with_inv nm body None s.range) names body in
      let n1 : term = tm_expr n1 s.range in
      return (SW.tm_with_inv n1 tt returns_ s.range)

and desugar_branch (env:env_t) (br:A.pattern & Sugar.stmt)
  : err SW.branch
  = let (p, e) = br in
    let? (p, vs) = desugar_pat env p in
    let env, bvs = push_bvs env vs in
    let? e = desugar_stmt env e in
    let e = SW.close_st_term_n e (L.map (fun (v:S.bv) -> v.index <: nat) bvs) in
    return (p,e)

and desugar_pat (env:env_t) (p:A.pattern)
  : err (SW.pattern & list ident)
  = let r = p.prange in
    match p.pat with
    | A.PatVar (id, _, _) ->
      return (SW.pat_var (Ident.string_of_id id) r, [id])
    | A.PatWild _ ->
      let id = Ident.mk_ident ("_", r) in
      return (SW.pat_var "_" r, [id])
    | A.PatConst c ->
      let c = desugar_const c in
      return (SW.pat_constant c r, [])
    | A.PatName lid ->
      let? fv = desugar_datacon env lid in
      return (SW.pat_cons fv [] r, [])
    | A.PatApp ({pat=A.PatName lid}, args) ->
      let? fv = desugar_datacon env lid in
      let? idents = map_err (fun (p:A.pattern) ->
          match p.pat with
          | A.PatVar (id, _, _) -> return id
          | A.PatWild _ -> return (Ident.mk_ident ("_", r))
          | _ -> fail "invalid pattern: no deep patterns allowed" r
      ) args
      in
      let strs = L.map Ident.string_of_id idents in
      let pats = L.map (fun s -> SW.pat_var s r) strs in
      return (SW.pat_cons fv pats r, idents)

    | _ ->
      fail "invalid pattern" r

and desugar_bind (env:env_t) (lb:_) (s2:Sugar.stmt) (r:R.range)
  : err SW.st_term
  = let open Sugar in
    let? annot = desugar_term_opt env lb.typ in
    let? s2 = 
      let env, bv = push_bv env lb.id in        
      let? s2 = desugar_stmt env s2 in
      return (SW.close_st_term s2  bv.index)
    in        
    match lb.init with
    | None ->
      fail "Uninitialized variables are not yet handled" r

    | Some e1 -> (
      match lb.qualifier with
      | None -> //just a regular bind
        if Sugar.Array_initializer? e1
        then fail "immutable local arrays are not yet supported" r
        else if Sugar.Lambda_initializer? e1
        then fail "lambdas are not yet supported" r
        else (
          let Default_initializer e1 = e1 in
          let? s1 = tosyntax env e1 in
          let b = SW.mk_binder lb.id annot in
          let t =
            match admit_or_return env s1 with
            | STTerm s1 ->
              mk_bind b s1 s2 r
            | Return s1 ->
              mk_totbind b (as_term s1) s2 r
          in
          return t
        )
      | Some MUT //these are handled the same for now
      | Some REF ->
        let b = SW.mk_binder lb.id annot in
        match e1 with
        | Sugar.Array_initializer {init; len} ->
          let? init = desugar_term env init in
          let? len = desugar_term env len in
          return (SW.tm_let_mut_array b init len s2 r)
        | Sugar.Default_initializer e1 ->
          let? e1 = desugar_term env e1 in 
          return (SW.tm_let_mut b e1 s2 r)
    )

and desugar_sequence (env:env_t) (s1 s2:Sugar.stmt) r
  : err SW.st_term
  = let? s1 = desugar_stmt env s1 in
    let? s2 = desugar_stmt env s2 in
    let annot = SW.mk_binder (Ident.id_of_text "_") (SW.tm_expr S.t_unit r) in
    return (mk_bind annot s1 s2 r)

and desugar_proof_hint_with_binders (env:env_t) (s1:Sugar.stmt) (k:option Sugar.stmt) r
  : err SW.st_term
  = match s1.s with
    | Sugar.ProofHintWithBinders { hint_type; binders=bs } -> //; vprop=v } ->
      let? env, binders, bvs = desugar_binders env bs in
      let vars = L.map #_ #nat (fun bv -> bv.S.index) bvs in
      let? ht = desugar_hint_type env hint_type in
      let? s2 = 
        match k with
        | None -> return (SW.tm_ghost_return (SW.tm_expr S.unit_const r) r)
        | Some s2 -> desugar_stmt env s2 in
      let binders = L.map snd binders in
      let sub = SW.bvs_as_subst vars in
      let s2 = SW.subst_st_term sub s2 in
      let ht = SW.subst_proof_hint sub ht in
      return (SW.tm_proof_hint_with_binders ht (SW.close_binders binders vars) s2 r)
    | _ -> fail "Expected ProofHintWithBinders" s1.range

and desugar_binders (env:env_t) (bs:Sugar.binders)
  : err (env_t & list (option SW.qualifier & SW.binder) & list S.bv)
  = let rec aux env bs 
      : err (env_t & list (qual & ident & SW.term) & list S.bv)
      = match bs with
        | [] -> return (env, [], [])
        | (aq, b, t)::bs ->
          let? t = desugar_term env t in
          let env, bv = push_bv env b in
          let? env, bs, bvs = aux env bs in
          return (env, (as_qual aq, b, t)::bs, bv::bvs)
    in
    let? env, bs, bvs = aux env bs in
    return (env, L.map (fun (aq, b, t) -> aq, SW.mk_binder b t) bs, bvs)

let rec fold_right1 (f : 'a -> 'a -> 'a) (l : list 'a) : 'a =
  match l with
  | [h] -> h
  | h::t -> f h (fold_right1 f t)

let desugar_computation_type (env:env_t) (c:Sugar.computation_type)
  : err SW.comp
  = //let? pres = map_err (desugar_vprop env) c.preconditions in
    //let pre = fold_right1 (fun a b -> SW.tm_star a b c.range) pres in
    let? pre = desugar_vprop env c.precondition in

    let? ret = desugar_term env c.return_type in

    // let? opens = match c.opens with
    //             | [] -> return SW.tm_emp_inames
    //             | [i] -> desugar_term env i
    //             | _ -> fail "only one opens supported" c.range
    // in
    let? opens = match c.opens with
                 | Some t -> desugar_term env t
                 | None -> return SW.tm_emp_inames
    in

    (* Should have return_name in scope I think *)
    // let? openss = map_err (desugar_term env) c.opens in
    // let opens = L.fold_right (fun i is -> SW.tm_add_inv i is c.range) openss SW.tm_emp_inames in

    let env1, bv = push_bv env c.return_name in
    // let? posts = map_err (desugar_vprop env1) c.postconditions in
    // let post = fold_right1 (fun a b -> SW.tm_star a b c.range) posts in
    let? post = desugar_vprop env1 c.postcondition in
    let post = SW.close_term post bv.index in

    match c.tag with
    | Sugar.ST ->
      if Some? c.opens then
        fail "STT computations are not indexed by invariants. Either remove the `opens` or make this function ghost/atomic."
             (Some?.v c.opens).range
      else return ();?
      return SW.(mk_comp pre (mk_binder c.return_name ret) post)
    | Sugar.STAtomic ->
      return SW.(atomic_comp opens pre (mk_binder c.return_name ret) post)
    | Sugar.STGhost ->
      return SW.(ghost_comp opens pre (mk_binder c.return_name ret) post)

let rec free_vars_term (env:env_t) (t:A.term) =
  ToSyntax.free_vars false env.tcenv.dsenv t
and free_vars_vprop (env:env_t) (t:Sugar.vprop) =
  let open Sugar in
  match t.v with
  | VPropTerm t -> free_vars_term env t

and free_vars_binders (env:env_t) (bs:Sugar.binders)
  : env_t & list ident
  = match bs with
    | [] -> env, []
    | (_, x, t)::bs ->
      let fvs = free_vars_term env t in
      let env', res = free_vars_binders (fst (push_bv env x)) bs in
      env', fvs@res

let free_vars_list (#a:Type0) (f : env_t -> a -> list ident) (env:env_t) (xs : list a) : list ident =
  L.collect (f env) xs

let free_vars_comp (env:env_t) (c:Sugar.computation_type)
  : list ident
  = let ids =
        free_vars_vprop env c.precondition @
        free_vars_term env c.return_type @
        free_vars_vprop (fst (push_bv env c.return_name)) c.postcondition
    in
    L.deduplicate Ident.ident_equals ids

let idents_as_binders (env:env_t) (l:list ident)
  : err (env_t & list (option SW.qualifier & SW.binder) & list S.bv)
  = let erased_tm = A.(mk_term (Var FStar.Parser.Const.erased_lid) FStar.Compiler.Range.dummyRange Un) in
    let rec aux env binders bvs l 
      : err (env_t & list (option SW.qualifier & SW.binder) & list S.bv)
      = match l with
        | [] -> return (env, L.rev binders, L.rev bvs)
        | i::l ->
          let env, bv = push_bv env i in
          let qual = SW.as_qual true in
          let text = Ident.string_of_id i in
          let wild = A.(mk_term Wild (Ident.range_of_id i) Un) in
          let ty = 
            if BU.starts_with text "'"
            then A.(mkApp erased_tm [wild, A.Nothing] (Ident.range_of_id i))
            else wild
          in
          let? ty = desugar_term env ty in
          aux env ((qual, SW.mk_binder i ty)::binders) (bv::bvs) l
    in
    aux env [] [] l

(* Local mutable variables are implicitly dereferenced *)


let mutvar_entry = (ident & S.bv & option ident)

type menv = {
  //Maps local mutable variables to an
  //immutable variable storing their current value
  map:list mutvar_entry;
  env:env_t
}

let menv_push_ns (m:menv) (ns:lid) = 
  { m with env = push_namespace m.env ns }

//
// auto_deref is not applicable for mutable local arrays
//
let menv_push_bv (m:menv) (x:ident) (q:option Sugar.mut_or_ref) (auto_deref_applicable:bool) =
  let env, bv = push_bv m.env x in
  let m = { m with env } in
  if q = Some Sugar.MUT && auto_deref_applicable
  then { m with map=(x, bv, None)::m.map }
  else m

let menv_push_bvs (m:menv) (xs:_) =
  { m with env = fst (push_bvs m.env xs) }

let is_mut (m:menv) (x:S.bv) : option (option ident) =
    match L.tryFind (fun (_, y, _) -> S.bv_eq x y) m.map with
    | None -> None
    | Some (_, _, curval) -> Some curval

let needs_derefs = list (ident & ident)

let fresh_var (nm:ident)
  : err ident
  = let? ctr = next_ctr in
    let s = Ident.string_of_id nm ^ "@" ^ string_of_int ctr in
    return (Ident.mk_ident (s, Ident.range_of_id nm))

let bind_curval (m:menv) (x:ident) (curval:ident) = 
  match L.tryFind (fun (y, _, _) -> Ident.ident_equals x y) m.map with
  | None -> failwith "Impossible 1"
  | Some (x, bv, _) -> { m with map=(x, bv, Some curval)::m.map }

let clear_curval (m:menv) (x:ident) =
  match L.tryFind (fun (y, _, _) -> Ident.ident_equals x y) m.map with
  | None -> failwith "Impossible 2"
  | Some (x, bv, _) -> { m with map=(x, bv, None)::m.map }

let bind_curvals (m:menv) (l:needs_derefs) = 
  L.fold_left 
    (fun m (x, y) -> bind_curval m x y)
    m l


let resolve_mut (m:menv) (e:A.term)
  : option mutvar_entry
  = let open A in
    match e.tm with
    | Var l -> (
      let topt = FStar.Syntax.DsEnv.try_lookup_lid m.env.tcenv.dsenv l in
      match topt with
      | Some {n=S.Tm_name x} -> 
        L.tryFind (fun (_, y, _) -> S.bv_eq x y) m.map 
      | _ -> None
    )
    | _ -> None

let maybe_clear_curval (m:menv) (x:A.term)
  : menv
  = match resolve_mut m x with
    | None -> m
    | Some (x, y, _) -> { m with map = (x, y, None)::m.map }


  
let add_derefs_in_scope (n:needs_derefs) (p:Sugar.stmt)
  : Sugar.stmt
  = L.fold_right
       (fun (x, y) (p:Sugar.stmt) ->
         let lb : Sugar.stmt =
           { s=Sugar.LetBinding { qualifier=None; id=y; typ=None;
                                  init=Some (Sugar.Default_initializer (read x)) };
             range=p.range } in
         { s=Sugar.Sequence { s1=lb; s2=p }; range=p.range})
       n p

let term'_of_id (y:ident) = A.Var (Ident.lid_of_ids [y])

let rec transform_term (m:menv) (e:A.term) 
  : err (A.term & needs_derefs & menv)
  = let open A in
    match e.tm with
    | Var _ -> (
      match resolve_mut m e with
      | None -> return (e, [], m)
      | Some (x, _, None) ->
        let? y = fresh_var x in
        return ({e with tm=Var (Ident.lid_of_ids [y])}, [x, y], bind_curval m x y)
      | Some (_, _, Some y) ->
        return ({e with tm=Var (Ident.lid_of_ids [y])}, [], m)
    )
    | Op(id, tms) ->
      let? tms, needs, m =
        fold_err 
          (fun (tms, needs, m) tm ->
            let? tm, needs', m' = transform_term m tm in
            return (tm::tms, needs@needs', m'))
          tms
          ([], [], m)
      in
      let e = { e with tm = Op(id, L.rev tms) } in
      return (e, needs, m)

    | App (head, arg, imp) ->
      let? head, needs, m = transform_term m head in
      let? arg, needs', m = transform_term m arg in
      let e = { e with tm = App (head, arg, imp) } in
      return (e, needs@needs', m)
      
    | Ascribed (e, t, topt, b) ->
      let? e, needs, m = transform_term m e in
      let e = { e with tm = Ascribed (e, t, topt, b) } in
      return (e, needs, m)

    | Paren e ->
      let? e, needs, m = transform_term m e in
      let e = { e with tm = Paren e } in
      return (e, needs, m)    
    
    | Construct (lid, tms) ->
      let? tms, needs, m =
        fold_err 
          (fun (tms, needs, m) (tm, imp) ->
            let? tm, needs', m' = transform_term m tm in
            return ((tm, imp)::tms, needs@needs', m'))
          tms
          ([], [], m)
      in
      let e = { e with tm = Construct(lid, L.rev tms) } in
      return (e, needs, m)

    | LetOpen (l, t) ->
      let m = menv_push_ns m l in
      let? p, needs, _ = transform_term m t in
      return (p, needs, bind_curvals m needs)
    
    | _ -> return (e, [], m)
    

let rec transform_stmt_with_reads (m:menv) (p:Sugar.stmt)
  : err (Sugar.stmt & needs_derefs & menv)
  = let open Sugar in
    match p.s with
    | Sequence { s1; s2 } -> (
      let? (s1, needs, m) = transform_stmt_with_reads m s1 in
      let? s2 = transform_stmt m s2 in
      let p = { p with s=Sequence { s1; s2 }} in      
      return (p, needs, m)
    )
    
    | Open l ->
      return (p, [], menv_push_ns m l)

    | Expr { e } -> 
      let? e, needs, _ = transform_term m e in
      let p = { p with s = Expr { e }} in
      return (p, needs, m)

    | Assignment { lhs; value } ->
      let? value, needs, m = transform_term m value in
      let m = maybe_clear_curval m lhs in
      let s1 = { p with s = Assignment {lhs; value} } in
      return (s1, needs, m)

    | ArrayAssignment { arr; index; value } ->
      let? arr, arr_needs, m = transform_term m arr in
      let? index, index_needs, m = transform_term m index in
      let? value, value_needs, m = transform_term m value in
      let p = { p with s=ArrayAssignment {arr;index;value} } in
      return (p, arr_needs@index_needs@value_needs, m)

    | LetBinding { qualifier; id; typ; init } -> (
      let? init, needs, m =
          match init with
          | None -> return (None, [], m)
          | Some (Default_initializer e) -> (
            let mk_init e = Some (Default_initializer e) in
            match e.tm with
            | A.Var zlid -> (
              match qualifier, Ident.ids_of_lid zlid with
              | None, [z] -> (
                match resolve_mut m e with
                | None -> return (mk_init e, [], m)
                | Some (_, _, Some y) ->
                  return (mk_init { e with A.tm =term'_of_id y }, [], m)
                | Some (x, _, None) ->
                  return (mk_init (read x), [], bind_curval m x z)
              )
              | _ ->
                let? init, needs, m = transform_term m e in
                return (mk_init init, needs, m)
            )
            | _ ->
              let? init, needs, m = transform_term m e in
              return (mk_init init, needs, m)
            )
          | Some (Array_initializer {init; len}) ->
            let? init, needs, m = transform_term m init in
            let? len, len_needs, m = transform_term m len in
            return (Some (Array_initializer {init; len}), needs@len_needs, m)
          | Some (Lambda_initializer { range }) ->
            fail "Lambdas are not yet supported" range
      in
      let auto_deref_applicable =
        match init with
        | Some (Array_initializer _) -> false
        | _ -> true in
      let m = menv_push_bv m id qualifier auto_deref_applicable in
      let p = { p with s=LetBinding { qualifier; id; typ; init } } in
      return (p, needs, m)
      )

    | Block { stmt } ->
      let? stmt = transform_stmt m stmt in
      let p = { p with s=Block { stmt } } in
      return (p, [], m)

    | If { head; join_vprop; then_; else_opt } ->
      let? head, needs, m = transform_term m head in
      let? then_ = transform_stmt m then_ in
      let? else_opt =
        match else_opt with
        | None ->
          return None
        | Some else_ ->
          let? else_ = transform_stmt m else_ in
          return (Some else_)
      in
      let p = { p with s=If {head;join_vprop;then_;else_opt} } in
      return (p, needs, m)

    | Match { head; returns_annot; branches } ->
      let? head, needs, m = transform_term m head in
      let? branches = 
        map_err
          (fun (p, s) ->
            let? (_, vs) = desugar_pat m.env p in
            let m = menv_push_bvs m vs in
            let? s = transform_stmt m s in
            return (p, s))
          branches
      in
      let p = { p with s = Match { head; returns_annot; branches } } in
      return (p, needs, m)

    | While { guard; id; invariant; body } ->
      let? guard = transform_stmt m guard in
      let? body = transform_stmt m body in
      let p = { p with s = While { guard; id; invariant; body } } in
      return (p, [], m)


    | Parallel { p1; p2; q1; q2; b1; b2} ->
      let? b1 = transform_stmt m b1 in
      let? b2 = transform_stmt m b2 in
      let p = { p with s = Parallel { p1; p2; q1; q2; b1; b2 } } in
      return (p, [], m)    
    
    | Introduce _ 
    | Rewrite _
    | ProofHintWithBinders _ ->
      //This is a proof step; no implicit dereference
      return (p, [], m)


and transform_stmt (m:menv) (p:Sugar.stmt)
  : err Sugar.stmt
  = let open Sugar in
    let? p, needs, m = transform_stmt_with_reads m p in
    return (add_derefs_in_scope needs p)      

let vprop_to_ast_term (v:Sugar.vprop)
  : err A.term
  = let open FStar.Parser.AST in
    match v.v with
    | Sugar.VPropTerm t -> return t

let comp_to_ast_term (c:Sugar.computation_type) : err A.term =
  let open FStar.Parser.AST in
  let return_ty = c.return_type in
  let r = c.range in
  let head =
    match c.tag with
    | Sugar.ST ->
      let h = mk_term (Var stt_lid) r Expr in
      let h = mk_term (App (h, return_ty, Nothing)) r Expr in
      h
    | Sugar.STAtomic ->
      (* hack for now *)
      let is = mk_term (Var (Ident.lid_of_str "Pulse.Lib.Core.emp_inames")) r Expr in
      let h = mk_term (Var stt_atomic_lid) r Expr in
      let h = mk_term (App (h, return_ty, Nothing)) r Expr in
      mk_term (App (h, is, Nothing)) r Expr
    | Sugar.STGhost ->
      (* hack for now *)
      let is = mk_term (Var (Ident.lid_of_str "Pulse.Lib.Core.emp_inames")) r Expr in
      let h = mk_term (Var stt_ghost_lid) r Expr in
      let h = mk_term (App (h, return_ty, Nothing)) r Expr in
      mk_term (App (h, is, Nothing)) r Expr
  in
  let? pre = vprop_to_ast_term c.precondition in
  let? post = vprop_to_ast_term c.postcondition in
  let post =
    let pat = mk_pattern (PatVar (c.return_name, None, [])) r in
    let pat = mk_pattern (PatAscribed (pat, (return_ty, None))) r in
    mk_term (Abs ([pat], post)) r Expr
  in
  let t = mk_term (App (head, pre, Nothing)) r Expr in
  let t = mk_term (App (t, post, Nothing)) r Expr in
  return t

let rec map2 (f : 'a -> 'b -> 'c) (xs : list 'a) (ys : list 'b) : err (list 'c) =
  match xs, ys with
  | [], [] ->
    return []
  | x::xx, y::yy ->
    let? r = map2 f xx yy in
    return (f x y :: r)
  | _ ->
    fail "map2: mismatch" r_

let faux (qb : option SW.qualifier & SW.binder) (bv : S.bv)
  : option SW.qualifier & SW.binder & SW.bv
   =
    let (q,b) = qb in
    let bv = SW.mk_bv bv.S.index
                      (Ident.string_of_id bv.S.ppname)
                      bv.S.sort.pos
    in
    (q,b,bv)

let mk_knot_arr (env:env_t) (meas : option A.term) (bs:Sugar.binders) (res:Sugar.computation_type)
: err A.term
=
  // can we just use a unknown type here?
  let r = range_of_id res.return_name in
  let? env, bs', _ = desugar_binders env bs in
  let? res_t = comp_to_ast_term res in
  let bs'' = bs |> L.map (fun (q, x, ty) ->
    A.mk_binder (A.Annotated (x, ty)) r A.Expr q)
  in
  let last = L.last bs'' in
  let init = L.init bs'' in
  let bs'' = init @ [last] in
  return (A.mk_term (A.Product (bs'', res_t)) r A.Expr)

let left (f:either 'a 'b) (r:R.range)
  : err 'a
  = match f with
    | Inl x -> return x
    | Inr _ -> fail "Unsupported case" r

let right (f:either 'a 'b) (r:R.range)
  : err 'b
  = match f with
    | Inr x -> return x
    | Inl _ -> fail "Unsupported case" r

let desugar_lambda (env:env_t) (l:Sugar.lambda)
  : err SW.st_term
  = let { binders; ascription; body; range } = l in
    let? env, bs, bvs = desugar_binders env binders in
    let? env, bs, bvs, comp =
      match ascription with
      | None ->
        return (env, bs, bvs, None)
      | Some c -> 
        let fvs = free_vars_comp env c in
        let? env, bs', bvs' = idents_as_binders env fvs in
        let bs = bs@bs' in
        let bvs = bvs@bvs' in
        let? comp = desugar_computation_type env c in
        return (env, bs, bvs, Some comp)
    in
    let? body = 
      if FStar.Options.ext_getv "pulse:rvalues" <> ""
      then transform_stmt { map=[]; env=env} body
      else return body
    in
    let? body = desugar_stmt env body in
    let? qbs = map2 faux bs bvs in
    let _, abs =
      L.fold_right 
        (fun (q,b,bv) (c, body) ->
          let body' = SW.close_st_term body (SW.index_of_bv bv) in
          let asc =
            match c with
            | None -> None
            | Some c -> Some  (SW.close_comp c (SW.index_of_bv bv)) in
          None, SW.tm_abs b q asc body' range)
        qbs (comp, body)
    in
    return abs
    
let desugar_decl' (env:env_t)
                 (d:Sugar.decl)
  : err SW.decl
  = match d with
    | Sugar.FnDecl { id; is_rec; binders; ascription=Inl ascription; measure; body=Inl body; range } ->
      let? env, bs, bvs = desugar_binders env binders in
      let fvs = free_vars_comp env ascription in
      let? env, bs', bvs' = idents_as_binders env fvs in
      let bs = bs@bs' in
      let bvs = bvs@bvs' in
      let? comp = desugar_computation_type env ascription in
      let? body = 
        if FStar.Options.ext_getv "pulse:rvalues" <> ""
        then transform_stmt { map=[]; env=env} body
        else return body
      in
      let? meas = map_err_opt (desugar_term env) measure in
      (* Perhaps push the recursive binding. *)
      let? (env, bs, bvs) =
        if is_rec
        then
          let? ty = mk_knot_arr env measure binders ascription in
          let? ty = desugar_term env ty in
          let env, bv = push_bv env id in
          let b = SW.mk_binder id ty in
          return (env, bs@[(None, b)], bvs@[bv])
        else
          return (env, bs, bvs)
      in
      let? body = desugar_stmt env body in
      let? qbs = map2 faux bs bvs in
      return (SW.fn_decl range id is_rec qbs comp meas body)
  
    | Sugar.FnDecl { id; is_rec=false; binders; ascription=Inr ascription; measure=None; body=Inr body; range } ->
      let? env, bs, bvs = desugar_binders env binders in
      let? comp = 
        match ascription with
        | None -> return (SW.mk_tot (SW.tm_unknown range))
        | Some t -> let? t = desugar_term env t in return (SW.mk_tot t)
      in
      let? body = desugar_lambda env body in
      let? qbs = map2 faux bs bvs in
      return (SW.fn_decl range id false qbs comp None body)
let desugar_decl env d =
  let? decl = desugar_decl' env d in
  return decl

let name = list string

let initialize_env (env:TcEnv.env)
                   (open_namespaces: list name)
                   (module_abbrevs: list (string & name))
  : env_t
  = let dsenv = env.dsenv in
    let dsenv = D.set_current_module dsenv (TcEnv.current_module env) in
    let dsenv =
      L.fold_right
        (fun ns env -> D.push_namespace env (Ident.lid_of_path ns r_))
        open_namespaces
        dsenv
    in
    let dsenv = D.push_namespace dsenv (TcEnv.current_module env) in
    let dsenv =
      L.fold_left
        (fun env (m, n) -> 
          D.push_module_abbrev env (Ident.id_of_text m) (Ident.lid_of_path n r_))
        dsenv
        module_abbrevs
    in
    let env = { env with dsenv } in
    { 
      tcenv = env;
      local_refs = []
    }
