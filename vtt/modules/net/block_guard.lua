-- net/block_guard.lua
-- Слой: net (сетевой перехватчик защиты мира Neutron)
-- Спека: specs/net-block-guard.md
-- Назначение: Защита мира от изменения игроками (не-Мастерами). Перехватывает входящие пакеты
--             изменения блоков и спавна/взаимодействия с сущностями и отбрасывает их.

local log = require("core/log")
local gm_rules = require("core/gm_rules")
local identity = require("net/identity")

local M = {}

local denial_counts = {}

-- Создание функции-обработчика для перехвата пакета по имени
function M.make_guard(name)
    return function(client, original, edited)
        local ok, allowed = pcall(function()
            local sender_id, role = identity.sender_of(client)
            local is_gm = sender_id ~= nil and identity.is_master(role)
            local can_pass, reason = gm_rules.is_packet_allowed(name, is_gm)
            if can_pass then
                return true
            end

            local sid = sender_id or "unknown"
            local throttle_key = sid .. ":" .. name
            denial_counts[throttle_key] = (denial_counts[throttle_key] or 0) + 1
            local count = denial_counts[throttle_key]

            if count == 1 or (count % 20 == 0) then
                log("auth_denied", {
                    name = name,
                    sender_id = sid,
                    reason = reason,
                    count = count,
                })
            end

            return false
        end)

        if not ok then
            log("block_guard_error", {
                name = name,
                error = tostring(allowed),
            })
            return false
        end

        return allowed
    end
end

-- Инициализация серверного перехватчика
-- docs: docs/neutron/api/libraries/interceptors.md:20: api.interceptors.receive.add_interceptor(packet_type, interceptor)
-- docs: docs/neutron/api/libraries/interceptors.md:14: api.interceptors.packets.ClientMsg
function M.init(api)
    if not api then
        log("block_guard_unprotected", { part = "api" })
        return false
    end

    if type(api.interceptors) ~= "table" then
        log("block_guard_unprotected", { part = "interceptors" })
        return false
    end

    if type(api.interceptors.receive) ~= "table" or type(api.interceptors.receive.add_interceptor) ~= "function" then
        log("block_guard_unprotected", { part = "interceptors.receive.add_interceptor" })
        return false
    end

    if type(api.interceptors.packets) ~= "table" or type(api.interceptors.packets.ClientMsg) ~= "table" then
        log("block_guard_unprotected", { part = "interceptors.packets.ClientMsg" })
        return false
    end

    denial_counts = {}
    local missing = {}
    local registered_count = 0

    for _, name in ipairs(gm_rules.GUARDED_PACKETS) do
        -- docs: docs/neutron/api/libraries/interceptors.md:14: api.interceptors.packets.ClientMsg
        local packet_id = api.interceptors.packets.ClientMsg[name]
        if packet_id == nil then
            table.insert(missing, name)
            log("block_guard_packet_missing", { name = name })
        else
            -- docs: docs/neutron/api/libraries/interceptors.md:20: api.interceptors.receive.add_interceptor(packet_type, interceptor)
            api.interceptors.receive.add_interceptor(packet_id, M.make_guard(name))
            registered_count = registered_count + 1
        end
    end

    if #missing > 0 then
        log("block_guard_unprotected", { missing = missing })
        return false, missing
    end

    log("block_guard_active", { count = registered_count })
    return true
end

return M
