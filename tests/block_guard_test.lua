-- tests/block_guard_test.lua
-- Тесты модуля net/block_guard (серверная защита мира от не-Мастеров)

local T = require("lib")
local log_mod = require("core/log")
local identity = require("net/identity")
local block_guard = require("net/block_guard")

local function make_mock_api(override_packets)
    local registered = {} -- [packet_id] = handler
    local default_packets = {
        BlockUpdate = 101,
        BlockDestroy = 102,
        BlockInteract = 103,
        BlockRegionUpdate = 104,
        BlockRegionDestroy = 105,
        BlockRegionInteract = 106,
        EntitySpawnAttempt = 107,
        EntityInteract = 108,
        ChatMessage = 109,
        PlayerPosition = 110,
    }
    local packets = override_packets or default_packets

    local api = {
        interceptors = {
            packets = {
                ClientMsg = packets,
            },
            receive = {
                add_interceptor = function(packet_id, handler)
                    registered[packet_id] = handler
                end,
            },
        },
    }
    return api, registered
end

T.test("block_guard: init(api) регистрирует ровно 8 пакетов с числовыми ID из ClientMsg", function()
    local api, registered = make_mock_api()
    local ok, missing = block_guard.init(api)
    T.eq(ok, true)
    T.eq(missing, nil)

    -- Ровно 8 перехватчиков
    local count = 0
    for _ in pairs(registered) do
        count = count + 1
    end
    T.eq(count, 8)

    -- Проверяем, что зарегистрированы именно 101-108, а 109, 110 нет
    for id = 101, 108 do
        T.truthy(type(registered[id]) == "function")
    end
    T.eq(registered[109], nil)
    T.eq(registered[110], nil)
end)

T.test("block_guard: мастер получает true для всех 8 перехватчиков", function()
    local api, registered = make_mock_api()
    block_guard.init(api)

    local client_gm = {
        account = {
            identity = "master_bob",
            role = "master",
        },
    }

    for id = 101, 108 do
        local handler = registered[id]
        local res = handler(client_gm, {}, {})
        T.eq(res, true)
    end
end)

T.test("block_guard: не-мастера (member, пустая роль, nil роль, без identity, nil клиент) получают false", function()
    local api, registered = make_mock_api()
    block_guard.init(api)

    local clients_denied = {
        { name = "member", client = { account = { identity = "p_member", role = "member" } } },
        { name = "empty_role", client = { account = { identity = "p_empty", role = "" } } },
        { name = "nil_role", client = { account = { identity = "p_nil", role = nil } } },
        { name = "no_identity", client = { account = { identity = "", role = "master" } } },
        { name = "nil_client", client = nil },
    }

    for _, entry in ipairs(clients_denied) do
        for id = 101, 108 do
            local handler = registered[id]
            local res = handler(entry.client, {}, {})
            T.eq(res, false, "клиент " .. entry.name .. " должен получить false для id=" .. id)
        end
    end
end)

