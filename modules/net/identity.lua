-- net/identity.lua
-- Слой: net (единственное место, где читаются client.account и client.player)
-- Спека: specs/server-move-validation.md, specs/net-console-commands.md, specs/net-block-revert.md
-- Назначение: Извлечение идентичности (identity), роли (role) и позиции региона (region_pos) игрока
--             из объекта клиента Neutron с проверкой авторизации.

local log = require("core/log")

local M = {}

M.api = nil
M.MASTER_ROLE = "master"

local logged_pairs = {}
local not_logged_denials = {}

-- Инициализация ссылок на подсистемы Neutron
function M.init(api)
    M.api = api
    if not api then
        log("identity_init", { status = "no_api" })
    end
end

-- Проверка роли Мастера
function M.is_master(role)
    return role == M.MASTER_ROLE
end

-- Получение текстовой метки клиента для логирования (account.identity -> player.username -> "unknown")
function M.label(client)
    if type(client) ~= "table" then
        return "unknown"
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:22: client.account
    local account = client.account
    if type(account) == "table" and account.identity and account.identity ~= "" then
        -- docs: docs/neutron/api/libraries/extra-classes.md:10: account.identity = string
        return tostring(account.identity)
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:23: client.player
    local player = client.player
    if type(player) == "table" and player.username and player.username ~= "" then
        -- docs: docs/neutron/api/libraries/extra-classes.md:31: player.username = string
        return tostring(player.username)
    end

    return "unknown"
end

-- Получение идентичности и роли отправителя из клиента
-- Возвращает identity (string) | nil, role (string) | nil
function M.sender_of(client)
    if type(client) ~= "table" then
        return nil, nil
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:22: client.account
    local account = client.account
    if type(account) ~= "table" then
        return nil, nil
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:10: account.identity = string
    local identity = account.identity
    if identity == nil or identity == "" or (type(identity) ~= "string" and type(identity) ~= "number") then
        return nil, nil
    end
    identity = tostring(identity)

    -- docs: docs/neutron/api/libraries/extra-classes.md:12: account.is_logged = boolean
    if account.is_logged ~= true then
        if not not_logged_denials[identity] then
            not_logged_denials[identity] = true
            log("auth_denied", { sender_id = identity, reason = "not_logged" })
        end
        return nil, nil
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:13: account.role = string
    local role = account.role
    if role ~= nil then
        if type(role) == "string" and role ~= "" then
            role = tostring(role)
        else
            role = nil
        end
    end

    local pair_key = identity .. "::" .. tostring(role)
    if not logged_pairs[pair_key] then
        logged_pairs[pair_key] = true
        log("identity", { identity = identity, role = role })
    end

    return identity, role
end

-- Получение позиции региона игрока {x, y, z}
-- Возвращает {x, y, z} | nil
function M.region_of(client)
    if type(client) ~= "table" then
        return nil
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:23: client.player
    local player = client.player
    if type(player) ~= "table" then
        return nil
    end

    -- docs: docs/neutron/api/libraries/extra-classes.md:36: player.region_pos = { x = x, y = y, z = z }
    local rp = player.region_pos
    if type(rp) ~= "table" then
        return nil
    end

    if type(rp.x) ~= "number" or type(rp.y) ~= "number" or type(rp.z) ~= "number" then
        return nil
    end

    return { x = rp.x, y = rp.y, z = rp.z }
end

return M
