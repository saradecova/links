(*pp deriving *)
(* js.ml
    JavaScript generation.
*)

open Utility

let js_lib_url = Basicsettings.Js.lib_url
let js_pretty_print = Basicsettings.Js.pp

let get_js_lib_url () = Settings.get_value js_lib_url

(* Intermediate language *)
type code = | Var    of string
            | Lit    of string
            | DeclareVar of string * code option
            | Fn     of (string list * code)

            | LetFun of ((string * string list * code * Ir.location) * code)
            | LetRec of ((string * string list * code * Ir.location) list * code)
            | Call   of (code * code list)
            | Unop   of (string * code)
            | Binop  of (code * string * code)
            | If     of (code * code * code)
            | Case   of (string * (string * code) stringmap * (string * code) option)
            | Dict   of ((string * code) list)
            | Lst    of (code list)

            | Bind   of (string * code * code)
            | Seq    of (code * code)

            | Die    of (string)
            | Ret    of code
            | Nothing
  deriving (Show)


(* IR variable environment *)
module VEnv = Env.Int

(* type of environments mapping IR variables to source variables *)
type venv = string VEnv.t

(*
  Runtime required (JavaScript functions used should be documented here)

  LINKS.concat(a, b)
     concatenate two sequences: either strings or lists
  LINKS.accum(f, i)
    concatMap: apply f to every element of the sequence `i' and concatenate the results.
  _plus, _minus, etc.
    curried function versions of the standard arithmetic operators
  LINKS.XML(tag, attrs, children)
    create a DOM node with name `tag'
                       and attributes `attrs' (a dictionary)
                       and children `children' (a sequence of DOM nodes and strings)    
  LINKS.union(r, s)
    return the union of the records r and s
    precondition: r and s have disjoint labels 
  LINKS.project(record, label)
    project a field of a record
  LINKS.erase(record, label)
    return a record like "record" but without the field labeled "label"

  _start(tree)
    Replace the current page with `tree'.

  Also, any `builtin' functions from Lib.value_env.
 *)

(* Ugly printer for JavaScript code *)
module UP :
sig
  val show : code -> string
end =
struct
  let rec show code =
    let show_func name (Fn (vars, body)) = 
      "function "^ name ^"("^ String.concat ", " vars ^")"^"{ " ^" "^show body^"; }" 
    and arglist args = String.concat ", " (List.map show args) 
    and paren = function
      | Var _
      | Lit _
      | Call _
      | Dict _
      | Lst _
      | Seq _
      | Bind _
      | Die _
      | Nothing as c -> show c
      | c -> "(" ^ show c ^ ")" in
    let show_case v (l:string) ((x:string), (e:code)) =
      "case " ^ l ^ ":{var " ^ x ^ "=" ^ v ^"._value;" ^ show e ^ "break;}\n" in
    let show_cases v : (string * code) stringmap -> string =
      fun cases ->
        StringMap.fold (fun l c s ->
                          s ^ show_case v l c)
          cases "" in
    let show_default v = opt_app
      (fun (x, e) ->
         "default:{var " ^ x ^ "=" ^ v ^ ";" ^ show e ^ ";" ^ "break;}") "" in
      match code with
        | Var s -> s
        | Lit s -> s
        | Fn _ as f -> show_func "" f
        | DeclareVar (x, c) -> "var "^x^(opt_app (fun c -> " = " ^ show c) "" c)

        | LetFun ((name, vars, body, location), rest) ->
            (show_func name (Fn (vars, body))) ^ show rest
        | LetRec (defs, rest) ->
            String.concat ";\n" (List.map (fun (name, vars, body, location) -> show_func name (Fn (vars, body))) defs) ^ show rest
        | Call (Var "LINKS.project", [record; label]) -> (paren record) ^ "[" ^ show label ^ "]"
        | Call (Var "hd", [list;kappa]) -> Printf.sprintf "%s(%s[0])" (paren kappa) (paren list)
        | Call (Var "tl", [list;kappa]) -> Printf.sprintf "%s(%s.slice(1))" (paren kappa) (paren list)
        | Call (fn, args) -> paren fn ^ "(" ^ arglist args  ^ ")"
        | Unop (op, body) -> op ^ paren body
        | Binop (l, op, r) -> paren l ^ " " ^ op ^ " " ^ paren r
        | If (cond, e1, e2) ->
            "if (" ^ show cond ^ ") {" ^ show e1 ^ "} else {" ^ show e2 ^ "}"
        | Case (v, cases, default) ->
            "switch (" ^ v ^ "._label) {" ^ show_cases v cases ^ show_default v default ^ "}"
        | Dict (elems) -> "{" ^ String.concat ", " (List.map (fun (name, value) -> "'" ^  name ^ "':" ^ show value) elems) ^ "}"
        | Lst [] -> "[]"
        | Lst elems -> "[" ^ arglist elems ^ "]"
        | Bind (name, value, body) ->  name ^" = "^ show value ^"; "^ show body
        | Seq (l, r) -> show l ^"; "^ show r
        | Nothing -> ""
        | Die msg -> "error('" ^ msg ^ "', __kappa)"
