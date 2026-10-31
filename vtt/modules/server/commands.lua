-- server/commands.lua
-- Слой: server
-- Спека: specs/server-commands.md
-- Назначение: Реестр серверных команд MVP-0: SpawnToken, MoveToken, RemoveToken, Roll, Chat.
--   Приём намерений, проверка схемы, валидация прав, вызов обработчика и логирование.
-- Публичные функции:
--   register(name, def)
--   dispatch(name, sender_id, payload, table_session)
--   get(name)
--   init()

local log = require("core/log")
local schema = require("core/schema")
local gm_rules = require("core/gm_rules")

local M = {}

M.registry = {}

-- Регистрация команды в реестре
function M.register(name, def)
    M.registry[name] = {
        name = name,
        schema = def.schema or schema.get(name),
        check = def.check or function() return true end,
        handler = def.handler or function() return true end,
    }
    log("command_registered", { name = name })
end

-- Получение определения команды
function M.get(name)
    if not M.registry[name] and next(M.registry) == nil then
        M.init()
    end
    return M.registry[name]
end

-- Диспетчеризация входящей команды
function M.dispatch(name, sender_id, payload, table_session)
    log("command", { name = name, sender_id = sender_id })
    local cmd = M.registry[name]
    if not cmd and next(M.registry) == nil then
        M.init()
        cmd = M.registry[name]
    end
    if not cmd then
        log("command_unknown", { name = name, sender_id = sender_id })
        return false, "Неизвестная команда: " .. tostring(name)
    end

    -- 1. Валидация по схеме
    local valid, err_schema = schema.validate(name, payload)
    if not valid then
        log("schema_error", { name = name, sender_id = sender_id, error = err_schema })
        return false, err_schema
    end

    -- 2. Проверка прав (GM vs Player)
    local is_gm = table_session and table_session.is_gm and table_session.is_gm(sender_id) or false
    local check_ok, allowed, reason = pcall(cmd.check, sender_id, payload, is_gm, table_session)
    if not check_ok then
        log("command_error", { name = name, sender_id = sender_id, error = "check failed: " .. tostring(allowed) })
        return false, tostring(allowed)
    end
    if not allowed then
        log("auth_denied", { name = name, sender_id = sender_id, reason = reason })
        return false, reason or "Отказано в доступе"
    end

    -- 3. Исполнение команды
    local ok, res = pcall(cmd.handler, sender_id, payload, table_session)
    if not ok then
        log("command_error", { name = name, sender_id = sender_id, error = tostring(res) })
        return false, tostring(res)
    end
    if res == false then
        log("command_error", { name = name, sender_id = sender_id, error = "handler returned false" })
        return false, "Команда завершилась с ошибкой"
    end

    log("command_result", { name = name, sender_id = sender_id, success = true })
    return true, res
end

-- Инициализация базовых команд MVP-0
function M.init(tokens_mod, world_mod)
    M.tokens = tokens_mod or M.tokens
    M.world = world_mod or M.world
    M.register("SpawnToken", {
        check = function(sender_id, payload, is_gm, table_session)
            local allowed, reason = gm_rules.can_spawn_token(sender_id, is_gm, payload.owner)
            if not allowed then
                return false, reason
            end
            if payload.id ~= nil then
                local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
                if tokens_m and tokens_m.get and tokens_m.get(payload.id) ~= nil then
                    return false, "Токен с таким id уже существует"
                end
            end
            return true
        end,
        handler = function(sender_id, payload, table_session)
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            if tokens_m and tokens_m.spawn then
                local tid = tokens_m.spawn(payload.cell, {
                    id = payload.id,
                    name = payload.name,
                    asset_id = payload.asset_id,
                    owner_id = payload.owner,
                })
                return { token_id = tid }
            end
            return { token_id = payload.id or ("token_" .. tostring(os.time())) }
        end,
    })

    M.register("SetTokenOwner", {
        check = function(sender_id, payload, is_gm, table_session)
            local allowed, reason = gm_rules.can_set_token_owner(sender_id, is_gm)
            if not allowed then
                return false, reason
            end
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            local token = tokens_m and tokens_m.get and tokens_m.get(payload.token_id)
            if not token then
                return false, "Токен не найден"
            end
            return true
        end,
        handler = function(sender_id, payload, table_session)
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            if tokens_m and tokens_m.set_owner then
                local ok, err = tokens_m.set_owner(payload.token_id, payload.owner)
                if not ok then
                    error(err or "tokens.set_owner failed")
                end
                return { token_id = payload.token_id, owner = payload.owner }
            end
            return true
        end,
    })

    M.register("MoveToken", {
        check = function(sender_id, payload, is_gm, table_session)
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            local token = tokens_m and tokens_m.get and tokens_m.get(payload.token_id)
            if not token then
                return false, "Токен не найден"
            end
            local allowed, reason = gm_rules.can_move_token(token, payload.target_cell, sender_id, is_gm)
            if not allowed then
                return false, reason
            end
            if payload.from_cell and token.cell then
                if payload.from_cell.cx ~= token.cell.cx or payload.from_cell.cz ~= token.cell.cz or (payload.from_cell.level or 0) ~= (token.cell.level or 0) then
                    log("from_cell_mismatch", {
                        token_id = payload.token_id,
                        payload_from = payload.from_cell,
                        token_cell = token.cell,
                    })
                end
            end
            return true
        end,
        handler = function(sender_id, payload, table_session)
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            if tokens_m and tokens_m.move then
                local ok, err = tokens_m.move(payload.token_id, payload.target_cell)
                if not ok then
                    error(err or "tokens.move failed")
                end
                return ok
            end
            return true
        end,
    })

    M.register("RemoveToken", {
        check = function(sender_id, payload, is_gm, table_session)
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            local token = tokens_m and tokens_m.get and tokens_m.get(payload.token_id)
            if not token then
                return false, "Токен не найден"
            end
            return gm_rules.can_remove_token(token, sender_id, is_gm)
        end,
        handler = function(sender_id, payload, table_session)
            local tokens_m = (table_session and table_session.tokens_module) or M.tokens or package.loaded["server/tokens"] or require("server/tokens")
            if tokens_m and tokens_m.remove then
                local ok, err = tokens_m.remove(payload.token_id)
                if not ok then
                    error(err or "tokens.remove failed")
                end
                return ok
            end
            return true
        end,
    })

    M.register("Roll", {
        check = function(sender_id, payload, is_gm)
            return true
        end,
        handler = function(sender_id, payload, table_session)
            -- Заглушка: вызов gm_rules.parse_roll
            local parsed = gm_rules.parse_roll(payload.formula)
            return { parsed = parsed, result = 20 }
        end,
    })

    M.register("Chat", {
        check = function(sender_id, payload, is_gm)
            return true
        end,
        handler = function(sender_id, payload, table_session)
            -- Заглушка: рассылка сообщения чата
            return true
        end,
    })

    M.register("SetBlock", {
        check = function(sender_id, payload, is_gm, table_session)
            return gm_rules.can_modify_world(sender_id, is_gm)
        end,
        handler = function(sender_id, payload, table_session)
            local world_m = (table_session and table_session.world_module) or M.world or package.loaded["server/world"] or require("server/world")
            if world_m and world_m.set_block then
                local res = world_m.set_block(payload.x, payload.y, payload.z, payload.id or 1, 0)
                return res
            end
            return true
        end,
    })

    log("commands_init", { count = 7 })
end

return M
