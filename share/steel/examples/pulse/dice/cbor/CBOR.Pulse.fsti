module CBOR.Pulse
open Pulse.Lib.Pervasives
open Pulse.Lib.Stick

module Cbor = CBOR.Spec
module U64 = FStar.UInt64
module U8 = FStar.UInt8
module SZ = FStar.SizeT
module R = Pulse.Lib.Reference
module A = Pulse.Lib.Array
module SM = Pulse.Lib.SeqMatch

(* The C datatype for CBOR objects *)

noeq
type cbor_int = {
  cbor_int_type: Cbor.major_type_uint64_or_neg_int64;
  cbor_int_value: U64.t;
}

noeq
type cbor_string = {
  cbor_string_type: Cbor.major_type_byte_string_or_text_string;
  cbor_string_length: U64.t;
  cbor_string_payload: A.array U8.t;
  permission: perm; // ghost
}

inline_for_extraction
noextract
let cbor_serialized_payload_t = A.array U8.t // extraction only

[@@erasable]
val cbor_serialized_footprint_t: Type0

noeq
type cbor_serialized = {
  cbor_serialized_size: SZ.t;
  cbor_serialized_payload: cbor_serialized_payload_t;
  footprint: cbor_serialized_footprint_t; // ghost
}

noeq
type cbor_tagged = {
  cbor_tagged_tag: U64.t;
  cbor_tagged_payload: R.ref cbor;
  footprint: Ghost.erased cbor; // ghost
}

and cbor_array = {
  cbor_array_length: U64.t;
  cbor_array_payload: A.array cbor;
  footprint: Ghost.erased (Seq.seq cbor); // ghost
}

and cbor_map_entry = {
  cbor_map_entry_key: cbor;
  cbor_map_entry_value: cbor;
}

and cbor_map = {
  cbor_map_length: U64.t;
  cbor_map_payload: A.array cbor_map_entry;
  footprint: Ghost.erased (Seq.seq cbor_map_entry); // ghost
}

and cbor =
| CBOR_Case_Int64 of cbor_int
| CBOR_Case_String of cbor_string
| CBOR_Case_Tagged of cbor_tagged
| CBOR_Case_Array of cbor_array
| CBOR_Case_Map of cbor_map
| CBOR_Case_Simple_value of Cbor.simple_value
| CBOR_Case_Serialized of cbor_serialized

inline_for_extraction
noextract
let dummy_cbor : cbor = CBOR_Case_Simple_value 0uy

(* Relating a CBOR C object with a CBOR high-level value *)

