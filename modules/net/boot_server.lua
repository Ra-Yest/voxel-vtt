-- net/boot_server.lua
-- Слой: net (точка сборки серверного сетевого слоя)
-- Спека: specs/net-split-server.md
-- Назначение: Единая безопасная инициализация серверных сетевых подсистем Neutron.
-- Публичные функции:
--   start(api, deps) -> boolean

local log = require("core/log")

local M = {}

-- Запуск всех серверных сетевых подсистем в строго определённом порядке
function M.start(api, deps)
    deps = deps or {}

    if type(api) ~= "table" then
        log("neutron_api_missing", { part = "api" })
        log("net_boot", { status = "skipped", reason = "no_api" })
        return false
    end

    local channel = require("net/channel")
    local identity_mod = require("net/identity")
    local lifecycle = require("net/lifecycle")
    local token_entity = require("net/token_entity")
    local console_mod = require("net/console")
    local intents = require("net/intents")
    local block_guard = require("net/block_guard")

    local all_ok = true
    local has_execute = (type(deps.execute) == "function")

    local function run_step(part_name, fn)
        local ok, err = pcall(fn)
        if not ok then
            all_ok = false
            log("net_boot_error", { part = part_name, error = tostring(err) })
            return false
        end
        return true
    end

    -- 1. channel.init(api)
    run_step("channel", function()
        channel.init(api)
    end)

    -- 2. identity.init(api)
    run_step("identity", function()
        identity_mod.init(api)
    end)

    -- 3. lifecycle.init(api)
    run_step("lifecycle", function()
        lifecycle.init(api)
    end)

    -- 4. token_entity.register_server(api, deps.token_id_of)
    run_step("token_entity", function()
        token_entity.register_server(api, deps.token_id_of)
    end)

    -- 5 & 6. console и intents (только при наличии deps.execute)
    if has_execute then
        run_step("console", function()
            console_mod.register(api, deps.execute)
        end)
        run_step("intents", function()
            intents.serve(deps.execute)
        end)
    else
        all_ok = false
    end

    -- 7. block_guard.init(api, { read_block = deps.read_block }) (всегда, даже без execute)
    run_step("block_guard", function()
        block_guard.init(api, { read_block = deps.read_block })
    end)

    if all_ok and has_execute then
        log("net_boot", { status = "ok" })
        return true
    elseif not has_execute then
        log("net_boot", { status = "partial", reason = "no_execute" })
        return false
    else
        log("net_boot", { status = "partial" })
        return false
    end
end

return M
