-- net/boot_client.lua
-- Слой: net (точка сборки клиентского сетевого слоя)
-- Спека: specs/net-split-client.md
-- Назначение: Единая безопасная инициализация клиентских сетевых подсистем Neutron.
-- Публичные функции:
--   start(api, deps) -> boolean

local log = require("core/log")

local M = {}

-- Запуск клиентских сетевых подсистем в строго определённом порядке
function M.start(api, deps)
    deps = deps or {}

    if type(api) ~= "table" then
        log("neutron_api_missing", { part = "api" })
        log("net_client_initialized", { status = "skipped", reason = "no_api" })
        return false
    end

    local channel = require("net/channel")
    local token_entity = require("net/token_entity")

    local all_ok = true
    local failed = {}
    local has_on_token = (type(deps.on_token) == "function")

    local function run_step(part_name, fn, expect_true)
        local ok, res = pcall(fn)
        if not ok then
            all_ok = false
            table.insert(failed, part_name)
            log("net_boot_error", { part = part_name, error = tostring(res) })
            return false
        end
        if res == false or (expect_true and res ~= true) then
            all_ok = false
            table.insert(failed, part_name)
            log("net_boot_error", { part = part_name, error = "returned false" })
            return false
        end
        return true
    end

    -- 1. channel.init(api)
    run_step("channel", function()
        return channel.init(api)
    end, false)

    -- 2. token_entity.register_client(api, deps.on_token)
    if has_on_token then
        run_step("token_entity", function()
            return token_entity.register_client(api, deps.on_token)
        end, true)
    else
        all_ok = false
        table.insert(failed, "token_entity")
    end

    if all_ok and #failed == 0 and has_on_token then
        log("net_client_initialized", { entity = "vtt:token", status = "ok" })
        return true
    elseif not has_on_token then
        log("net_client_initialized", { entity = "vtt:token", status = "partial", reason = "no_on_token", failed = failed })
        return false
    else
        log("net_client_initialized", { entity = "vtt:token", status = "partial", failed = failed })
        return false
    end
end

return M