end

(* Pretty printer for JavaScript code *)
module PP :
sig
  val show : code -> string
end =
struct
  open PP

  (** Pretty-print a Code value as a JavaScript string. *)
  let rec show c : PP.doc =
    let rec show_func name (Fn (vars, body)) = 
      PP.group (PP.text "function" ^+^ PP.text name ^^ (formal_list vars)
                ^+^  (braces
                        (break ^^ group(nest 2 (show body)) ^^ break))) in
    let show_case v l (x, e) =
      PP.text "case" ^+^ PP.text("'"^l^"'") ^^
        PP.text ":" ^+^ braces (PP.text"var" ^+^ PP.text x ^+^ PP.text "=" ^+^ PP.text (v^"._value;") ^+^
                                  show e ^^ PP.text ";" ^+^ PP.text "break;") ^^ break in
    let show_cases v =
      fun cases ->
        StringMap.fold (fun l c s ->
                          s ^+^ show_case v l c)
          cases DocNil in
    let show_default v = opt_app
      (fun (x, e) ->
         PP.text "default:" ^+^ braces (PP.text "var" ^+^ PP.text x ^+^ PP.text "=" ^+^ PP.text (v^";") ^+^
                                          show e ^^ PP.text ";" ^+^ PP.text "break;") ^^ break) PP.DocNil in
    let maybe_parenise = function
      | Var _
      | Lit _
      | Call _
      | Dict _
      | Lst _
      | Seq _
      | Bind _
      | Die _
      | Nothing as c -> show c
      | c -> parens (show c)
    in
      match c with
        | Var x -> PP.text x
        | Nothing -> PP.text ""

        | DeclareVar (x, c) -> PP.text "var" ^+^ PP.text x
            ^+^ (opt_app (fun c -> PP.text "=" ^+^ show c) PP.empty c)

        | Die msg -> PP.text("error('" ^ msg ^ "', __kappa)")
        | Lit literal -> PP.text literal

        | LetFun ((name, vars, body, location), rest) ->
            (show_func name (Fn (vars, body))) ^^ break ^^ show rest
        | LetRec (defs, rest) ->
            PP.vsep (punctuate " " (List.map (fun (name, vars, body, location) -> show_func name (Fn (vars, body))) defs)) ^^
              break ^^ show rest

        | Fn _ as f -> show_func "" f
        | Call (Var "LINKS.project", [record; label]) -> 
            maybe_parenise record ^^ (brackets (show label))
        | Call (Var "hd", [list;kappa]) -> 
            (maybe_parenise kappa) ^^ (parens (maybe_parenise list ^^ PP.text "[0]"))
        | Call (Var "tl", [list;kappa]) -> 
            (maybe_parenise kappa) ^^ (parens (maybe_parenise list ^^ PP.text ".slice(1)"))
        | Call (fn, args) -> maybe_parenise fn ^^ 
            (PP.arglist (List.map show args))
        | Unop (op, body) -> PP.text op ^+^ (maybe_parenise body)
        | Binop (l, op, r) -> (maybe_parenise l) ^+^ PP.text op ^+^ (maybe_parenise r)
        | If (cond, c1, c2) ->
            PP.group (PP.text "if (" ^+^ show cond ^+^ PP.text ")"
                      ^+^  (braces
                              (break ^^ group(nest 2 (show c1)) ^^ break))
                      ^+^ PP.text "else"
                      ^+^  (braces
                              (break ^^ group(nest 2 (show c2)) ^^ break)))
        | Case (v, cases, default) ->
            PP.group (PP.text "switch" ^+^ (parens (PP.text (v^"._label"))) ^+^
                        (braces ((show_cases v cases) ^+^ (show_default v default))))
        | Dict (elems) -> 
            PP.braces (hsep (punctuate ","
                               (List.map (fun (name, value) -> 
                                       group (PP.text "'" ^^ PP.text name ^^ 
                                                PP.text "':" ^^ show value)) 
                                  elems)))
        | Lst elems -> brackets(hsep(punctuate "," (List.map show elems)))
        | Bind (name, value, body) ->
            PP.text "var" ^+^ PP.text name ^+^ PP.text "=" ^+^ show value ^^ PP.text ";" ^^
              break ^^ show body
        | Seq (l, r) -> vsep [(show l ^^ PP.text ";"); show r]
        | Ret e -> PP.text("return ") ^| parens(show e)

  let show = show ->- PP.pretty 144
end

