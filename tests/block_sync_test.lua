-- tests/block_sync_test.lua
-- Тесты для модуля net/block_interceptor.lua (S0.2: блок хост -> клиент)

local T = require("lib")
local interceptor = require("net/block_interceptor")
local log_mod = require("core/log")

T.test("block_interceptor: handle_packet логирует поля BlockChanged и возвращает true", function()
    local logged_line
    local old_sink = log_mod.sink
    log_mod.sink = function(line)
        logged_line = line
    end

    local mock_client = {
        account = { identity = "gm_user" },
        player = { username = "GM" },
    }
    local original = {
        pid = 1,
        block = {
            id = 5,
            state = 0,
            pos = { x = 10, y = 64, z = 20 },
        },
    }
    local edited = {
        pid = 1,
        block = {
            id = 5,
            state = 0,
            pos = { x = 10, y = 64, z = 20 },
        },
    }

    local pass = interceptor.handle_packet(mock_client, original, edited, "test_variant")
    T.eq(pass, true)
    T.truthy(logged_line ~= nil, "лог записан")
    T.truthy(logged_line:find("[net_block_changed]", 1, true), "тег net_block_changed")
    T.truthy(logged_line:find("block_id=5", 1, true), "block_id=5")
    T.truthy(logged_line:find("pid=1", 1, true), "pid=1")
    T.truthy(logged_line:find('client="gm_user"', 1, true), "client identity")
    T.truthy(logged_line:find('variant="test_variant"', 1, true), "variant")

    -- Проверяем, что пакет не изменён (Rule: пакет не менять и не блокировать)
    T.eq(edited.block.id, 5)
    T.eq(edited.block.pos.x, 10)

    log_mod.sink = old_sink
end)

T.test("block_interceptor: handle_packet игнорирует не-блочные пакеты по умолчанию и дампит только при флаге", function()
    local logged_line
    local old_sink = log_mod.sink
    log_mod.sink = function(line)
        logged_line = line
    end

    local original = {
        msg = "hello",
        code = 42,
        active = true,
    }

    -- 1. По умолчанию не-блочные пакеты НЕ спамят в лог
    local pass = interceptor.handle_packet(nil, original, original, "generic")
    T.eq(pass, true)
    T.eq(logged_line, nil, "лог не должен спамить при не-блочных пакетах")

    -- 2. При явном флаге dump_non_blocks = true — логирует дамп
    pass = interceptor.handle_packet(nil, original, original, "generic_dump", true)
    T.eq(pass, true)
    T.truthy(logged_line ~= nil, "лог записан при dump_non_blocks = true")
    T.truthy(logged_line:find("[net_packet_dump]", 1, true), "тег net_packet_dump")
    T.truthy(logged_line:find('msg="hello"', 1, true), "scalar msg")
    T.truthy(logged_line:find("code=42", 1, true), "scalar code")

    log_mod.sink = old_sink
end)

T.test("block_interceptor: register_interceptors регистрирует варианты а, б, в", function()
    local calls = {}
    local mock_api = {
        interceptors = {
            send = {
                add_interceptor = function(packet_type, handler)
                    table.insert(calls, { type = "specific", packet_type = packet_type, handler = handler })
                end,
                add_generic_interceptor = function(handler)
                    table.insert(calls, { type = "generic", handler = handler })
                end,
            },
        },
    }

    interceptor.register_interceptors(mock_api, "all")
    T.eq(#calls, 3)
    T.eq(calls[1].packet_type, "BlockChanged")
    T.eq(calls[2].packet_type, "ServerMsg")
    T.eq(calls[3].type, "generic")
end)

T.test("block_interceptor: register_command регистрирует block_set с жесткими правами и вызывает world.set_block", function()
    local registered_scheme, registered_perms, registered_handler, registered_no_logged
    local mock_api = {
        console = {
            set_command = function(scheme, perms, handler, no_logged)
                registered_scheme = scheme
                registered_perms = perms
                registered_handler = handler
                registered_no_logged = no_logged
            end,
        },
    }

    local world_called_with = nil
    local mock_world = {
        set_block = function(x, y, z, id, states)
            world_called_with = { x = x, y = y, z = z, id = id, states = states }
            return true
        end,
    }

    interceptor.register_command(mock_api, nil, mock_world)

    T.truthy(registered_scheme:find("block_set:", 1, true), "схема содержит block_set")
    T.truthy(registered_scheme:find("x=", 1, true), "схема содержит x")
    T.truthy(registered_scheme:find("y=", 1, true), "схема содержит y")
    T.truthy(registered_scheme:find("z=", 1, true), "схема содержит z")
    T.truthy(registered_scheme:find("id=", 1, true), "схема содержит id")

    -- Проверка строгих прав
    T.truthy(registered_perms.permissions, "permissions table")
    T.eq(registered_perms.permissions[1], "role_management")
    T.eq(registered_no_logged, false)

    -- Проверка исполнения команды
    local logged_lines = {}
    local old_sink = log_mod.sink
    log_mod.sink = function(line)
        table.insert(logged_lines, line)
    end

    local mock_client = { account = { identity = "admin", role = "master", is_logged = true } }
    registered_handler({ x = "12", y = "64", z = "-5", id = "3" }, mock_client)

    T.truthy(world_called_with ~= nil, "world.set_block вызван")
    T.eq(world_called_with.x, 12)
    T.eq(world_called_with.y, 64)
    T.eq(world_called_with.z, -5)
    T.eq(world_called_with.id, 3)

    local has_exec, has_res = false, false
    for _, l in ipairs(logged_lines) do
        if l:find("[command_exec_block_set]", 1, true) then has_exec = true end
        if l:find("[command_result_block_set]", 1, true) and l:find("result=true", 1, true) then has_res = true end
    end
    T.truthy(has_exec, "command_exec_block_set")
    T.truthy(has_res, "command_result_block_set result=true")





    log_mod.sink = old_sink
end)

T.test("block_interceptor: init_lifecycle подписывается на server:client_connected", function()
    local connected_handler
    -- Mock глобального events.on
    local old_events = _G.events
    _G.events = {
        on = function(evt, handler)
            if evt == "server:client_connected" then
                connected_handler = handler
            end
        end,
    }

    local logged_line = nil
    local old_sink = log_mod.sink
    log_mod.sink = function(line)
        logged_line = line
    end

    interceptor.init_lifecycle()
    T.truthy(connected_handler ~= nil, "обработчик server:client_connected зарегистрирован")

    connected_handler({ account = { identity = "player42" } })
    T.truthy(logged_line ~= nil, "событие подключения залогировано")
    T.truthy(logged_line:find("[server_client_connected]", 1, true), "тег server_client_connected")
    T.truthy(logged_line:find('client="player42"', 1, true), "identity player42")

    log_mod.sink = old_sink
    _G.events = old_events
end)