T.test("block_guard: логирование отказов и троттлинг (1-й и 20-й из 30 вызовов)", function()
    local api, registered = make_mock_api()
    block_guard.init(api)

    local logged_denials = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[auth_denied]", 1, true) and line:find("throttle_test_user", 1, true) then
            table.insert(logged_denials, line)
        end
    end

    local client = {
        account = {
            identity = "throttle_test_user",
            role = "member",
        },
    }

    -- Пакет BlockDestroy (id = 102)
    local handler = registered[102]
    T.truthy(handler ~= nil)

    for i = 1, 30 do
        local res = handler(client, {}, {})
        T.eq(res, false)
    end

    log_mod.sink = orig_sink

    -- Должно быть ровно 2 лога: count=1 и count=20
    T.eq(#logged_denials, 2)
    T.truthy(logged_denials[1]:find('count=1') or logged_denials[1]:find('count = 1'))
    T.truthy(logged_denials[1]:find('name="BlockDestroy"') or logged_denials[1]:find('name = "BlockDestroy"'))
    T.truthy(logged_denials[1]:find('reason="Только Мастер может менять мир"') or logged_denials[1]:find('reason = "Только Мастер может менять мир"'))

    T.truthy(logged_denials[2]:find('count=20') or logged_denials[2]:find('count = 20'))
end)

T.test("block_guard: отсутствие пакета в ClientMsg (нет BlockDestroy)", function()
    local packets = {
        BlockUpdate = 101,
        -- BlockDestroy отсутствует
        BlockInteract = 103,
        BlockRegionUpdate = 104,
        BlockRegionDestroy = 105,
        BlockRegionInteract = 106,
        EntitySpawnAttempt = 107,
        EntityInteract = 108,
    }
    local api, registered = make_mock_api(packets)

    local logged = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[block_guard_packet_missing]", 1, true) or line:find("[block_guard_unprotected]", 1, true) then
            table.insert(logged, line)
        end
    end

    local ok, missing = block_guard.init(api)
    log_mod.sink = orig_sink

    T.eq(ok, false)
    T.truthy(type(missing) == "table")
    T.eq(#missing, 1)
    T.eq(missing[1], "BlockDestroy")

    -- Остальные 7 должны быть зарегистрированы
    local count = 0
    for _ in pairs(registered) do
        count = count + 1
    end
    T.eq(count, 7)
    T.eq(registered[102], nil)
    T.truthy(registered[101] ~= nil)

    -- В логе есть и packet_missing, и unprotected
    local has_missing_log = false
    local has_unprotected_log = false
    for _, l in ipairs(logged) do
        if l:find("[block_guard_packet_missing]", 1, true) and l:find("BlockDestroy", 1, true) then
            has_missing_log = true
        end
        if l:find("[block_guard_unprotected]", 1, true) and l:find("BlockDestroy", 1, true) then
            has_unprotected_log = true
        end
    end
    T.truthy(has_missing_log)
    T.truthy(has_unprotected_log)
end)

T.test("block_guard: init(nil), init({}), init({interceptors = {}}) не падают, возвращают false, логируют unprotected", function()
    local cases = {
        { label = "nil", api = nil },
        { label = "empty", api = {} },
        { label = "interceptors_empty", api = { interceptors = {} } },
        { label = "no_receive", api = { interceptors = { packets = { ClientMsg = {} } } } },
        { label = "no_client_msg", api = { interceptors = { receive = { add_interceptor = function() end } } } },
    }

    for _, c in ipairs(cases) do
        local logged = {}
        local orig_sink = log_mod.sink
        log_mod.sink = function(line)
            if line:find("[block_guard_unprotected]", 1, true) then
                table.insert(logged, line)
            end
        end

        local ok, err = block_guard.init(c.api)
        log_mod.sink = orig_sink

        T.eq(ok, false, "init(" .. c.label .. ") должен вернуть false")
        T.truthy(#logged >= 1, "init(" .. c.label .. ") должен записать block_guard_unprotected")
    end
end)

T.test("block_guard: ошибка внутри обработчика (identity.sender_of сбоит) перехватывается, возвращает false и пишет block_guard_error", function()
    local api, registered = make_mock_api()
    block_guard.init(api)

    local logged_errors = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[block_guard_error]", 1, true) then
            table.insert(logged_errors, line)
        end
    end

    local orig_sender_of = identity.sender_of
    identity.sender_of = function()
        error("simulated identity failure")
    end

    local handler = registered[101]
    local res = handler({ account = { identity = "gm", role = "master" } }, {}, {})

    identity.sender_of = orig_sender_of
    log_mod.sink = orig_sink

    T.eq(res, false)
    T.eq(#logged_errors, 1)
    T.truthy(logged_errors[1]:find("simulated identity failure", 1, true))
    T.truthy(logged_errors[1]:find("BlockUpdate", 1, true))
end)

T.test("block_guard: статическая проверка исходного кода (нет server/* и client.account)", function()
    local f = io.open("vtt/modules/net/block_guard.lua", "r")
    T.truthy(f ~= nil, "файл vtt/modules/net/block_guard.lua должен существовать")
    local content = f:read("*a")
    f:close()

    T.truthy(not content:find('require%s*%(%s*["\']server/'), 'в net/block_guard.lua не должно быть require("server/...")')
    T.truthy(not content:find('client%.account'), 'в net/block_guard.lua не должно быть прямого чтения client.account')
    T.truthy(not content:find('["\']master["\']'), 'в net/block_guard.lua не должно быть строковой роли "master"')
end)