let show =
  if Settings.get_value(js_pretty_print) then
    PP.show
  else
    UP.show

(* create a string literal, quoting special characters *)
let string_js_quote s =
  let sub old repl s = Str.global_replace (Str.regexp old) repl s in
    "'" ^ sub "'" "\\'" (sub "\n" "\\n" (sub "\\" "\\\\\\\\" s)) ^ "'"

(** [strlit] produces a JS literal string from an OCaml string. *)
let strlit s = Lit (string_js_quote s)
let chrlit ch = Lit(string_js_quote(string_of_char ch))
(** [chrlistlit] produces a JS literal for the representation of a Links string. *)
let chrlistlit s  = Lst(List.map chrlit (explode s))

(* Specialness:

   * Top-level boilerplate code to replace the root element and reset the focus

     The special function _start takes an html page as a string and
     replaces the currently displayed page with that one.

     Some of the other functions are equivalents to Links builtins
     (e.g. int_of_string, xml)
 *)

let ext_script_tag ?(base=get_js_lib_url()) file =
    "  <script type='text/javascript' src=\""^base^file^"\"></script>"

let inline_script file = (* makes debugging with firebug easier *)
  let file_in = open_in file in
  let file_len = in_channel_length file_in in
  let file_contents = String.make file_len '\000' in
    really_input file_in file_contents 0 file_len;
    "  <script type='text/javascript'>" ^file_contents^ "</script>"

module Arithmetic :
sig
  val is : string -> bool
  val gen : (code * string * code) -> code
end =
struct
  let builtin_ops =
    StringMap.from_alist
      [ "+",   "+"  ;
        "+.",  "+"  ;
        "-",   "-"  ;
        "-.",  "-"  ;
        "*",   "*"  ;
        "*.",  "*"  ;
        "/",   ""   ;
        "^",   ""   ;
        "^.",  ""  ;
        "/.",  "/"  ;
        "mod", "%"  ]

  let is x = StringMap.mem x builtin_ops
  let js_name op = StringMap.find op builtin_ops
  let gen (l, op, r) =
    match op with
      | "/" -> Call (Var "Math.floor", [Binop (l, js_name op, r)])
      | "^" -> Call (Var "Math.floor", [Call (Var "Math.pow", [l; r])])
      | "^." -> Call (Var "Math.pow", [l; r])
      | _ -> Binop(l, js_name op, r)
end

module Comparison :
sig
  val is : string -> bool
  val js_name : string -> string
  val gen : (code * string * code) -> code
end =
struct
  (* these binops could be used for primitive types: Int, Bool, Char,
     String *)
  let binops =
    StringMap.from_alist
      [ "==", "==" ;
        "<>", "!=" ;
        "<",  "<"  ;
        ">",  ">"  ;
        "<=", "<=" ;
        ">=", ">=" ]
      
  (* these names should be used for non-primitive types *)
  let funs =
    StringMap.from_alist
      [ "==", "LINKS.eq"  ;
        "<>", "LINKS.neq" ;
        "<",  "LINKS.lt"  ;
        ">",  "LINKS.gt"  ;
        "<=", "LINKS.lte" ;
        ">=", "LINKS.gte" ]

  let is x = StringMap.mem x funs
  let js_name op = StringMap.find op funs
  let gen (l, op, r) =
    match op with
      | "<>" -> Unop("!", Call (Var "LINKS.eq", [l; r]))
          (* HACK

             This is technically wrong, but as we haven't implemented
             LINKS.lt, etc., it is enough to get the demos working.

             Ideally we want to compile to the builtin operators
             whenever we know that the argument types are primitive
             and the general functions otherwise. This would
             necessitate making the JS compiler type-aware.
          *)
      | "<" | ">" | "<=" | ">=" ->
          Binop(l, op, r)         
      | _ ->  Call(Var (js_name op), [l; r])
end

(* This transformation is supposed to pre-pickle any continuations
   that might need to be invoked from the client.

   As it is currently implemented it is rather brittle. It only works
   if the call to pickleCont is of the form:

   let f () = e in C[pickleCont f]

   where \().e is the continuation, and C[...] is a one-holed context.

   As we cannot jsonise functions, it also requires that any
   free-local variables in e are structural.

   To implement this functionality properly would probably require
   closure-converting the IR.
*)
module FixPickles :
sig
  type envs = Ir.closures * Var.var Env.String.t * string VEnv.t * Types.datatype VEnv.t

  val bindings : envs -> Ir.binding list -> Ir.binding list
  val program : envs -> Ir.program -> Ir.program
end
  =
