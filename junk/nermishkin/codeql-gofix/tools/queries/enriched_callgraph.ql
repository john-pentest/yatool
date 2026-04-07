import go

private string callerQualifiedName(FuncDef fd) {
  if exists(Function f | f.getFuncDecl() = fd)
  then result = any(Function f | f.getFuncDecl() = fd | f.getQualifiedName())
  else result = ""
}

private string referredQualifiedName(Expr e) {
  if exists(Entity ent |
    (e instanceof SelectorExpr and e.(SelectorExpr).refersTo(ent)) or
    (e instanceof Ident and e.(Ident).refersTo(ent))
  )
  then result = any(Entity ent |
    ((e instanceof SelectorExpr and e.(SelectorExpr).refersTo(ent)) or
    (e instanceof Ident and e.(Ident).refersTo(ent)))
    | ent.getQualifiedName()
  )
  else result = ""
}

private string baseQualifiedType(Expr e) {
  if exists(SelectorExpr s, Type t, string q |
    s = e and
    (t = s.getBase().getType().(PointerType).getBaseType() or t = s.getBase().getType().getUnderlyingType()) and
    q = t.getQualifiedName()
  )
  then result = any(SelectorExpr s, Type t, string q |
    s = e and
    (t = s.getBase().getType().(PointerType).getBaseType() or t = s.getBase().getType().getUnderlyingType()) and
    q = t.getQualifiedName()
    | q
  )
  else result = ""
}

from CallExpr call, FuncDef caller,
  string caller_file, string caller_name, string caller_qname,
  int caller_line, int caller_col,
  int call_line, int call_col,
  string callee_expr, string callee_qname, string base_qname, string callee_sig
where
  caller = call.getEnclosingFunction() and
  caller_file = caller.getLocation().getFile().getRelativePath() and
  caller_name = caller.getName() and
  caller_qname = callerQualifiedName(caller) and
  caller_line = caller.getLocation().getStartLine() and
  caller_col = caller.getLocation().getStartColumn() and
  call_line = call.getLocation().getStartLine() and
  call_col = call.getLocation().getStartColumn() and
  callee_expr = call.getCalleeExpr().toString() and
  callee_qname = referredQualifiedName(call.getCalleeExpr()) and
  base_qname = baseQualifiedType(call.getCalleeExpr()) and
  callee_sig = call.getCalleeExpr().getType().toString()
select caller_file, caller_name, caller_qname, caller_line, caller_col, call_line, call_col, callee_expr, callee_qname, base_qname, callee_sig
