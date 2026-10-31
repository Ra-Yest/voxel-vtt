-- core/log.lua
-- Слой: core (чистый Lua, без вызовов движка)
-- Спека: specs/core-log.md
-- Назначение: Единый логгер VTT. Без зависимостей от движка.
-- Публичные функции:
--   log(tag, data)
--   serialize(val)

local M = {}

M.sink = print
M.enabled = true

local function ser(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "table" then
        if depth > 3 then return "{...}" end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = tostring(k) .. "=" .. ser(v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

M.serialize = ser

-- log(tag, data): одна строка вида "[tag] {k=v, ...}".
function M.log(tag, data)
    if not M.enabled then return end
    local line = "[" .. tostring(tag) .. "]"
    if data ~= nil then line = line .. " " .. ser(data) end
    M.sink(line)
end

return setmetatable(M, { __call = function(_, tag, data) return M.log(tag, data) end })
