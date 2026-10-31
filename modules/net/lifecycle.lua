-- net/lifecycle.lua
-- Слой: net (единственное место, где вызывается Neutron)
-- Спека: specs/net-split-server.md
-- Назначение: Логирование жизненного цикла сервера и подключений клиентов.
-- Публичные функции:
--   init(api) -> boolean

local log = require("core/log")
local identity_mod = require("net/identity")

local M = {}

-- Инициализация логирования жизненного цикла сервера
function M.init(api)
    if type(events) ~= "table" or type(events.on) ~= "function" then
        log("neutron_api_missing", { part = "events" })
        return false
    end

    -- docs: docs/engine/scripting/events.md:180: events.on(event: str, callback: function)
    events.on("server:client_connected", function(client)
        local client_identity = identity_mod.label(client)
        log("server_client_connected", { client = client_identity })
    end)

    log("server_lifecycle_init", { status = "active" })
    return true
end

return M
