-- net/reply.lua
-- Слой: net (единственное место, где вызывается Neutron)
-- Спека: specs/net-intents-reply.md
-- Назначение: Единая отправка текстовых уведомлений и ответов игроку через api.console.tell.
-- Публичные функции:
--   tell(api, client, text) -> boolean
--   denied(api, client, reason) -> boolean
--   ok(api, client, text) -> boolean

local log = require("core/log")

local M = {}

local logged_unavailable = false

-- Отправка произвольного сообщения клиенту в чат
function M.tell(api, client, text)
    if not (api and api.console and type(api.console.tell) == "function") then
        if not logged_unavailable then
            logged_unavailable = true
            log("reply_unavailable", {})
        end
        return false
    end

    -- docs: docs/neutron/api/libraries/console.md:143: api.console.tell(message: string, client: Client)
    local ok, err = pcall(api.console.tell, text, client)
    if not ok then
        log("reply_error", { error = tostring(err) })
        return false
    end
    return true
end

-- Отправка сообщения об отказе выполнения действия
function M.denied(api, client, reason)
    return M.tell(api, client, "[Отказ] " .. tostring(reason or "Действие запрещено"))
end

-- Отправка сообщения об успешном выполнении действия
function M.ok(api, client, text)
    return M.tell(api, client, "[Успех] " .. tostring(text or ""))
end

return M
