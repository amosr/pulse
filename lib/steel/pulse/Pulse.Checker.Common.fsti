module Pulse.Checker.Common
module RT = FStar.Reflection.Typing
module R = FStar.Reflection
module L = FStar.List.Tot
module T = FStar.Tactics
open FStar.List.Tot
open Pulse.Syntax
open Pulse.Typing
module FV = Pulse.Typing.FV
module RU = Pulse.RuntimeUtils
module Metatheory = Pulse.Typing.Metatheory

let mk_abs ty t = RT.(mk_abs (elab_term ty) T.Q_Explicit (elab_term t))
let mk_arrow ty t = RT.mk_arrow (elab_term ty) T.Q_Explicit (elab_term t)

noeq
type post_hint_t = {
  g:env;
  ret_ty:term;
  u:universe;
  ty_typing:universe_of g ret_ty u;
  post:term;
  post_typing:FStar.Ghost.erased (RT.tot_typing (elab_env g) (mk_abs ret_ty post) (mk_arrow ret_ty Tm_VProp))
}


let env_extends (g' g:env) = 
  g'.f == g.f /\
  (exists suffix. suffix @ g.g == g'.g)

let extends_env_trans (g2 g1 g:env) 
  : Lemma 
    (requires g2 `env_extends` g1 /\ 
              g1 `env_extends` g)
    (ensures g2 `env_extends` g)
    [SMTPat (g2 `env_extends` g);
     SMTPat (g2 `env_extends` g1)]
  = eliminate exists suffix2. suffix2 @ g1.g == g2.g
    returns _
    with _. (
      eliminate exists suffix1. suffix1 @ g.g == g1.g
      returns exists suffix. suffix @ g.g == g2.g
      with _. (
        assert (suffix2@(suffix1@g.g) == g2.g);
        List.Tot.Properties.append_assoc suffix2 suffix1 g.g
      )
    )

let extends_extends_env (g:env) (x:var) (b:binding)
  : Lemma 
    (ensures (extend x b g) `env_extends` g)
  = assert ([x,b]@g.g == (extend x b g).g)

let extends_env_refl (g:env)
  : Lemma 
    (ensures g `env_extends` g)
  = assert ([]@g.g == g.g)
  
let env_extends_one_trans (g' g:env) (x:var) (b:binding)
  : Lemma 
    (requires g' `env_extends` g)
    (ensures (extend x b g') `env_extends` g)
  = extends_extends_env g' x b;
    extends_env_trans (extend x b g') g' g

let post_hint_for_env_p (g:env) (p:post_hint_t) = g `env_extends` p.g

let post_hint_for_env_extends (g:env) (p:post_hint_t) (x:var) (b:binding)
  : Lemma
    (requires post_hint_for_env_p g p)
    (ensures post_hint_for_env_p (extend x b g) p)
    [SMTPat (post_hint_for_env_p (extend x b g) p)]
  = env_extends_one_trans g p.g x b
  
let post_hint_for_env (g:env) = p:post_hint_t { post_hint_for_env_p g p }
let post_hint_opt (g:env) = o:option post_hint_t { None? o \/ post_hint_for_env_p g (Some?.v o) }

noeq
type post_hint_typing_t (g:env) (p:post_hint_t) (x:var) = {
  ty_typing:universe_of g p.ret_ty p.u;
  post_typing:tot_typing (extend x (Inl p.ret_ty) g) (open_term p.post x) Tm_VProp
}

val post_hint_typing (g:env)
                     (p:post_hint_for_env g)
                     (x:var { Metatheory.fresh_wrt x g (freevars p.post) })
  : post_hint_typing_t g p x

val intro_post_hint (g:env) (ret_ty:option term) (post:term)
  : T.Tac (post_hint_for_env g)

val post_hint_from_comp_typing (#g:env) (#c:comp_st) (ct:Metatheory.comp_typing_u g c)
  : post_hint_for_env g

exception Framing_failure of Pulse.Checker.Framing.framing_failure

val try_frame_pre (#g:env)
                  (#t:st_term)
                  (#pre:term)
                  (pre_typing: tot_typing g pre Tm_VProp)
                  (#c:comp_st)
                  (t_typing: st_typing g t c)
  : T.Tac (c':comp_st { comp_pre c' == pre } &
           st_typing g t c')

val replace_equiv_post
      (g:env)
      (c:comp{stateful_comp c /\ freevars_comp c `Set.subset` FV.vars_of_env g})
      (ct:Metatheory.comp_typing_u g c)
      (post_hint:post_hint_opt g)
  : T.Tac (c1:comp { stateful_comp c1 /\ comp_pre c1 == comp_pre c } & st_equiv g c c1)

val repack (#g:env) (#pre:term) (#t:st_term)
           (x:(c:comp_st { comp_pre c == pre } & st_typing g t c))
           (post_hint:post_hint_opt g)
           (apply_post_hint:bool)
  : T.Tac (t:st_term &
           c:comp {stateful_comp c ==> comp_pre c == pre} &
           st_typing g t c)

val intro_comp_typing (g:env) 
                      (c:comp_st)
                      (pre_typing:tot_typing g (comp_pre c) Tm_VProp)
                      (res_typing:universe_of g (comp_res c) (comp_u c))
                      (x:var { Metatheory.fresh_wrt x g (freevars (comp_post c)) })
                      (post_typing:tot_typing (extend x (Inl (comp_res c)) g) (open_term (comp_post c) x) Tm_VProp)
  : T.Tac (comp_typing g c (comp_u c))

let checker_result_t (g:env) (pre:term) (post_hint:option post_hint_t) =
    t:st_term &
    c:comp{stateful_comp c ==> comp_pre c == pre} &
    st_typing g t c

let continuation_elaborator (g:env) (ctxt:term)
                            (g':env) (ctxt':term) =
    post_hint:post_hint_opt g ->
    checker_result_t g' ctxt' post_hint ->
    T.Tac (checker_result_t g ctxt post_hint)

type check_t =
  g:env ->
  t:st_term ->
  pre:term ->
  pre_typing:tot_typing g pre Tm_VProp ->
  post_hint:post_hint_opt g ->
  T.Tac (checker_result_t g pre post_hint)
