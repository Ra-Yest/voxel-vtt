-- scripts/world.lua
-- Скрипт жизненного цикла мира контент-пака VTT на сервере и клиенте VoxelCore/Neutron.
-- docs: docs/engine/scripting/events.md:105: Callbacks specified in world.lua script

local log = require("core/log")

-- docs: docs/engine/scripting/events.md:108: function on_world_open()
function on_world_open()
    -- docs: docs/neutron/api/index.md:8: if _G["$Multiplayer"].side == "server" then
    if _G["$Multiplayer"] then
        local m = _G["$Multiplayer"]
        if m.side == "server" then
            log("server_started", { side = "server" })

            -- docs: docs/neutron/api/index.md:32: local api = require(string.format("%s:api/%s/api", m.pack_id, m.api_references.Neutron[2]))[m.side]
            local api = require(string.format("%s:api/%s/api", m.pack_id, m.api_references.Neutron[2]))[m.side]

            local world = require("server/world")
            local tokens = require("server/tokens")
            local commands = require("server/commands")
            commands.init(tokens)
            local block_interceptor = require("net/block_interceptor")
            block_interceptor.init(api, world, {
                tokens_module = tokens,
                commands_module = commands,
            })
            require("net/block_guard").init(api)
        -- docs: docs/neutron/api/index.md:10: elseif _G["$Multiplayer"].side == "client" then
        elseif m.side == "client" then
            log("client_started", { side = "client" })

            -- docs: docs/neutron/api/index.md:32: local api = require(string.format("%s:api/%s/api", m.pack_id, m.api_references.Neutron[2]))[m.side]
            local api = require(string.format("%s:api/%s/api", m.pack_id, m.api_references.Neutron[2]))[m.side]

            local block_interceptor = require("net/block_interceptor")
            block_interceptor.init_client(api)
        end
    end
end
