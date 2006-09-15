(** Converts the tree returned by the parser into our internal
    representation *)
exception ConcreteSyntaxError of (string * (Lexing.position * Lexing.position))
exception RedundantPatternMatch of Syntax.position

val define_xml_type : string -> Sugartypes.datatype -> unit
val desugar : (Sugartypes.pposition -> Syntax.position) -> Sugartypes.phrase -> Syntax.untyped_expression
val desugar_datatype : Sugartypes.datatype -> Types.assumption
