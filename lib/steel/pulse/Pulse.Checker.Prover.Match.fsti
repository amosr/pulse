module Pulse.Checker.Prover.Match

module T = FStar.Tactics

open Pulse.Syntax
open Pulse.Typing

open Pulse.Checker.Base
open Pulse.Checker.Prover.Base

val match_step (#preamble:preamble) (pst:prover_state preamble)
  (p:vprop) (remaining_ctxt':list vprop)
  (q:vprop) (unsolved':list vprop)
  (_:squash (pst.remaining_ctxt == p::remaining_ctxt' /\
             pst.unsolved == q::unsolved'))
: T.Tac (option (pst':prover_state preamble { pst' `pst_extends` pst }))

val match_q (#preamble:preamble) (pst:prover_state preamble)
  (q:vprop) (unsolved':list vprop)
  (_:squash (pst.unsolved == q::unsolved'))
  : T.Tac (option (pst':prover_state preamble { pst' `pst_extends` pst }))
