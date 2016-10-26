local io = require "io"
local os = require "os"
local parser = require "parser"


local type = type
local error = error
local pcall = pcall
local print = print
local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local unpack = unpack or table.unpack
local format = string.format


local function is_func(v) return type(v) == "function" end
local function is_num(v) return type(v) == "number" end
local function is_str(v) return type(v) == "string" end
local function is_tbl(v) return type(v) == "table" end


local function copytable(obj)
    local t = {}
    for k, v in pairs(obj) do
        t[k] = is_tbl(v) and copytable(v) or v
    end

    return t
end


local RETURN   = 0
local CONTINUE = 1
local BREAK    = 2


local function throw(kind, value)
    error({ kind = kind, value = value })
end


local I = {}
local mt = { __index = I }


local _parent = -1
local global_env = {
    write = io.write,
    print = print,
    exit = os.exit
}


local function resolve(id, env)
    if not env then
        return nil
    end

    return env[id] or resolve(id, env[_parent])
end


function I.new(env)
    return setmetatable({ env = env or copytable(global_env) }, mt)
end


function I:_expr(node, env)
    local tag = node[1]
    if tag == "number" or tag == "string" then
        return node[2]
    end

    if tag == "ref" then
        local id = node[2]
        return resolve(id, env) or
            error(format("use of undefined identifier '%s'", id))
    end

    if tag == "call" then
        return self:_call(node, env)
    end

    local op = tag
    local lhs, rhs = self:_expr(node[2], env), self:_expr(node[3], env)
    if op == "+" then
        return lhs + rhs
    elseif op == "-" then
        return lhs - rhs
    elseif op == "%" then
        return lhs % rhs
    elseif op == "*" then
        return lhs * rhs
    elseif op == "/" then
        return lhs / rhs
    elseif op == ">" then
        return lhs > rhs
    elseif op == ">=" then
        return lhs >= rhs
    elseif op == "<" then
        return lhs < rhs
    elseif op == "<=" then
        return lhs <= rhs
    elseif op == "==" then
        return lhs == rhs
    elseif op == "!=" then
        return lhs ~= rhs
    end

    error(format("unexpected tag '%s'", tag))
end


function I:_if(node, env)
    local cond = self:_expr(node[2], env)
    local else_node = node[4]
    if cond then
        return self:interpret(node[3], env)
    elseif else_node then
        return self:interpret(else_node[2], env)
    end
end


function I:_while(node, env)
    local cond = self:_expr(node[2], env)
    while cond do
        self:interpret(node[3], env)
        cond = self:_expr(node[2], env)
    end
end


function I:_def(node, env)
    local id = node[2]
    local pars = node[3]
    local body = node[4]
    env[id] = function(...)
        local args = { ... }
        local env = { [_parent] = env }
        for k, p in ipairs(pars) do
            env[p] = args[k]
        end

        return self:interpret(body, env)
    end
end


function I:_call(node, env)
    local id = node[2]
    local func = resolve(id, env)
    if not func then
        error(format("use of undefined function '%s'", id))
    end

    local args = {}
    for i, expr in ipairs(node[3]) do
        args[i] = self:_expr(expr, env)
    end

    local ok, ret = pcall(function() return func(unpack(args)) end)
    if ok then
        return
    end

    if is_str(ret) then
        error("unexpected error: " .. ret)
    end

    return ret.value
end


function I:_return(node, env)
    local ret = node[2] and self:_expr(node[2], env) or nil
    throw(RETURN, ret)
end


function I:_assign(node, env)
    local id = node[2]
    local expr = node[3]
    local value = self:_expr(expr, env)

    while true do
        if env[id] or env == self.env then
            env[id] = value
            break
        end
        env = env[_parent]
    end
end


function I:_local(node, env)
    local id = node[2]
    local expr = node[3]
    env[id] = self:_expr(expr, env)
end


function I:visit(node, env)
    local tag = node[1]
    local visit = self["_" .. tag] or self._expr
    return visit(self, node, env)
end


function I:interpret(ast, env)
    for _, node in ipairs(ast) do
        self:visit(node, env or self.env)
    end
end


return I