noextract
let fstp (#a1 #a2: Type) (x: (a1 & a2)) : Tot a1 = fst x

noextract
let sndp (#a1 #a2: Type) (x: (a1 & a2)) : Tot a2 = snd x

let raw_data_item_map_entry_match1
  (c1: cbor_map_entry)
  (v1: (Cbor.raw_data_item & Cbor.raw_data_item))
  (raw_data_item_match: (cbor -> (v': Cbor.raw_data_item { v' << v1 }) -> vprop))
: Tot vprop
= raw_data_item_match c1.cbor_map_entry_key (fstp v1) **
  raw_data_item_match c1.cbor_map_entry_value (sndp v1)

val raw_data_item_match
  (c: cbor)
  (v: Cbor.raw_data_item)
: Tot vprop

let raw_data_item_array_match
  (c: Seq.seq cbor)
  (v: list Cbor.raw_data_item)
: Tot vprop
  (decreases v)
= SM.seq_list_match c v raw_data_item_match

let raw_data_item_map_entry_match
  (c1: cbor_map_entry)
  (v1: (Cbor.raw_data_item & Cbor.raw_data_item))
: Tot vprop
= raw_data_item_map_entry_match1 c1 v1 raw_data_item_match

let raw_data_item_map_match
  (c: Seq.seq cbor_map_entry)
  (v: list (Cbor.raw_data_item & Cbor.raw_data_item))
: Tot vprop
  (decreases v)
= SM.seq_list_match c v raw_data_item_map_entry_match

val raw_data_item_match_get_case
  (#opened: _)
  (c: cbor)
  (#v: Cbor.raw_data_item)
: stt_ghost unit opened
    (raw_data_item_match c v)
    (fun _ -> raw_data_item_match c v ** pure (
      match c, v with
      | CBOR_Case_Serialized _, _
      | CBOR_Case_Array _, Cbor.Array _
      | CBOR_Case_Int64 _, Cbor.Int64 _ _
      | CBOR_Case_Map _, Cbor.Map _
      | CBOR_Case_Simple_value _, Cbor.Simple _
      | CBOR_Case_String _, Cbor.String _ _
      | CBOR_Case_Tagged _, Cbor.Tagged _ _
        -> True
      | _ -> False
    ))

(* Parsing *)

noeq
type read_cbor_success_t = {
  read_cbor_payload: cbor;
  read_cbor_remainder: A.array U8.t;
  read_cbor_remainder_length: SZ.t;
}

noeq
type read_cbor_t =
| ParseError
| ParseSuccess of read_cbor_success_t

noextract
let read_cbor_success_postcond
  (va: Ghost.erased (Seq.seq U8.t))
  (c: read_cbor_success_t)
  (v: Cbor.raw_data_item)
  (rem: Seq.seq U8.t)
: Tot prop
= SZ.v c.read_cbor_remainder_length == Seq.length rem /\
  va `Seq.equal` (Cbor.serialize_cbor v `Seq.append` rem)

let read_cbor_success_post
  (a: A.array U8.t)
  (p: perm)
  (va: Ghost.erased (Seq.seq U8.t))
  (c: read_cbor_success_t)
: Tot vprop
= exists_ (fun v -> exists_ (fun rem ->
    raw_data_item_match c.read_cbor_payload v **
    A.pts_to c.read_cbor_remainder #p rem **
    ((raw_data_item_match c.read_cbor_payload v ** A.pts_to c.read_cbor_remainder #p rem) @==>
      A.pts_to a #p va) **
    pure (read_cbor_success_postcond va c v rem)
  ))

noextract
let read_cbor_error_postcond
  (va: Ghost.erased (Seq.seq U8.t))
: Tot prop
= forall v . ~ (Cbor.serialize_cbor v == Seq.slice va 0 (min (Seq.length (Cbor.serialize_cbor v)) (Seq.length va)))

let read_cbor_error_post
  (a: A.array U8.t)
  (p: perm)
  (va: Ghost.erased (Seq.seq U8.t))
: Tot vprop
= A.pts_to a #p va ** pure (read_cbor_error_postcond va)

let read_cbor_post
  (a: A.array U8.t)
  (p: perm)
  (va: Ghost.erased (Seq.seq U8.t))
  (res: read_cbor_t)
: Tot vprop
= match res with
  | ParseError -> read_cbor_error_post a p va
  | ParseSuccess c -> read_cbor_success_post a p va c

val read_cbor
  (a: A.array U8.t)
  (sz: SZ.t)
  (#va: Ghost.erased (Seq.seq U8.t))
  (#p: perm)
: stt read_cbor_t
    (A.pts_to a #p va ** pure (
      (SZ.v sz == Seq.length va \/ SZ.v sz == A.length a)
    ))
    (fun res -> read_cbor_post a p va res)

noextract
let read_deterministically_encoded_cbor_success_postcond
  (va: Ghost.erased (Seq.seq U8.t))
  (c: read_cbor_success_t)
  (v: Cbor.raw_data_item)
  (rem: Seq.seq U8.t)
: Tot prop
= read_cbor_success_postcond va c v rem /\
  Cbor.data_item_wf Cbor.deterministically_encoded_cbor_map_key_order v == true

let read_deterministically_encoded_cbor_success_post
  (a: A.array U8.t)
  (p: perm)
  (va: Ghost.erased (Seq.seq U8.t))
  (c: read_cbor_success_t)
: Tot vprop
= exists_ (fun v -> exists_ (fun rem ->
    raw_data_item_match c.read_cbor_payload v **
    A.pts_to c.read_cbor_remainder #p rem **
    ((raw_data_item_match c.read_cbor_payload v ** A.pts_to c.read_cbor_remainder #p rem) @==>
      A.pts_to a #p va) **
    pure (read_deterministically_encoded_cbor_success_postcond va c v rem)
  ))

noextract
let read_deterministically_encoded_cbor_error_postcond
  (va: Ghost.erased (Seq.seq U8.t))
: Tot prop
= forall v . Cbor.serialize_cbor v == Seq.slice va 0 (min (Seq.length (Cbor.serialize_cbor v)) (Seq.length va)) ==> Cbor.data_item_wf Cbor.deterministically_encoded_cbor_map_key_order v == false

let read_deterministically_encoded_cbor_error_post
  (a: A.array U8.t)
  (p: perm)
  (va: Ghost.erased (Seq.seq U8.t))
: Tot vprop
= A.pts_to a #p va ** pure (read_deterministically_encoded_cbor_error_postcond va)

let read_deterministically_encoded_cbor_post
  (a: A.array U8.t)
  (p: perm)
  (va: Ghost.erased (Seq.seq U8.t))
  (res: read_cbor_t)
: Tot vprop
= match res with
  | ParseError -> read_deterministically_encoded_cbor_error_post a p va
  | ParseSuccess c -> read_deterministically_encoded_cbor_success_post a p va c

val read_deterministically_encoded_cbor
  (a: A.array U8.t)
  (sz: SZ.t)
  (#va: Ghost.erased (Seq.seq U8.t))
  (#p: perm)
: stt read_cbor_t
    (A.pts_to a #p va ** pure (SZ.v sz == Seq.length va \/ SZ.v sz == A.length a))
    (fun res -> read_deterministically_encoded_cbor_post a p va res)

(* Destructors and constructors *)

val destr_cbor_int64
  (c: cbor)
  (#va: Ghost.erased Cbor.raw_data_item)
: stt cbor_int
    (raw_data_item_match c (Ghost.reveal va) ** pure (
      (Cbor.Int64? (Ghost.reveal va))
    ))
    (fun c' -> raw_data_item_match c (Ghost.reveal va) ** pure (
      Ghost.reveal va == Cbor.Int64 c'.cbor_int_type c'.cbor_int_value /\
      (CBOR_Case_Int64? c ==> c == CBOR_Case_Int64 c')
    ))

val constr_cbor_int64
  (ty: Cbor.major_type_uint64_or_neg_int64)
  (value: U64.t)
: stt cbor
    emp
    (fun c -> raw_data_item_match c (Cbor.Int64 ty value) ** pure (
      c == CBOR_Case_Int64 ({ cbor_int_type = ty; cbor_int_value = value })
    ))

val destr_cbor_simple_value
  (c: cbor)
  (#va: Ghost.erased Cbor.raw_data_item)
: stt Cbor.simple_value
    (raw_data_item_match c (Ghost.reveal va) ** pure (
      (Cbor.Simple? (Ghost.reveal va))
    ))
    (fun c' ->
      raw_data_item_match c (Ghost.reveal va) ** pure (
      Ghost.reveal va == Cbor.Simple c' /\
      (CBOR_Case_Simple_value? c ==> c == CBOR_Case_Simple_value c')
    ))

val constr_cbor_simple_value
  (value: Cbor.simple_value)
: stt cbor
    emp
    (fun c -> raw_data_item_match c (Cbor.Simple value) ** pure (
      c == CBOR_Case_Simple_value value
    ))

val destr_cbor_string
  (c: cbor)
  (#va: Ghost.erased Cbor.raw_data_item)
: stt cbor_string
    (raw_data_item_match c (Ghost.reveal va) ** pure (
      Cbor.String? va
    ))
    (fun c' -> exists_ (fun vc' ->
      A.pts_to c'.cbor_string_payload #c'.permission vc' **
      (A.pts_to c'.cbor_string_payload #c'.permission vc' @==> raw_data_item_match c (Ghost.reveal va)) **
      pure (
        Cbor.String? va /\
        U64.v c'.cbor_string_length == Seq.length vc' /\
        c'.cbor_string_type == Cbor.String?.typ va /\
        vc' == Cbor.String?.v va
    )))

val constr_cbor_string
  (typ: Cbor.major_type_byte_string_or_text_string)
  (a: A.array U8.t)
  (len: U64.t)
  (#va: Ghost.erased (Seq.seq U8.t))
  (#p: perm)
: stt cbor
    (A.pts_to a #p va ** pure (
      U64.v len == Seq.length va
    ))
    (fun c' -> exists_ (fun vc' ->
      raw_data_item_match c' vc' **
      (raw_data_item_match c' vc' @==>
        A.pts_to a #p va
      ) ** pure (
      U64.v len == Seq.length va /\
      vc' == Cbor.String typ va /\
      c' == CBOR_Case_String ({
        cbor_string_type = typ;
        cbor_string_length = len;
        cbor_string_payload = a;
        permission = p;
      })
    )))

val constr_cbor_array
  (a: A.array cbor)
  (len: U64.t)
  (#c': Ghost.erased (Seq.seq cbor))
  (#v': Ghost.erased (list Cbor.raw_data_item))
: stt cbor
    (A.pts_to a c' **
      raw_data_item_array_match c' v' **
      pure (
        U64.v len == List.Tot.length v'
    ))
    (fun res -> exists_ (fun vres ->
      raw_data_item_match res vres **
      (raw_data_item_match res vres @==>
        (A.pts_to a c' **
          raw_data_item_array_match c' v')
      ) ** pure (
      U64.v len == List.Tot.length v' /\
      vres == Cbor.Array v' /\
      res == CBOR_Case_Array ({
        cbor_array_payload = a;
        cbor_array_length = len;
        footprint = c';
      })
    )))

let maybe_cbor_array
  (v: Cbor.raw_data_item)
: GTot (list Cbor.raw_data_item)
= match v with
  | Cbor.Array l -> l
  | _ -> []

val destr_cbor_array
  (a: cbor)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt cbor_array
    (raw_data_item_match a v ** pure (
      (CBOR_Case_Array? a)
    ))
    (fun res ->
      A.pts_to res.cbor_array_payload res.footprint **
      raw_data_item_array_match res.footprint (maybe_cbor_array v) **
      ((A.pts_to res.cbor_array_payload res.footprint **
        raw_data_item_array_match res.footprint (maybe_cbor_array v)) @==>
        raw_data_item_match a v
      ) ** pure (
        a == CBOR_Case_Array res /\
        Cbor.Array? v /\
        U64.v res.cbor_array_length == List.Tot.length (Cbor.Array?.v v)
      )
    )

val cbor_array_length
  (a: cbor)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt U64.t
    (raw_data_item_match a v ** pure (
      (Cbor.Array? v)
    ))
    (fun res -> raw_data_item_match a v ** pure (
      Cbor.Array? v /\
      U64.v res == List.Tot.length (Cbor.Array?.v v)
    ))

val cbor_array_index
  (a: cbor)
  (i: SZ.t)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt cbor
    (raw_data_item_match a v ** pure (
      Cbor.Array? v /\
      SZ.v i < List.Tot.length (Cbor.Array?.v v)
    ))
    (fun a' -> exists_ (fun va' ->
      raw_data_item_match a' va' **
      (raw_data_item_match a' va' @==>
        raw_data_item_match a v) **
      pure (
        Cbor.Array? v /\
        SZ.v i < List.Tot.length (Cbor.Array?.v v) /\
        va' == List.Tot.index (Cbor.Array?.v v) (SZ.v i)
    )))

noeq
type cbor_array_iterator_payload_t =
| CBOR_Array_Iterator_Payload_Array:
    payload: A.array cbor ->
    footprint: Ghost.erased (Seq.seq cbor) ->
    cbor_array_iterator_payload_t
| CBOR_Array_Iterator_Payload_Serialized:
    payload: cbor_serialized_payload_t ->
    footprint: cbor_serialized_footprint_t ->
    cbor_array_iterator_payload_t

// NOTE: this type could be made abstract (with val and
// CAbstractStruct, and then hiding cbor_array_iterator_payload_t
// altogether), but then, users couldn't allocate on stack
noeq
type cbor_array_iterator_t = {
  cbor_array_iterator_length: U64.t;
  cbor_array_iterator_payload: cbor_array_iterator_payload_t;
}

val dummy_cbor_array_iterator: cbor_array_iterator_t

val cbor_array_iterator_match
  (i: cbor_array_iterator_t)
  (l: list Cbor.raw_data_item)
: Tot vprop

val cbor_array_iterator_init
  (a: cbor)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt cbor_array_iterator_t
    (raw_data_item_match a v)
    (fun i -> exists_ (fun vi ->
      cbor_array_iterator_match i vi **
      (cbor_array_iterator_match i vi @==>
        raw_data_item_match a v) **
      pure (
        Cbor.Array? v /\
        vi == Cbor.Array?.v v
    )))

val cbor_array_iterator_is_done
  (i: cbor_array_iterator_t)
  (#l: Ghost.erased (list Cbor.raw_data_item))
: stt bool
    (cbor_array_iterator_match i l)
    (fun res -> cbor_array_iterator_match i l ** pure (
      res == Nil? l
    ))

val cbor_array_iterator_next
  (pi: R.ref cbor_array_iterator_t)
  (#l: Ghost.erased (list Cbor.raw_data_item))
  (#i: Ghost.erased cbor_array_iterator_t)
: stt cbor
    (R.pts_to pi i ** cbor_array_iterator_match i l **
      pure (Cons? l)
    )
    (fun c -> exists_ (fun i' -> exists_ (fun vc -> exists_ (fun vi' ->
      R.pts_to pi i' **
      raw_data_item_match c vc **
      cbor_array_iterator_match i' vi' **
      ((raw_data_item_match c vc **
        cbor_array_iterator_match i' vi') @==>
        cbor_array_iterator_match i l
      ) ** pure (
      Ghost.reveal l == vc :: vi'
    )))))

val read_cbor_array
  (a: cbor)
  (dest: A.array cbor) // it is the user's responsibility to allocate the array properly
  (len: U64.t)
  (#v: Ghost.erased Cbor.raw_data_item)
  (#vdest: Ghost.erased (Seq.seq cbor))
: stt cbor_array
    (raw_data_item_match a v **
      A.pts_to dest vdest **
      pure (
        (Cbor.Array? v /\
          (U64.v len == A.length dest \/ U64.v len == Seq.length vdest) /\
          U64.v len == List.Tot.length (Cbor.Array?.v v)
        )
    ))
    (fun res ->
      A.pts_to res.cbor_array_payload res.footprint **
      raw_data_item_array_match res.footprint (maybe_cbor_array v) **
      ((A.pts_to res.cbor_array_payload res.footprint **
        raw_data_item_array_match res.footprint (maybe_cbor_array v)) @==> (
        raw_data_item_match a v **
        (exists_ (A.pts_to dest #full_perm))
      )) ** pure (
      Cbor.Array? v /\
      res.cbor_array_length == len /\
      U64.v len == A.length dest /\
      U64.v len == A.length res.cbor_array_payload /\
      U64.v len == Seq.length res.footprint /\
      (if CBOR_Case_Array? a
      then a == CBOR_Case_Array res
      else res.cbor_array_payload == dest
      )
    ))

let maybe_cbor_tagged_tag
  (v: Cbor.raw_data_item)
: GTot U64.t
= match v with
  | Cbor.Tagged t _ -> t
  | _ -> 0uL // dummy

let dummy_raw_data_item : Ghost.erased Cbor.raw_data_item =
  Cbor.Int64 Cbor.major_type_uint64 0uL

let maybe_cbor_tagged_payload
  (v: Cbor.raw_data_item)
: GTot Cbor.raw_data_item
= match v with
  | Cbor.Tagged _ l -> l
  | _ -> dummy_raw_data_item

val destr_cbor_tagged
  (a: cbor)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt cbor_tagged
    (raw_data_item_match a v ** pure (
      (CBOR_Case_Tagged? a)
    ))
    (fun res ->
      R.pts_to res.cbor_tagged_payload res.footprint **
      raw_data_item_match res.footprint (maybe_cbor_tagged_payload v) **
      ((R.pts_to res.cbor_tagged_payload res.footprint **
        raw_data_item_match res.footprint (maybe_cbor_tagged_payload v)) @==>
        raw_data_item_match a v
      ) ** pure (
      a == CBOR_Case_Tagged res /\
      Cbor.Tagged? v /\
      res.cbor_tagged_tag == Cbor.Tagged?.tag v
    ))

val constr_cbor_tagged
  (tag: U64.t)
  (a: R.ref cbor)
  (#c': Ghost.erased (cbor))
  (#v': Ghost.erased (Cbor.raw_data_item))
: stt cbor
    (R.pts_to a c' **
      raw_data_item_match c' v')
    (fun res ->
      raw_data_item_match res (Cbor.Tagged tag v') **
      (raw_data_item_match res (Cbor.Tagged tag v') @==>
        (R.pts_to a c' **
          raw_data_item_match c' v')
      ) ** pure (
      res == CBOR_Case_Tagged ({
        cbor_tagged_tag = tag;
        cbor_tagged_payload = a;
        footprint = c';
      })
    ))

val read_cbor_tagged
  (a: cbor)
  (dest: R.ref cbor) // it is the user's responsibility to allocate the reference properly (maybe on the stack)
  (#v: Ghost.erased Cbor.raw_data_item)
  (#vdest: Ghost.erased (cbor))
: stt cbor_tagged
    (raw_data_item_match a v **
      R.pts_to dest vdest **
      pure (
      (Cbor.Tagged? v)
    ))
    (fun res ->
      R.pts_to res.cbor_tagged_payload res.footprint **
      raw_data_item_match res.footprint (maybe_cbor_tagged_payload v) **
      ((R.pts_to res.cbor_tagged_payload res.footprint **
        raw_data_item_match res.footprint (maybe_cbor_tagged_payload v)) @==> (
        raw_data_item_match a v **
        (exists_ (R.pts_to dest #full_perm))
      )) ** pure (
      Cbor.Tagged? v /\
      Cbor.Tagged?.tag v == res.cbor_tagged_tag /\
      (if CBOR_Case_Tagged? a
      then a == CBOR_Case_Tagged res
      else res.cbor_tagged_payload == dest
      )
    ))

let maybe_cbor_map
  (v: Cbor.raw_data_item)
: GTot (list (Cbor.raw_data_item & Cbor.raw_data_item))
= match v with
  | Cbor.Map l -> l
  | _ -> []

val destr_cbor_map
  (a: cbor)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt cbor_map
    (raw_data_item_match a v ** pure (
      (CBOR_Case_Map? a)
    ))
    (fun res ->
      A.pts_to res.cbor_map_payload res.footprint **
      SM.seq_list_match res.footprint (maybe_cbor_map v) raw_data_item_map_entry_match **
      ((A.pts_to res.cbor_map_payload res.footprint **
        SM.seq_list_match res.footprint (maybe_cbor_map v) raw_data_item_map_entry_match) @==>
        raw_data_item_match a v
      ) ** pure (
      a == CBOR_Case_Map res /\
      Cbor.Map? v /\
      U64.v res.cbor_map_length == List.Tot.length (Cbor.Map?.v v)
    ))

val constr_cbor_map
  (a: A.array cbor_map_entry)
  (len: U64.t)
  (#c': Ghost.erased (Seq.seq cbor_map_entry))
  (#v': Ghost.erased (list (Cbor.raw_data_item & Cbor.raw_data_item)))
: stt cbor
    (A.pts_to a c' **
      raw_data_item_map_match c' v' **
      pure (
        U64.v len == List.Tot.length v'
    ))
    (fun res -> exists_ (fun vres ->
      raw_data_item_match res vres **
      (raw_data_item_match res vres @==>
        (A.pts_to a c' **
          raw_data_item_map_match c' v')
      ) ** pure (
      U64.v len == List.Tot.length v' /\
      vres == Cbor.Map v' /\
      res == CBOR_Case_Map ({
        cbor_map_payload = a;
        cbor_map_length = len;
        footprint = c';
      })
    )))

val cbor_get_major_type
  (a: cbor)
  (#v: Ghost.erased Cbor.raw_data_item)
: stt Cbor.major_type_t
    (raw_data_item_match a v)
    (fun res -> raw_data_item_match a v ** pure (
      res == Cbor.get_major_type v
    ))

val cbor_is_equal
  (a1: cbor)
  (a2: cbor)
  (#v1: Ghost.erased Cbor.raw_data_item)
  (#v2: Ghost.erased Cbor.raw_data_item)
: stt bool
    (raw_data_item_match a1 v1 ** raw_data_item_match a2 v2)
    (fun res -> raw_data_item_match a1 v1 ** raw_data_item_match a2 v2 ** pure (
      (~ (Cbor.Tagged? v1 \/ Cbor.Array? v1 \/ Cbor.Map? v1)) ==> (res == true <==> v1 == v2) // TODO: underspecified for tagged, arrays and maps, complete those missing cases
    ))

noeq
type cbor_map_get_t =
| Found of cbor
| NotFound

let rec list_ghost_assoc
  (#key: Type)
  (#value: Type)
  (k: key)
  (m: list (key & value))
: GTot (option value)
  (decreases m)
= match m with
  | [] -> None
  | (k', v') :: m' ->
    if FStar.StrongExcludedMiddle.strong_excluded_middle (k == k')
    then Some v'
    else list_ghost_assoc k m'

let cbor_map_get_post_not_found
  (vkey: Cbor.raw_data_item)
  (vmap: Cbor.raw_data_item)
  (map: cbor)
: Tot vprop
= raw_data_item_match map vmap ** pure (
    Cbor.Map? vmap /\
    list_ghost_assoc vkey (Cbor.Map?.v vmap) == None
  )

let cbor_map_get_post_found
  (vkey: Cbor.raw_data_item)
  (vmap: Cbor.raw_data_item)
  (map: cbor)
  (value: cbor)
: Tot vprop
= exists_ (fun vvalue ->
    raw_data_item_match value vvalue **
    (raw_data_item_match value vvalue @==> raw_data_item_match map vmap) **
    pure (
      Cbor.Map? vmap /\
      list_ghost_assoc vkey (Cbor.Map?.v vmap) == Some vvalue
  ))

let cbor_map_get_post
  (vkey: Cbor.raw_data_item)
  (vmap: Cbor.raw_data_item)
  (map: cbor)
  (res: cbor_map_get_t)
: Tot vprop
= match res with
  | NotFound -> cbor_map_get_post_not_found vkey vmap map
  | Found value -> cbor_map_get_post_found vkey vmap map value

val cbor_map_get
  (key: cbor)
  (map: cbor)
  (#vkey: Ghost.erased Cbor.raw_data_item)
  (#vmap: Ghost.erased Cbor.raw_data_item)
: stt cbor_map_get_t
    (raw_data_item_match key vkey ** raw_data_item_match map vmap ** pure (
      Cbor.Map? vmap /\
      (~ (Cbor.Tagged? vkey \/ Cbor.Array? vkey \/ Cbor.Map? vkey))
    ))
    (fun res -> raw_data_item_match key vkey ** cbor_map_get_post vkey vmap map res ** pure (
      Cbor.Map? vmap /\
      Found? res == Some? (list_ghost_assoc (Ghost.reveal vkey) (Cbor.Map?.v vmap))
    ))

(* Serialization *)

noextract
let write_cbor_postcond
  (va: Cbor.raw_data_item)
  (out: A.array U8.t)
  (vout': Seq.seq U8.t)
  (res: SZ.t)
: Tot prop
= let s = Cbor.serialize_cbor va in
  Seq.length vout' == A.length out /\
  (res = 0sz <==> Seq.length s > Seq.length vout') /\
  (res <> 0sz ==> (
    SZ.v res == Seq.length s /\
    Seq.slice vout' 0 (Seq.length s) `Seq.equal` s
  ))

let write_cbor_post
  (va: Ghost.erased Cbor.raw_data_item)
  (c: cbor)
  (vout: Ghost.erased (Seq.seq U8.t))
  (out: A.array U8.t)
  (res: SZ.t)
  (vout': Seq.seq U8.t)
: Tot vprop
= 
  A.pts_to out vout' **
  pure (write_cbor_postcond va out vout' res)

val write_cbor
  (c: cbor)
  (out: A.array U8.t)
  (sz: SZ.t)
  (#va: Ghost.erased Cbor.raw_data_item)
  (#vout: Ghost.erased (Seq.seq U8.t))
: stt SZ.t
    (raw_data_item_match c (Ghost.reveal va) **
      A.pts_to out vout **
      pure (
        (SZ.v sz == A.length out)
    ))
    (fun res -> 
      raw_data_item_match c (Ghost.reveal va) **
      exists_ (write_cbor_post va c vout out res)
    )
