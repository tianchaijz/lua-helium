local lpeg = require "lpeg"


local type = type
local tonumber = tonumber
local match = lpeg.match


lpeg.locale(lpeg)
lpeg.setmaxstack(10000)


local R, S, V, P, C, Ct, Cp, Cg, Cb, Cc, Cf =
    lpeg.R, lpeg.S, lpeg.V, lpeg.P, lpeg.C, lpeg.Ct,
    lpeg.Cp, lpeg.Cg, lpeg.Cb, lpeg.Cc, lpeg.Cf


local Break = P"\r"^-1 * P"\n"
local Comment = P("#") * (1 - P"\n")^0
local White = S" \t\r\n"
local Space = (White + Comment)^0
local Alpha = lpeg.alpha
local AlphaNum = R("az", "AZ", "09", "__")


local mark = function(name)
  return function(...)
    return {
      name,
      ...
    }
  end
end


local remark = function(name)
  return function(cap)
    cap[1] = name
    return cap
  end
end


local pos = function(patt)
  return (Cp() * patt) / function(pos, value)
    if type(value) == "table" then
      value[-1] = pos
    end
    return value
  end
end


local keyword = function(chars)
    return Space * chars * -AlphaNum
end


local sym = function(chars)
  return Space * chars
end


local op = function(chars)
    return Space * C(chars)
end


local function binaryOp(lhs, op, rhs)
  if not op then
    return lhs
  end

  return { op, lhs, rhs }
end


local function sepBy(patt, sep)
    return patt * Cg(sep * patt)^0
end


local function chainOp(patt, sep)
    return Cf(sepBy(patt, sep), binaryOp)
end


local function chain(patt, sep)
    return patt * (sep * patt)^0
end


local Keywords = P"if" + P"else" + P"end" + P"def" + P"while" +
                 P"return" + P"break" + P"continue"
local Id = Space * (C((Alpha + P"_") * AlphaNum^0) - Keywords)
local Num = Space * (P"-"^-1 * (R"09"^1 * P".")^-1 * R"09"^1 / tonumber) / mark("number")
local String = Space * (P'"' * C(((P"\\" * P(1)) + (P(1) - P'"'))^0) * P'"' +
                        P"'" * C(((P"\\" * P(1)) + (P(1) - P"'"))^0) * P"'")
                     / mark("string")

local CompOp = op(S"><" * P"="^-1) + op(S"!=" * P"=")
local AddOp = op(S"+-%")
local MulOp = op(S"*/")

local program = P({
    "Program",

    Program = V"Block" + Ct"",
    Block = Ct(V"Stat"^0),

    Stat = V"Def" + V"Assign" + V"LocalAssign" + V"Return"
         + V"Call" + V"If" + V"While",

    Assign = Id * sym("=") * V"Expr" / mark("assign"),
    LocalAssign = keyword("local") * V"Assign" / remark("local"),
    Return = keyword("return") * (V"Expr" + Cc(nil)) / mark("return"),

    CompExpr = V"Expr" * CompOp * V"Expr" / binaryOp,
    Cond = V"CompExpr" + sym("(") * V"CompExpr" * sym(")") + V"Expr",

    Expr = V"AddExpr",
    AddExpr = chainOp(V"MulExpr", AddOp),
    MulExpr = chainOp(V"Value", MulOp),
    Ref = Id / mark("ref"),
    Value = Num + String + V"Call" + V"Ref" + sym("(") * V"Expr" * sym(")"),

    ParsList = Ct(chain(Id, sym(","))^0),
    Pars = sym("(") * V"ParsList" * sym(")"),
    Def = keyword("def") * Id * V"Pars" * V"Block" * keyword("end") / mark("def"),

    ArgsList = Ct(chain(V"Expr", sym(","))^0),
    Args = sym("(") * V"ArgsList" * sym(")"),
    Call = Id * V"Args" / mark("call"),

    IfElse = keyword("else") * V"Block" / mark("else"),
    If = keyword("if") * V"Cond" * V"Block" * V"IfElse"^-1 * keyword("end") / mark("if"),

    While = keyword("while") * V"Cond" * V"Block" * keyword("end") / mark("while"),
})


local function parse(source)
    return match(program, source)
end


return { parse = parse }
