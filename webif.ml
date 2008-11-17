(*pp deriving *)

open Performance
open Utility
open Value

type query_params = (string * Value.t) list deriving (Show)

type web_request = ContInvoke of continuation * query_params
                   | ExprEval of Ir.tail_computation * env
                   | ClientReturn of continuation * Value.t
                   | RemoteCall of Value.t * Value.t list
                   | CallMain
                       deriving (Show)

(* Does at least one of the functions have to run on the client? *)
let is_client_program program = false

let serialize_call_to_client (continuation, name, arg) = 
  Json.jsonize_call continuation name arg

let untuple r =
  let rec un n accum list = 
    match List.partition (fst ->- (=) (string_of_int n)) list with
      | [_,item], rest -> un (n+1) (item::accum) rest
      | [], [] -> List.rev accum
      | _ -> assert false
  in match r with
    | `Record args -> un 1 [] args
    | _ -> assert false

let get_remote_call_args lookup cgi_args = 
  let fname = Utility.base64decode (List.assoc "__name" cgi_args) in
  let args = Utility.base64decode (List.assoc "__args" cgi_args) in
  let args = untuple (Json.parse_json args) in
  let func = lookup fname in
    RemoteCall(func, args)

let decode_continuation (cont : string) : Value.continuation =
  let fixup_cont = 
  (* At some point, '+' gets replaced with ' ' in our base64-encoded
     string.  Here we put it back as it was. *)
    Str.global_replace (Str.regexp " ") "+" 
  in Marshal.from_string (Utility.base64decode (fixup_cont cont)) 0

let is_special_param (k, _) =
  List.mem k ["_cont"; "_k"; "_jsonArgs"]

let string_dict_to_charlist_dict =
  alistmap Value.string_as_charlist

(* ContInvoke doesn't appear to be used any more *)
(* Extract continuation from the parameters passed in over CGI.*)
let contin_invoke_req (valenv, nenv, tyenv) program params =
  let pickled_continuation = List.assoc "_cont" params in
  let params = List.filter (not -<- is_special_param) params in
  let params = string_dict_to_charlist_dict params in
  let unmarshal_envs = Value.build_unmarshal_envs (valenv, nenv, tyenv) program in
    (* TBD: create a debug setting for printing webif modes. *)
(*     Debug.print("Invoking " ^ string_of_cont(unmarshal_continuation valenv program pickled_continuation)); *)
    ContInvoke (unmarshal_continuation unmarshal_envs pickled_continuation, params)

(* Extract expression/environment pair from the parameters passed in over CGI.*)
let expr_eval_req (valenv, nenv, tyenv) program params =
  let string_pair (l, r) =
    `Extend
      (StringMap.from_alist [("1", `Constant (`String l));
                             ("2", `Constant (`String r))],
       None) in
  let tenv = Var.varify_env (nenv, tyenv.Types.var_env) in
  let closures = Ir.ClosureTable.program tenv program in
  let valenv = Value.with_closures valenv (closures) in
  let unmarshal_envs = Value.build_unmarshal_envs (valenv, nenv, tyenv) program in
    match Value.unmarshal_value unmarshal_envs (List.assoc "_k" params) with
      | `RecFunction ([(f, (_xs, _body))], locals, _) as v ->
          let json_args =
            try (match Json.parse_json_b64 (List.assoc "_jsonArgs" params) with
                   | `Record fields -> fields
                   | _ -> assert false) 
            with NotFound _ -> [] in

          (* we don't need to pass the args in here as they are read using the environment
             function *)

          (*           let params = List.filter (not -<- is_special_param) params in *)            
          (*           let args = *)
          (*             List.fold_right *)
          (*               (fun pair env -> *)
          (*                  `ApplyPure (`Variable (Env.String.lookup nenv "Cons"), [string_pair pair; env])) *)
          (*               params *)
          (*               (`Variable (Env.String.lookup nenv "Nil")) in *)


          (* TODO: add json_args to environment? *)
          let env = Value.bind f (v, `Local) locals in
            ExprEval (`Apply (`Variable f, []), env)
      | _ -> assert false

let is_remote_call params =
  List.mem_assoc "__name" params && List.mem_assoc "__args" params

let is_func_appln params =
  List.mem_assoc "__name" params && List.mem_assoc "__args" params

let is_client_call_return params = 
  List.mem_assoc "__continuation" params && List.mem_assoc "__result" params

let is_contin_invocation params = 
  List.mem_assoc "_cont" params

let is_expr_request = List.exists is_special_param
        
let client_return_req cgi_args = 
  let continuation = decode_continuation (List.assoc "__continuation" cgi_args) in
  let arg = Json.parse_json_b64 (List.assoc "__result" cgi_args) in
    ClientReturn(continuation, arg)

