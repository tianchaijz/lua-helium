local parser = require "parser"

local error = error
local ipairs = ipairs
local setmetatable = setmetatable
local concat = table.concat
local rep = string.rep
local format = string.format


local function append(list, elm)
    list[#list + 1] = elm
end


local T = {}
local mt = { __index = T }


function T.new(env)
    return setmetatable({ buf = {} }, mt)
end


function T:_expr(node)
    local tag = node[1]
    if tag == "number" then
        return node[2]
    elseif tag == "string" then
        return format('"%s"', node[2])
    end

    if tag == "ref" then
        return node[2]
    end

    if tag == "call" then
        return self:_call(node)
    end

    local op = tag
    local lhs, rhs = self:_expr(node[2]), self:_expr(node[3])
    if op == "+" then
        return format("(%s + %s)", lhs, rhs)
    elseif op == "-" then
        return format("(%s - %s)", lhs, rhs)
    elseif op == "%" then
        return format("(%s % %s)", lhs, rhs)
    elseif op == "*" then
        return format("(%s * %s)", lhs, rhs)
    elseif op == "/" then
        return format("(%s / %s)", lhs, rhs)
    elseif op == ">" then
        return format("(%s > %s)", lhs, rhs)
    elseif op == ">=" then
        return format("(%s >= %s)", lhs, rhs)
    elseif op == "<" then
        return format("(%s < %s)", lhs, rhs)
    elseif op == "<=" then
        return format("(%s <= %s)", lhs, rhs)
    elseif op == "==" then
        return format("(%s == %s)", lhs, rhs)
    elseif op == "!=" then
        return format("(%s ~= %s)", lhs, rhs)
    end

    error(format("unexpected tag '%s'", tag))
end


function T:_if(node)
    local cond = self:_expr(node[2])
    local if_body = self:translate(node[3], {})
    local else_node = node[4]

    if else_node then
        local else_body = self:translate(else_node[2], {})
        return format("if %s then\n%s\nelse\n%s\nend", cond, if_body, else_body)
    end

    return format("if %s then\n%s\nend", cond, if_body)
end


function T:_while(node)
    local cond = self:_expr(node[2])
    local body = self:translate(node[3], {})

    return format("while %s do\n%s\nend", cond, body)
end


function T:_def(node)
    local id = node[2]
    local pars = concat(node[3], ", ")
    local body = self:translate(node[4], {})

    return format("local function %s(%s)\n%s\nend", id, pars, body)
end


function T:_call(node)
    local id = node[2]
    local args = {}
    for i, expr in ipairs(node[3]) do
        args[i] = self:_expr(expr)
    end

    return format("%s(%s)", id, concat(args, ", "))
end


function T:_return(node)
    local ret = node[2] and self:_expr(node[2])
    if ret then
        return format("return %s", ret)
    else
        return "return"
    end
end


function T:_assign(node)
    local id = node[2]
    local expr = node[3]

    return format("%s = %s", id, self:_expr(expr))
end


function T:_local(node)
    local id = node[2]
    local expr = node[3]

    return format("local %s = %s", id, self:_expr(expr))
end


function T:visit(node)
    local tag = node[1]
    local visit = self["_" .. tag] or self._expr
    return visit(self, node)
end


function T:translate(ast, buf)
    if not buf then
        buf = {}
    end

    for _, node in ipairs(ast) do
        append(buf, self:visit(node))
    end

    return concat(buf, "\n")
end


return T
