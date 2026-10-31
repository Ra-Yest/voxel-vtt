-- net/intents.lua
-- Слой: net (единственное место, где вызывается Neutron)
-- Спека: specs/net-split-server.md
-- Назначение: Приём сетевых намерений от клиентов (MoveToken) через Neutron channel.
-- Публичные функции:
--   serve(execute) -> boolean

local log = require("core/log")
local identity_mod = require("net/identity")

local M = {}

-- Регистрация приёма серверных сообщений (в т.ч. MoveToken)
function M.serve(execute)
    local channel = require("net/channel")
    local subscribed = false
    local ok_sub, err_sub = pcall(function()
        channel.on("MoveToken", function(payload, client)
            local ok_h, err_h = pcall(function()
                local sender_id, role = identity_mod.sender_of(client)
                if not sender_id then
                    log("auth_denied", { name = "MoveToken", reason = "sender_unknown" })
                    return
                end

                log("token_move_command", {
                    client = sender_id,
                    token_id = payload and payload.token_id,
                    target_cell = payload and payload.target_cell,
                    from_cell = payload and payload.from_cell,
                })

                local actor = { id = sender_id, is_master = identity_mod.is_master(role) }
                if execute then
                    return execute("MoveToken", actor, payload)
                end
            end)
            if not ok_h then
                log("command_error", { name = "MoveToken", error = tostring(err_h) })
            end
        end)
        subscribed = true
    end)

    if ok_sub and subscribed then
        log("server_messages_registered", { list = { "MoveToken" } })
        return true
    else
        log("neutron_api_missing", { part = "messages" })
        return false
    end
end

return M
