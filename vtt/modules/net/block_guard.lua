-- net/block_guard.lua
-- Слой: net (сетевой перехватчик защиты мира Neutron с откатом блоков)
-- Спека: specs/net-block-guard.md, specs/net-block-revert.md
-- Назначение: Защита мира от изменения игроками (не-Мастерами). Перехватывает входящие пакеты
--             изменения блоков и сущностей, отбрасывает их и отправляет пакет коррекции (откат).

local log = require("core/log")
local gm_rules = require("core/gm_rules")
local identity = require("net/identity")

local M = {}

M.api = nil
M.opts = nil

local denial_counts = {}

local BLOCK_PACKETS = {
    BlockUpdate = true,
    BlockDestroy = true,
    BlockInteract = true,
    BlockRegionUpdate = true,
    BlockRegionDestroy = true,
    BlockRegionInteract = true,
}

-- Отправка пакета коррекции (отката) реального состояния блока клиенту
local function send_correction(client, name, original)
    if not BLOCK_PACKETS[name] then
        return
    end

    if not M.api or not M.api.protocol or type(M.api.protocol.tell) ~= "function" then
        return
    end

    if not M.opts or type(M.opts.read_block) ~= "function" then
        return
    end

    local is_region = name == "BlockRegionUpdate" or name == "BlockRegionDestroy" or name == "BlockRegionInteract"
    local raw_pos = nil

    if name == "BlockUpdate" or name == "BlockRegionUpdate" then
        if type(original) == "table" and type(original.block) == "table" and type(original.block.pos) == "table" then
            raw_pos = original.block.pos
        elseif type(original) == "table" and type(original.pos) == "table" then
            raw_pos = original.pos
        end
    else
        if type(original) == "table" and type(original.pos) == "table" then
            raw_pos = original.pos
        end
    end

    if not raw_pos or type(raw_pos.x) ~= "number" or type(raw_pos.y) ~= "number" or type(raw_pos.z) ~= "number" then
        log("block_guard_correction_skipped", { name = name, reason = "invalid_pos" })
        return
    end

    local abs_x, abs_y, abs_z
    if is_region then
        local region = identity.region_of(client)
        if not region then
            log("block_guard_correction_skipped", { name = name, reason = "no_region" })
            return
        end
        abs_x = region.x * 64 + raw_pos.x
        abs_y = raw_pos.y
        abs_z = region.z * 64 + raw_pos.z
    else
        abs_x = raw_pos.x
        abs_y = raw_pos.y
        abs_z = raw_pos.z
    end

    if abs_y < 0 or abs_y > 255 then
        log("block_guard_correction_skipped", { name = name, reason = "bad_y" })
        return
    end

    local id, state = M.opts.read_block(abs_x, abs_y, abs_z)
    if id == nil or state == nil then
        log("block_guard_correction_skipped", { name = name, reason = "read_failed" })
        return
    end

    local block_changed_id = (M.api.protocol and M.api.protocol.ServerMsg and M.api.protocol.ServerMsg.BlockChanged)
        or (M.api.interceptors and M.api.interceptors.packets and M.api.interceptors.packets.ServerMsg and M.api.interceptors.packets.ServerMsg.BlockChanged)
    if not block_changed_id then
        log("block_guard_correction_skipped", { name = name, reason = "no_packet_id" })
        return
    end

    -- docs: docs/neutron/api/libraries/protocol.md:22: protocol.tell(client, packet_type, data)
    M.api.protocol.tell(client, block_changed_id, {
        pid = -1,
        block = {
            id = id,
            state = state,
            pos = {
                x = abs_x,
                y = abs_y,
                z = abs_z,
            },
        },
    })
end

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

            -- Отправка пакета коррекции (отката) при отказе
            local ok_corr, err_corr = pcall(function()
                send_correction(client, name, original)
            end)
            if not ok_corr then
                log("block_guard_error", {
                    name = name,
                    error = tostring(err_corr),
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
function M.init(api, opts)
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

    M.api = api
    M.opts = opts or {}

    local has_protocol = type(api.protocol) == "table" and type(api.protocol.tell) == "function"
    local has_reader = type(M.opts) == "table" and type(M.opts.read_block) == "function"
    if not has_protocol or not has_reader then
        log("block_guard_correction_unavailable", {
            has_protocol = has_protocol,
            has_reader = has_reader,
        })
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
            local reg_ok, reg_err = pcall(function()
                -- docs: docs/neutron/api/libraries/interceptors.md:20: api.interceptors.receive.add_interceptor(packet_type, interceptor)
                api.interceptors.receive.add_interceptor(packet_id, M.make_guard(name))
            end)
            if not reg_ok then
                table.insert(missing, name)
                log("block_guard_error", { name = name, error = tostring(reg_err) })
            else
                registered_count = registered_count + 1
            end
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
