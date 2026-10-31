-- core/schema.lua
-- Слой: core (чистый Lua, без вызовов движка)
-- Спека: specs/core-schema.md
-- Назначение: Реестр схем и валидация команд MVP-0: SpawnToken, MoveToken, RemoveToken, Roll, Chat.
-- Публичные функции:
--   define(name, schema_def)
--   get(name)
--   validate(name, payload)

local M = {}

M.schemas = {}

-- Регистрация схемы команды
function M.define(name, schema_def)
    M.schemas[name] = schema_def
end

-- Получение схемы команды
function M.get(name)
    return M.schemas[name]
end

-- Валидация данных команды по схеме
function M.validate(name, payload)
    local schema = M.schemas[name]
    if not schema then
        return false, "Неизвестная команда: " .. tostring(name)
    end
    if type(payload) ~= "table" then
        return false, "Payload должен быть таблицей"
    end
    for field, rule in pairs(schema.fields or {}) do
        local val = payload[field]
        if rule.required and val == nil then
            return false, "Отсутствует обязательное поле: " .. field
        end
        if val ~= nil then
            if rule.type == "cell" then
                if type(val) ~= "table" or type(val.cx) ~= "number" or type(val.cz) ~= "number" then
                    return false, "Поле " .. field .. " должно быть клеткой {cx, cz, level}"
                end
            elseif type(val) ~= rule.type then
                return false, "Поле " .. field .. " должно иметь тип " .. rule.type
            end
        end
    end
    return true
end

-- Регистрация схем команд MVP-0
M.define("SpawnToken", {
    fields = {
        asset_id = { type = "string", required = true },
        cell = { type = "cell", required = true },
        name = { type = "string", required = true },
        owner = { type = "string", required = false },
        id = { type = "string", required = false },
    },
})

M.define("SetBlock", {
    fields = {
        x = { type = "number", required = true },
        y = { type = "number", required = true },
        z = { type = "number", required = true },
        id = { type = "number", required = false },
    },
})

M.define("SetTokenOwner", {
    fields = {
        token_id = { type = "string", required = true },
        owner = { type = "string", required = false },
    },
})

M.define("MoveToken", {
    fields = {
        token_id = { type = "string", required = true },
        target_cell = { type = "cell", required = true },
        from_cell = { type = "cell", required = false },
    },
})

M.define("RemoveToken", {
    fields = {
        token_id = { type = "string", required = true },
    },
})

M.define("Roll", {
    fields = {
        formula = { type = "string", required = true },
        comment = { type = "string", required = false },
    },
})

M.define("Chat", {
    fields = {
        text = { type = "string", required = true },
    },
})

return M
