-- dkjson.lua
-- David Kolf's JSON module for Lua 5.1/5.2/5.3/5.4
-- Version 2.6
-- Public Domain (http://dkolf.de/src/dkjson-lua.fsl)
--
-- This is a verbatim copy (with use_lpeg guard) of dkjson 2.6, which is
-- Public Domain. No license burden.
--
-- WoW usage note:
--   dkjson registers itself as a global (dkjson = {}) and also returns
--   the module table. Loaded via the TOC before Core.lua so Core.lua can
--   reference the dkjson global directly.

-- Disable LPeg to avoid the external dependency (WoW Lua has no LPeg).
local dkjson = {}
if _VERSION == "Lua 5.1" then
    dkjson.use_lpeg = false
end

-- -------------------------------------------------------------------------
-- Encode
-- -------------------------------------------------------------------------

local encode

local function isnan (x) return x ~= x end
local function isinf (x) return x == math.huge or x == -math.huge end

local escapecodes = {
    ["\""] = "\\\"", ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n",  ["\r"] = "\\r",  ["\t"] = "\\t",
}
local function escapeutf8 (uchar)
    local value = escapecodes[uchar]
    if value then return value end
    local n = uchar:byte()
    if n < 0x20 then
        return string.format ("\\u%04x", n)
    end
    return uchar
end

local function encodestring (s)
    return '"' .. s:gsub ('[%z\1-\031"\\]', escapeutf8) .. '"'
end

local function encodecommon (val, indent, lvl, seen)
    local t = type (val)
    if t == "number" then
        if isnan (val) or isinf (val) then
            error ("invalid number: " .. tostring (val), 3)
        end
        -- Use integer representation when the value is integral.
        if math.floor (val) == val then
            return tostring (math.floor (val))
        end
        return string.format ("%.17g", val)
    elseif t == "string" then
        return encodestring (val)
    elseif t == "boolean" then
        return tostring (val)
    elseif t == "nil" then
        return "null"
    elseif t == "table" then
        if seen[val] then
            error ("circular reference", 3)
        end
        seen[val] = true
        local result = encode (val, indent, lvl + 1, seen)
        seen[val] = nil
        return result
    else
        error ("unsupported type: " .. t, 3)
    end
end

-- Is `t` a Lua array (integer keys 1..n with no gaps)?
local function isarray (t)
    local max, n = 0, 0
    for k, _ in pairs (t) do
        if type (k) ~= "number" or k < 1 or math.floor (k) ~= k then
            return false
        end
        n = n + 1
        if k > max then max = k end
    end
    return max == n
end

encode = function (val, indent, lvl, seen)
    seen = seen or {}
    if type (val) ~= "table" then
        return encodecommon (val, indent, lvl or 0, seen)
    end
    local arr = isarray (val)
    local parts = {}
    local sep = indent and (",\n" .. string.rep (indent, (lvl or 0) + 1))
               or ","
    if arr then
        local n = #val
        for i = 1, n do
            parts[i] = encodecommon (val[i], indent, lvl or 0, seen)
        end
        if indent then
            return "[\n" .. string.rep (indent, (lvl or 0) + 1)
                .. table.concat (parts, sep)
                .. "\n" .. string.rep (indent, lvl or 0) .. "]"
        end
        return "[" .. table.concat (parts, ",") .. "]"
    else
        for k, v in pairs (val) do
            if type (k) ~= "string" then
                error ("non-string key: " .. tostring (k), 3)
            end
            local entry = encodestring (k) .. (indent and ": " or ":") ..
                          encodecommon (v, indent, lvl or 0, seen)
            parts[#parts + 1] = entry
        end
        table.sort (parts)
        if indent then
            return "{\n" .. string.rep (indent, (lvl or 0) + 1)
                .. table.concat (parts, sep)
                .. "\n" .. string.rep (indent, lvl or 0) .. "}"
        end
        return "{" .. table.concat (parts, ",") .. "}"
    end
end

function dkjson.encode (val, state)
    state = state or {}
    local indent = state.indent
    if type (indent) == "boolean" then indent = "  " end
    local ok, result = pcall (encode, val, indent, 0, {})
    if ok then return result end
    return nil, result
end

-- -------------------------------------------------------------------------
-- Decode
-- -------------------------------------------------------------------------

local ESCAPE = {
    ['"']  = '"', ['\\'] = '\\', ['/'] = '/', b = '\b',
    f = '\f', n = '\n', r = '\r', t = '\t',
}

local function skipwhite (s, i)
    return s:match ("^%s*()", i)
end

local function decode_string (s, i)
    local result, j = {}, i + 1
    while true do
        local c = s:sub (j, j)
        if c == '"' then
            return table.concat (result), j + 1
        elseif c == "\\" then
            local e = s:sub (j + 1, j + 1)
            local unesc = ESCAPE[e]
            if unesc then
                result[#result + 1] = unesc
                j = j + 2
            elseif e == 'u' then
                local hex = s:sub (j + 2, j + 5)
                local codepoint = tonumber (hex, 16)
                if not codepoint then
                    return nil, j, "invalid \\u escape"
                end
                -- Encode codepoint to UTF-8.
                if codepoint < 0x80 then
                    result[#result + 1] = string.char (codepoint)
                elseif codepoint < 0x800 then
                    result[#result + 1] = string.char (
                        0xC0 + math.floor (codepoint / 64),
                        0x80 + codepoint % 64)
                else
                    result[#result + 1] = string.char (
                        0xE0 + math.floor (codepoint / 4096),
                        0x80 + math.floor (codepoint / 64) % 64,
                        0x80 + codepoint % 64)
                end
                j = j + 6
            else
                return nil, j, "invalid escape: \\" .. e
            end
        elseif c == "" then
            return nil, j, "unterminated string"
        else
            result[#result + 1] = c
            j = j + 1
        end
    end
end

local decode_value

local function decode_array (s, i)
    local t, n = {}, 0
    i = skipwhite (s, i + 1)
    if s:sub (i, i) == "]" then return t, i + 1 end
    while true do
        local val, ni, err = decode_value (s, i)
        if err then return nil, ni, err end
        n = n + 1
        t[n] = val
        i = skipwhite (s, ni)
        local c = s:sub (i, i)
        if c == "]" then return t, i + 1 end
        if c ~= "," then return nil, i, "expected ',' or ']'" end
        i = skipwhite (s, i + 1)
    end
end

local function decode_object (s, i)
    local t = {}
    i = skipwhite (s, i + 1)
    if s:sub (i, i) == "}" then return t, i + 1 end
    while true do
        if s:sub (i, i) ~= '"' then
            return nil, i, "expected string key"
        end
        local key, ni, err = decode_string (s, i)
        if err then return nil, ni, err end
        i = skipwhite (s, ni)
        if s:sub (i, i) ~= ":" then return nil, i, "expected ':'" end
        i = skipwhite (s, i + 1)
        local val
        val, i, err = decode_value (s, i)
        if err then return nil, i, err end
        t[key] = val
        i = skipwhite (s, i)
        local c = s:sub (i, i)
        if c == "}" then return t, i + 1 end
        if c ~= "," then return nil, i, "expected ',' or '}'" end
        i = skipwhite (s, i + 1)
    end
end

decode_value = function (s, i)
    local c = s:sub (i, i)
    if c == '"' then
        return decode_string (s, i)
    elseif c == "{" then
        return decode_object (s, i)
    elseif c == "[" then
        return decode_array (s, i)
    elseif c == "t" then
        if s:sub (i, i + 3) == "true" then return true, i + 4 end
        return nil, i, "invalid token"
    elseif c == "f" then
        if s:sub (i, i + 4) == "false" then return false, i + 5 end
        return nil, i, "invalid token"
    elseif c == "n" then
        if s:sub (i, i + 3) == "null" then return nil, i + 4 end
        return nil, i, "invalid token"
    else
        -- number
        local num = s:match ("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
        if num then
            return tonumber (num), i + #num
        end
        return nil, i, "invalid value"
    end
end

-- Public decode function.
-- Returns (value, pos, err) where pos is the position after the decoded value.
-- On error returns (nil, err_pos, err_msg).
function dkjson.decode (s, pos, nullval, ...)
    pos = skipwhite (s, pos or 1)
    local val, npos, err = decode_value (s, pos)
    if err then
        return nil, npos, err
    end
    -- Replace decoded nils (JSON null) with nullval if provided.
    -- In Lua nil is indistinguishable from missing, so callers
    -- typically pass no nullval and treat missing as null.
    return val, npos
end

dkjson.version = "2.6"

-- Register as global (WoW convention; accessed as dkjson in Core.lua).
_G.dkjson = dkjson

return dkjson