let error_page_stylesheet = 
  "<style>pre {border : 1px solid #c66; padding: 4px; background-color: #fee} code.typeError {display: block; padding:1em;}</style>"

let error_page body = 
  "<html>\n  <head>\n    <title>Links error</title>\n    " ^ 
    error_page_stylesheet ^ 
    "\n  </head>\n  <body>" ^ 
    body ^ 
    "\n  </body></html>\n"

let is_multipart () =
  ((Cgi.safe_getenv "REQUEST_METHOD") = "POST" &&
      Cgi.string_starts_with (Cgi.safe_getenv "CONTENT_TYPE") "multipart/form-data")

let wrap_with_render_page (nenv, {Types.tycon_env=tycon_env; Types.var_env=_}) (bs, body) =
  let xb, x = Var.fresh_var_of_type (Instantiate.alias "Page" [] tycon_env) in
    (bs @ [`Let (xb, ([], body))],
     `Apply (`Variable (Env.String.lookup nenv "renderPage"), [`Variable x]))

let perform_request 
    (valenv, nenv, tyenv)
    (globals, (locals, main)) (* original source: only used for generating js *)
    req =
  match req with
    | ContInvoke (cont, params) ->
        Lib.print_http_response [("Content-type", "text/html")]
          (Value.string_of_value 
             (Evalir.apply_cont_safe cont valenv (`Record params)))
    | ExprEval(expr, locals) ->        
        let env = Value.shadow valenv ~by:locals in
        let v = snd (Evalir.run_program env (wrap_with_render_page (nenv, tyenv) ([], expr))) in
          Lib.print_http_response [("Content-type", "text/html")]
            (Value.string_of_value v)               
    | ClientReturn(cont, value) ->
(*        Interpreter.has_client_context := true;*)
        let result_json = (Json.jsonize_value 
                             (Evalir.apply_cont_safe cont valenv value)) in
        Lib.print_http_response [("Content-type", "text/plain")]
          (Utility.base64encode result_json)
    | RemoteCall(func, args) ->
(*        Interpreter.has_client_context := true;*)
        let result = Evalir.apply_safe valenv (func, args) in
	  Lib.print_http_response [("Content-type", "text/plain")]
            (Utility.base64encode (Json.jsonize_value result))
    | CallMain -> 
        Lib.print_http_response [("Content-type", "text/html")] 
          (if is_client_program (globals @ locals, main) then
             assert false
(*             Irtojs.generate_program_page Lib.typing_env (List.map fst globals) program *)
           else
(*           Debug.print ("valenv domain: "^IntMap.fold (fun name _ s -> s ^ string_of_int name ^ "\n") valenv "\n");*)
             let program = wrap_with_render_page (nenv, tyenv) (locals, main) in
             let tenv = Var.varify_env (nenv, tyenv.Types.var_env) in
(*                  Debug.print ("tenv domain: "^Env.Int.fold (fun name _ s -> s ^ string_of_int name ^ "\n") tenv "\n"); *)
             let closures = Ir.ClosureTable.program tenv (globals @ (fst program), snd program) in
(*                  Debug.print ("closures: "^Ir.Show_closures.show closures); *)              
             let valenv = Value.with_closures valenv (closures) in
             let _env, v = Evalir.run_program valenv program in
               Value.string_of_value v)

let serve_request (valenv, nenv, (tyenv : Types.typing_environment)) (globals, (locals, main)) = 
  try 
    let cgi_args =
      if is_multipart () then
        List.map (fun (name, {Cgi.value=value}) ->
                    (name, value)) (Cgi.parse_multipart_args ())
      else
        Cgi.parse_args () in
      Lib.cgi_parameters := cgi_args;
      let lookup = Lib.primitive_stub in
      let request =
        if is_remote_call cgi_args then
          get_remote_call_args lookup cgi_args
        else if is_client_call_return cgi_args then
          client_return_req cgi_args
        else if (is_contin_invocation cgi_args) then
          contin_invoke_req (valenv, nenv, tyenv) (globals @ locals, main) cgi_args
        else if (is_expr_request cgi_args) then
          expr_eval_req (valenv, nenv, tyenv) (globals @ locals, main) cgi_args
        else
          CallMain
      in
        perform_request (valenv, nenv, tyenv) (globals, (locals, main)) request
  with
      (* FIXME: errors need to be handled differently
         between user-facing and remote-call modes. *)
      Failure msg as e -> 
        prerr_endline msg;
        Lib.print_http_response [("Content-type", "text/html; charset=utf-8")] 
          (error_page (Errors.format_exception_html e))
    | exc -> Lib.print_http_response [("Content-type", "text/html; charset=utf-8")]
        (error_page (Errors.format_exception_html exc))
          
let serve_request envs (globals, main) =
  Errors.display (lazy (serve_request envs (globals, main)))
