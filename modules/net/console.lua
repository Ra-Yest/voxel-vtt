-- net/console.lua
-- Слой: net (единственное место, где вызывается Neutron)
-- Спека: specs/net-split-server.md, specs/net-console-commands.md
-- Назначение: Регистрация серверных консольных команд чата через Neutron api.console.set_command.
--   Маршрутизация вызовов через функцию execute без зависимости от server/*.
-- Публичные функции:
--   register(api, execute) -> boolean

local log = require("core/log")
local identity_mod = require("net/identity")

local M = {}

-- Единое логирование результатов консольных команд (result vs error)
local function log_command_result(tag, fields, ok, res, fallback_id)
    local data = {}
    for k, v in pairs(fields) do
        data[k] = v
    end
    data.success = ok
    if ok then
        if tag == "command_result_token_spawn" then
            data.token_id = (type(res) == "table" and res.token_id) or fallback_id
        else
            data.result = (res ~= nil) and res or true
        end
    else
        data.error = tostring(res or "unknown_error")
    end
    log(tag, data)
end

-- Общая функция исполнения консольной команды через переданный execute
local function run(api, execute, client, name, payload)
    local sender_id, role = identity_mod.sender_of(client)
    if sender_id == nil then
        log("auth_denied", { name = name, reason = "sender_unknown" })
        if api and api.console and api.console.tell then
            -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
            pcall(function() api.console.tell("[Отказ] Не удалось определить отправителя (sender_unknown)", client) end)
        end
        return false, "sender_unknown"
    end

    local actor = { id = sender_id, is_master = identity_mod.is_master(role) }
    local ok, res = execute(name, actor, payload)

    if api and api.console and api.console.tell then
        pcall(function()
            if ok then
                -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
                api.console.tell("[Успех] Команда " .. name .. " выполнена", client)
            else
                -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
                api.console.tell("[Отказ] " .. tostring(res or "Действие запрещено"), client)
            end
        end)
    end
    return ok, res
end

-- Регистрация всех 5 консольных команд чата
function M.register(api, execute)
    if not (api and api.console and api.console.set_command) then
        log("neutron_api_missing", { part = "console" })
        return false
    end

    if type(execute) ~= "function" then
        error("execute must be a function")
    end

    -- Вторая линия защиты: по умолчанию member тоже имеет это право, решение принимает execute/gm_rules
    -- docs: docs/neutron/api/libraries/console.md:54: {permissions={"time_management"}}
    -- docs: docs/neutron/core/server-config.md:150: role_management - Управление ролями игроков
    local permissions = { permissions = { "role_management" } }
    local can_use_unauthorized = false

    -- 1. block_set
    -- docs: docs/neutron/api/libraries/console.md:48: block_set: x=, y=, z=, id=[number] -> Set Block
    local scheme_block_set = "block_set: x=<number>, y=<number>, z=<number>, id=[number] -> Set Block"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_block_set, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local x = tonumber(args.x)
        local y = tonumber(args.y)
        local z = tonumber(args.z)
        local id = tonumber(args.id) or 1

        log("command_exec_block_set", {
            x = x,
            y = y,
            z = z,
            id = id,
            client = client_identity,
        })

        local payload = { x = x, y = y, z = z, id = id }
        local ok, res = run(api, execute, client, "SetBlock", payload)

        log_command_result("command_result_block_set", {
            x = x,
            y = y,
            z = z,
            id = id,
        }, ok, res)
    end, can_use_unauthorized)

    log("test_command_registered", { scheme = scheme_block_set, restricted = true })

    -- 2. token_spawn
    local scheme_spawn = "token_spawn: cx=<number>, cz=<number>, id=[string], owner=[string] -> Spawn token"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_spawn, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local cx = tonumber(args.cx)
        local cz = tonumber(args.cz)
        local id = (type(args.id) == "string" and args.id ~= "") and args.id or nil
        local owner = (type(args.owner) == "string" and args.owner ~= "") and args.owner or nil

        log("command_exec_token_spawn", {
            cx = cx,
            cz = cz,
            id = id,
            client = client_identity,
        })

        local payload = {
            cell = { cx = cx, cz = cz, level = 0 },
            asset_id = "vtt:token",
            name = id or "Token",
            id = id,
            owner = owner,
        }
        local ok, res = run(api, execute, client, "SpawnToken", payload)
        log_command_result("command_result_token_spawn", { cx = cx, cz = cz }, ok, res, id)
    end, can_use_unauthorized)

    -- 3. token_move
    local scheme_move = "token_move: id=<string>, cx=<number>, cz=<number> -> Move token"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_move, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local id = tostring(args.id)
        local cx = tonumber(args.cx)
        local cz = tonumber(args.cz)

        log("command_exec_token_move", {
            id = id,
            cx = cx,
            cz = cz,
            client = client_identity,
        })

        local payload = {
            token_id = id,
            target_cell = { cx = cx, cz = cz, level = 0 },
        }
        local ok, res = run(api, execute, client, "MoveToken", payload)
        log_command_result("command_result_token_move", { id = id, cx = cx, cz = cz }, ok, res)
    end, can_use_unauthorized)

    -- 4. token_remove
    local scheme_remove = "token_remove: id=<string> -> Remove token"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_remove, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local id = tostring(args.id)

        log("command_exec_token_remove", {
            id = id,
            client = client_identity,
        })

        local payload = { token_id = id }
        local ok, res = run(api, execute, client, "RemoveToken", payload)
        log_command_result("command_result_token_remove", { id = id }, ok, res)
    end, can_use_unauthorized)

    -- 5. token_owner
    local scheme_owner = "token_owner: id=<string>, owner=[string] -> Set or clear token owner"
    -- docs: docs/neutron/api/libraries/console.md:11: api.console.set_command(схема: string, разрешения: table, исполнитель: function, [опционально] можно_ли_использовать_без_авторизации: boolean)
    api.console.set_command(scheme_owner, permissions, function(args, client)
        local client_identity = identity_mod.label(client)
        local id = tostring(args.id)
        local owner = (type(args.owner) == "string" and args.owner ~= "") and args.owner or nil

        log("command_exec_token_owner", {
            id = id,
            owner = owner,
            client = client_identity,
        })

        local payload = { token_id = id, owner = owner }
        local ok, res = run(api, execute, client, "SetTokenOwner", payload)
        log_command_result("command_result_token_owner", { id = id, owner = owner }, ok, res)
    end, can_use_unauthorized)

    log("token_commands_registered", { schemes = { "token_spawn", "token_move", "token_remove", "token_owner" } })
    return true
end

return M