struct
  type envs = Ir.closures * Var.var Env.String.t * string VEnv.t * Types.datatype VEnv.t

  class visitor (closures, nenv, venv, tenv) =
  object (o)
    inherit Ir.Transform.visitor(tenv) as super
      
    val fun_env = VEnv.empty
      
    val nenv = nenv
    val venv = venv

    val closures = closures

    method bind_name b =
      let name = Var.name_of_binder b in
      let var = Var.var_of_binder b in
      let nenv =
        if name = "" then nenv
        else Env.String.bind nenv (name, var) in
      let venv = VEnv.bind venv (var, name) in
        {< nenv = nenv; venv = venv >}

    method bind_fun f lam =
      {< fun_env = VEnv.bind fun_env (f, lam) >}      

    method super_binding b = super#binding b

    method binding b =
      match b with
        | `Fun (f, lam, _location) ->
            let o = o#bind_fun (Var.var_of_binder f) lam in
              o#super_binding b
        | `Rec defs ->
            let o =
              List.fold_right
                (fun (f, lam, _location) o -> o#bind_fun (Var.var_of_binder f) lam)
                defs
                o
            in
              o#super_binding b
        | _ -> super#binding b

    method binder b =
      let b, o = super#binder b in
        b, o#bind_name b

    method tail_computation =
      fun e ->
        match e with
          | `Apply (`TApp (`Variable v, _), [cont])
          | `Apply (`Variable v, [cont]) when VEnv.lookup venv v = "pickleCont" ->
              let f =
                match cont with
                  | `TApp (`Variable f, _)
                  | `Variable f -> f
                  | v -> failwith ("don't know how to pickle this value on the client: "^Ir.Show_value.show v) in
              let e, t, o = super#tail_computation e in
              let stringifyB64 = `Variable (Env.String.lookup nenv "stringifyB64") in
              let concat = `Variable (Env.String.lookup nenv "Concat") in

              let lam = 
                let _tyvars, xsb, body = VEnv.lookup fun_env f in
                  (List.map Var.var_of_binder xsb, body) in
              let fv = IntMap.find f closures in

              let func = Value.marshal_value (`RecFunction ([f, lam], Value.empty_env closures, f, `Local)) in
              let json_args =
                let fields =
                  IntSet.fold
                    (fun x fields ->
                       StringMap.add (string_of_int x) (`Variable x) fields)
                    fv
                    StringMap.empty
                in
                  `ApplyPure (stringifyB64,
                              [`Extend (fields, None)])
              in
                `Apply (concat, [`Constant (`String (func ^"&_jsonArgs=")); json_args]), t, o
          | e -> super#tail_computation e
  end

  let bindings envs bindings =
    let bindings, _ = (new visitor envs)#bindings bindings in
      bindings

  let program envs program =
    let program, _, _ = (new visitor envs)#program program in
      program
end

(** [cps_prims]: a list of primitive functions that need to see the
    current continuation. Calls to these are translated in CPS rather than
    direct-style.  A bit hackish, this list. *)
let cps_prims = ["recv"; "sleep"; "spawnWait"]

(** {0 Code generation} *)


module Symbols =
struct
  let words =
    CharMap.from_alist
      [ '!', "bang";
        '$', "dollar";
        '%', "percent";
        '&', "and";
        '*', "star";
        '+', "plus";
        '/', "slash";
        '<', "lessthan";
        '=', "equals";
        '>', "greaterthan";
        '?', "huh";
        '@', "monkey";
        '\\', "backslash";
        '^', "caret";
        '-', "hyphen";
        '.', "fullstop";
        '|', "pipe";
        '_', "underscore"]

  let js_keywords = ["break";"else";"new";"var";"case";"finally";"return";"void";
                     "catch";"for";"switch";"while";"continue";"function";"this";
                     "with";"default";"if";"throw";"delete";"in";"try";"do";
                     "instanceof";"typeof";
                     (* "future keywords" *)
                     "abstract";"enum";"int";"short";"boolean";"export";
                     "interface";"static";"byte";"extends";"long";"super";"char";
                     "final";"native";"synchronized";"class";"float";"package";
                     "throws";"const";"goto";"private";"transient";"debugger";
                     "implements";"protected";"volatile";
                    ]

  let has_symbols name =
    not (Lib.is_primitive name) &&
      List.exists (not -<- Utility.Char.isWord) (explode name)

  let wordify name = 
    if has_symbols name then 
      ("_" ^ 
         mapstrcat "_" 
         (fun ch ->
            if (Utility.Char.isWord ch) then
              String.make 1 ch
            else if CharMap.mem ch words then
              CharMap.find ch words
            else
              failwith("Internal error: unknown symbol character: "^String.make 1 ch))
         (Utility.explode name))
        (* TBD: it would be better if this split to chunks maximally matching
           (\w+)|(\W)
           then we would not split apart words in partly-symbolic idents. *)
    else if List.mem name js_keywords then
      "_" ^ name (* FIXME: this could conflict with Links names. *)
    else name  
end

(* generate a JavaScript name from a binder *)
let name_binder (x, info) =
  let name =
    match info with
      | (_, "", `Local) -> "_" ^ string_of_int x
      | (_, name, `Local) when (Str.string_match (Str.regexp "^_g[0-9]") name 0) ->
          "_" ^ string_of_int x (* make the generated names slightly less ridiculous in some cases *)
      | (_, name, `Local) -> name ^ "_" ^ string_of_int x
      | (_, name, `Global) -> name
  in
    x, Symbols.wordify name

let bind_continuation kappa body =
  match kappa with
    | Var _ -> body kappa
    | _ ->
        (* It is important to generate a unique name for continuation bindings because
           in the JavaScript code:
           
           var f = e;
           var f = function (args) {C[f]};
           
           the inner f is bound to function (args) {C[f]} and not e as we
           might expect in a saner language. (In other words var f =
           function(args) {body} is just syntactic sugar for function
           f(args) {body}.)
        *)
        let k = "_kappa" ^ (string_of_int (Var.fresh_raw_var ())) in
          Bind (k, kappa, body (Var k))

let apply_yielding (f, args) =
  Call(Var "_yield", f :: args)

let callk_yielding kappa arg =
  Call(Var "_yieldCont", [kappa; arg]) 

(** generate
    Generate javascript code for a Links expression
    
    With CPS transform, result of generate is always : (a -> w) -> b
*)
let rec generate_value env : Ir.value -> code =
  let gv v = generate_value env v in
    function
      | `Constant c ->
          begin
            match c with
              | `Int v  -> Lit (Num.string_of_num v)
              | `Float v    ->
                  let s = string_of_float v in
                  let n = String.length s in
                    (* strip any trailing '.' *)
                    if n > 1 && (s.[n-1] = '.') then
                      Lit (String.sub s 0 (n-1))
                    else
                      Lit s
              | `Bool v  -> Lit (string_of_bool v)
              | `Char v     -> chrlit v
              | `String v   -> chrlistlit v
          end
      | `Variable var ->
          (* HACK *)
          let name = VEnv.lookup env var in
            if Arithmetic.is name then
              Fn (["x"; "y"; "__kappa"], callk_yielding (Var "__kappa") (Arithmetic.gen (Var "x", name, Var "y")))
            else if Comparison.is name then
              Var (Comparison.js_name name)
            else
              Var name
      | `Extend (field_map, rest) ->
          let dict =
            Dict
              (StringMap.fold
                 (fun name v dict ->
                    (name, gv v) :: dict)
                 field_map [])
          in
            begin
              match rest with
                | None -> dict
                | Some v ->
                    Call (Var "LINKS.union", [gv v; dict])
            end
      | `Project (name, v) ->
          Call (Var "LINKS.project", [gv v; strlit name])
      | `Erase (names, v) ->
          Call (Var "LINKS.erase", [gv v; Lst (List.map strlit (StringSet.elements names))])
      | `Inject (name, v, _t) ->
          Dict [("_label", strlit name);
                ("_value", gv v)]

      (* erase polymorphism *)
      | `TAbs (_, v)
      | `TApp (v, _) -> gv v

      | `XmlNode (name, attributes, children) ->
          generate_xml env name attributes children

      | `ApplyPure (f, vs) ->
          let f =
            match f with
              | `TApp (f, _) -> f
              | f -> f
          in
            begin
              match f with
                | `Variable f ->
                    let f_name = VEnv.lookup env f in
                      begin
                        match vs with
                          | [l; r] when Arithmetic.is f_name ->
                              Arithmetic.gen (gv l, f_name, gv r)
                          | [l; r] when Comparison.is f_name ->
                              Comparison.gen (gv l, f_name, gv r)
                          | [v] when f_name = "negate" || f_name = "negatef" ->
                              Unop ("-", gv v)
                          | _ ->
                              if Lib.is_primitive f_name
                                && not (List.mem f_name cps_prims)
                                && Lib.primitive_location f_name <> `Server 
                              then
                                Call (Var ("_" ^ f_name), List.map gv vs)
                              else
                                Call (gv (`Variable f), List.map gv vs)
                      end
                | _ ->
                    Call (gv f, List.map gv vs)                      
            end
      | `Coerce (v, _) ->     
          gv v

and generate_xml env tag attrs children =
  Call(Var "LINKS.XML",
       [strlit tag;
        Dict (StringMap.fold (fun name v bs -> (name, generate_value env v) :: bs) attrs []);
        Lst (List.map (generate_value env) children)])

let generate_remote_call f_name xs_names =
  Call(Call (Var "LINKS.remoteCall", [Var "__kappa"]),
       [strlit f_name; Dict (
          List.map2
            (fun n v -> string_of_int n, Var v) 
            (Utility.fromTo 1 (1 + List.length xs_names))
            xs_names
        )])

let rec generate_tail_computation env : Ir.tail_computation -> code -> code = fun tc kappa ->
  let gv v = generate_value env v in
  let gc c kappa = snd (generate_computation env c kappa) in
    match tc with
      | `Return v ->           
          callk_yielding kappa (gv v)
      | `Apply (f, vs) ->
            let f =
              match f with
                | `TApp (f, _) -> f
                | f -> f
            in
              begin
                match f with
                  | `Variable f ->
                      let f_name = VEnv.lookup env f in
                        begin
                          match vs with
                            | [l; r] when Arithmetic.is f_name ->
                                callk_yielding kappa (Arithmetic.gen (gv l, f_name, gv r))
                            | [l; r] when Comparison.is f_name ->
                                callk_yielding kappa (Comparison.gen (gv l, f_name, gv r))
                            | [v] when f_name = "negate" || f_name = "negatef" ->
                                callk_yielding kappa (Unop ("-", gv v))
                            | _ ->
                                if Lib.is_primitive f_name
                                  && not (List.mem f_name cps_prims)
                                  && Lib.primitive_location f_name <> `Server 
                                then
                                  Call (kappa, [Call (Var ("_" ^ f_name), List.map gv vs)])
                                else
                                  apply_yielding (gv (`Variable f), [Lst (List.map gv vs); kappa])
                        end
                  | _ ->
                      apply_yielding (gv f, [Lst (List.map gv vs); kappa])
              end
      | `Special special ->
          generate_special env special kappa
      | `Case (v, cases, default) ->
          let v = gv v in
          let k, x = 
            match v with
              | Var x -> (fun e -> e), x
              | _ ->
                  let x = gensym ~prefix:"x" () in
                    (fun e -> Bind (x, v, e)), x
          in
            bind_continuation kappa
              (fun kappa ->
                 let gen_cont (xb, c) =
                   let (x, x_name) = name_binder xb in
                     x_name, (snd (generate_computation (VEnv.bind env (x, x_name)) c kappa)) in
                 let cases = StringMap.map gen_cont cases in
                 let default = opt_map gen_cont default in
                   k (Case (x, cases, default)))
      | `If (v, c1, c2) ->
          bind_continuation kappa
            (fun kappa ->
               If (gv v, gc c1 kappa, gc c2 kappa))

and generate_special env : Ir.special -> code -> code = fun sp kappa ->
  let gv v = generate_value env v in
    match sp with
      | `App (f, vs) ->
          Call (Var "_yield",
                Call (Var "app", [gv f]) :: [Lst ([gv vs]); kappa])
      | `Wrong _ -> Die "Internal Error: Pattern matching failed"
      | `Database v ->
          callk_yielding kappa (Dict [("_db", gv v)])
      | `Table (db, table_name, (readtype, _writetype, _needtype)) ->
          callk_yielding kappa
            (Dict [("_table",
                    Dict [("db", gv db);
                          ("name", gv table_name);
                          ("row",
                           strlit (Types.string_of_datatype (readtype)))])])
      | `Query e -> Die "Attempt to run a query on the client"
      | `CallCC v ->
          bind_continuation kappa
            (fun kappa -> apply_yielding (gv v, [Lst [kappa]; kappa]))

and generate_computation env : Ir.computation -> code -> (venv * code) = fun (bs, tc) kappa -> 
  let rec gbs env c =
    function
      | [] ->
          env, c (generate_tail_computation env tc kappa)
      | b :: bs -> 
          let env, c' = generate_binding env b in
            gbs env (c -<- c') bs
  in
    gbs env (fun code -> code) bs

and generate_binding env : Ir.binding -> (venv * (code -> code)) = fun binding ->
  match binding with
    | `Let (b, (_, `Return v)) ->
        let (x, x_name) = name_binder b in
        let env' = VEnv.bind env (x, x_name) in
          (env',
           fun code ->
             Seq (DeclareVar (x_name, Some (generate_value env v)), code))
    | `Let (b, (_, tc)) ->
        let (x, x_name) = name_binder b in
        let env' = VEnv.bind env (x, x_name) in
          env', (fun code -> generate_tail_computation env tc (Fn ([x_name], code)))
    | `Fun (fb, (_, xsb, body), location) ->
        let (f, f_name) = name_binder fb in
        let bs = List.map name_binder xsb in
        let xs, xs_names = List.split bs in
        let body_env = List.fold_left VEnv.bind env bs in
        let env' = VEnv.bind env (f, f_name) in
          (env',
           fun code ->
             let body =
               match location with
                 | `Client | `Unknown -> snd (generate_computation body_env body (Var "__kappa"))
                 | `Server -> generate_remote_call f_name xs_names
                 | `Native -> failwith ("Not implemented native calls yet")
             in
               LetFun
                 ((f_name,
                   xs_names @ ["__kappa"],
                   body,
                   location),
                  code))        
    | `Rec defs ->
        let fs = List.map (fun (fb, _, _) -> name_binder fb) defs in
        let env' = List.fold_left VEnv.bind env fs in
          (env',
           fun code ->
             LetRec
               (List.fold_right
                  (fun (fb, (_, xsb, body), location) (defs, code) ->
                     let (f, f_name) = name_binder fb in
                     let bs = List.map name_binder xsb in
                     let _, xs_names = List.split bs in
                     let body_env = List.fold_left VEnv.bind env (fs @ bs) in
                     let body =
                       match location with
                         | `Client | `Unknown -> snd (generate_computation body_env body (Var "__kappa"))
                         | `Server -> generate_remote_call f_name xs_names
                         | `Native -> failwith ("Not implemented native calls yet")
                     in
                       (f_name,
                        xs_names @ ["__kappa"],
                        body,
                        location) :: defs, code)
                  defs ([], code)))
    | `Module _
    | `Alien _
    | `Alias _ -> env, (fun code -> code)

and generate_declaration env
    : Ir.binding -> (venv * (code -> code)) = fun binding ->
  match binding with
    | `Let (b, (_, `Return v)) ->
        let (x, x_name) = name_binder b in
        let env' = VEnv.bind env (x, x_name) in
          (env',
           fun code ->
             Seq (DeclareVar (x_name, Some (generate_value env v)), code))
    | `Let (b, (_, tc)) ->
        if Settings.get_value (Basicsettings.allow_impure_defs) then
          let (x, x_name) = name_binder b in
          let env' = VEnv.bind env (x, x_name) in
            (env',
             fun code ->
               Seq (DeclareVar (x_name, None), code))
        else
          failwith "Top-level definitions must be values"
    | `Fun (fb, (_, xsb, body), location) ->
        let (f, f_name) = name_binder fb in
        let bs = List.map name_binder xsb in
        let xs, xs_names = List.split bs in
        let body_env = List.fold_left VEnv.bind env bs in
        let env' = VEnv.bind env (f, f_name) in
          (env',
           fun code ->
             let body =
               match location with
                 | `Client | `Unknown -> snd (generate_computation body_env body (Var "__kappa"))
                 | `Server -> generate_remote_call f_name xs_names
                 | `Native -> failwith ("Not implemented native calls yet")
             in
               LetFun
                 ((f_name,
                   xs_names @ ["__kappa"],
                   body,
                   location),
                  code))        
    | `Rec defs ->
        let fs = List.map (fun (fb, _, _) -> name_binder fb) defs in
        let env' = List.fold_left VEnv.bind env fs in
          (env',
           fun code ->
             LetRec
               (List.fold_right
                  (fun (fb, (_, xsb, body), location) (defs, code) ->
                     let (f, f_name) = name_binder fb in
                     let bs = List.map name_binder xsb in
                     let _, xs_names = List.split bs in
                     let body_env = List.fold_left VEnv.bind env (fs @ bs) in
                     let body =
                       match location with
                         | `Client | `Unknown -> snd (generate_computation body_env body (Var "__kappa"))
                         | `Server -> generate_remote_call f_name xs_names
                         | `Native -> failwith ("Not implemented native calls yet")
                     in
                       (f_name,
                        xs_names @ ["__kappa"],
                        body,
                        location) :: defs, code)
                  defs ([], code)))
    | `Module _
    | `Alien _
    | `Alias _ -> env, (fun code -> code)


and generate_definition env
    : Ir.binding -> code -> code =
  function
    | `Let (_, (_, `Return _)) -> (fun code -> code)
    | `Let (b, (_, tc)) ->
        let (x, x_name) = name_binder b in
          (fun code ->
             generate_tail_computation env tc
               (Fn ([x_name ^ "$"], Bind(x_name, Var (x_name ^ "$"), code))))
    | `Fun _
    | `Rec _
    | `Module _
    | `Alien _
    | `Alias _ -> (fun code -> code)

and generate_defs env : Ir.binding list -> (venv * (code -> code)) =
  fun bs ->
    let rec declare env c =
      function
        | [] -> env, c
        | b :: bs ->
            let env, c' = generate_declaration env b in
              declare env (c -<- c') bs in
    let env, with_declarations = declare env (fun code -> code) bs in
    let rec define c =
      function
        | [] -> c
        | b :: bs ->
            let c' = generate_definition env b in
              define (c -<- c') bs
    in
      if Settings.get_value Basicsettings.allow_impure_defs then
        env, fun code -> with_declarations (define (fun code -> code) bs code)
      else
        env, with_declarations

and generate_program env : Ir.program -> (venv * code) = fun c ->
  generate_computation env c (Var "_start")

let script_tag body = 
  "<script type='text/javascript'><!--\n" ^ body ^ "\n--> </script>\n"

let make_boiler_page ?(onload="") ?(body="") ?(head="") defs =
  let in_tag tag str = "<" ^ tag ^ ">\n" ^ str ^ "\n</" ^ tag ^ ">" in
  let debug_flag onoff = "\n    <script type='text/javascript'>var DEBUGGING=" ^ 
    string_of_bool onoff ^ ";</script>"
  in
  let extLibs = ext_script_tag "json.js"^"
  "            ^ext_script_tag "regex.js"^"
  "            ^ext_script_tag "yahoo/yahoo.js"^"
  "            ^ext_script_tag "yahoo/event.js" in
  let db_config_script = script_tag("    function _getDatabaseConfig() {
      return {driver:'" ^ Settings.get_value Basicsettings.database_driver ^
    "', args:'" ^ Settings.get_value Basicsettings.database_args ^"'}
    }
    var getDatabaseConfig = LINKS.kify(_getDatabaseConfig, 0);\n")
  in
  let version_comment = "<!-- $Id: js.ml 1367 2007-12-10 16:24:38Z sam $ -->" in
    in_tag "html" (in_tag "head"
                     (  extLibs
                      ^ debug_flag (Settings.get_value Debug.debugging_enabled)
                      ^ ext_script_tag "jslib.js" ^ "\n"
                      ^ db_config_script
                      ^ head
                      ^ script_tag (String.concat "\n" defs)
                      ^ version_comment
                     )
                   ^ "<body onload=\'" ^ onload ^ "\'>
  <script type='text/javascript'>
  _startTimer();" ^ body ^ ";
  </script>")
    
let wrap_with_server_stubs (code : code) : code = 
  let server_library_funcs =
    List.rev
      (Env.Int.fold
         (fun var v funcs ->
            let name = Lib.primitive_name var in
              if Lib.primitive_location name = `Server then
                (name, v)::funcs
              else
                funcs)
         (Lib.value_env) []) in

(*     List.filter *)
(*       (fun (name,_) ->  *)
(*          Lib.primitive_location name = `Server) *)
(*       (StringMap.to_alist !Lib.value_env)) in *)

  let rec some_vars = function 
      0 -> []      
    | n -> (some_vars (n-1) @ ["x"^string_of_int n]) in
    
  let prim_server_calls =
    concat_map (fun (name, _) -> 
                  match Lib.primitive_arity name with
                        None -> []
                    | Some arity ->
                        let args = some_vars arity in
                          [(name, args, generate_remote_call name args)])
      server_library_funcs
  in
    List.fold_right 
      (fun (name, args, body) code ->
         LetFun
           ((name,
             args @ ["__kappa"],
             body,
             `Server),
            code))
      prim_server_calls
      code

let initialise_envs (nenv, tyenv) =
  let dt = DesugarDatatypes.read ~aliases:tyenv.Types.tycon_env in

  (* TODO:
     
     - add stringifyB64 to lib.ml as a built-in function?
     - get rid of ConcatMap here?
  *)
  let tyenv =
    {Types.var_env = 
        Env.String.bind
          (Env.String.bind tyenv.Types.var_env
             ("ConcatMap", dt "((a) -> [b], [a]) -> [b]"))
          ("stringifyB64", dt "(a) -> String");
     Types.tycon_env = tyenv.Types.tycon_env;
     Types.effect_row = tyenv.Types.effect_row } in
  let nenv =
    Env.String.bind
      (Env.String.bind nenv
         ("ConcatMap", Var.fresh_raw_var ()))
      ("stringifyB64", Var.fresh_raw_var ()) in

  let venv =
    Env.String.fold
      (fun name v venv -> VEnv.bind venv (v, name))
      nenv
      VEnv.empty in
  let tenv = Var.varify_env (nenv, tyenv.Types.var_env) in
    (nenv, venv, tenv)
     
let generate_program_page ?(onload = "") (closures, nenv, tyenv) program =
  let nenv, venv, tenv = initialise_envs (nenv, tyenv) in
  let program = FixPickles.program (closures, nenv, venv, tenv) program in
  let _, code = generate_program venv program in
  let code = wrap_with_server_stubs code in
    (make_boiler_page
       ~body:(show code)
(*       ~head:(String.concat "\n" (generate_inclusions defs))*)
       [])

let generate_program_defs (closures, nenv, tyenv) bs =
  let nenv, venv, tenv = initialise_envs (nenv, tyenv) in
  let bs = FixPickles.bindings (closures, nenv, venv, tenv) bs in
  let _, code = generate_defs venv bs in
    [show (code Nothing)]

(* let generate_program_defs global_names defs root_names = *)
(*   generate_program_defs Library.typing_env global_names defs root_names *)
