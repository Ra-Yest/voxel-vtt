-- tests/block_guard_test.lua
-- Тесты модуля net/block_guard (серверная защита мира от не-Мастеров с откатом блоков)

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

    local told_packets = {}
    local api = {
        protocol = {
            ServerMsg = {
                BlockChanged = 28,
            },
            tell = function(client, packet_type, data)
                table.insert(told_packets, { client = client, packet_type = packet_type, data = data })
            end,
        },
        interceptors = {
            packets = {
                ClientMsg = packets,
                ServerMsg = {
                    BlockChanged = 28,
                },
            },
            receive = {
                add_interceptor = function(packet_id, handler)
                    registered[packet_id] = handler
                end,
            },
        },
    }
    return api, registered, told_packets
end

local function make_mock_opts(overrides)
    local opts = {
        read_block = function(x, y, z)
            return 1, 0 -- default stone, state 0
        end,
    }
    if overrides then
        for k, v in pairs(overrides) do
            opts[k] = v
        end
    end
    return opts
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
            is_logged = true,
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
        { name = "member", client = { account = { identity = "p_member", role = "member", is_logged = true } } },
        { name = "empty_role", client = { account = { identity = "p_empty", role = "", is_logged = true } } },
        { name = "nil_role", client = { account = { identity = "p_nil", role = nil, is_logged = true } } },
        { name = "no_identity", client = { account = { identity = "", role = "master", is_logged = true } } },
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
            is_logged = true,
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
    local res = handler({ account = { identity = "gm", role = "master", is_logged = true } }, {}, {})

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

-- =========================================================================
-- Новые тесты для спеки net-block-revert (Шаг 0, откат блоков, коррекции)
-- =========================================================================

T.test("block_guard: BlockUpdate от member с позицией (10, 64, -5) вызывает tell с реальными id и state из мока, pid = -1", function()
    local api, registered, told_packets = make_mock_api()
    local opts = make_mock_opts({
        read_block = function(x, y, z)
            if x == 10 and y == 64 and z == -5 then
                return 42, 3
            end
            return 0, 0
        end,
    })
    local ok = block_guard.init(api, opts)
    T.eq(ok, true)

    local client_member = {
        account = { identity = "alice", role = "member", is_logged = true },
    }
    local pkt = {
        block = {
            pos = { x = 10, y = 64, z = -5 },
            id = 99,
            state = 1,
        },
    }

    local handler = registered[101] -- BlockUpdate
    local res = handler(client_member, pkt, {})
    T.eq(res, false)

    T.eq(#told_packets, 1, "protocol.tell должен быть вызван ровно 1 раз")
    local call = told_packets[1]
    T.eq(call.client, client_member)
    T.eq(call.packet_type, 28, "packet_type должен быть ServerMsg.BlockChanged (28)")
    T.eq(call.data.pid, -1, "pid должен быть -1")
    T.eq(call.data.block.id, 42, "id должен совпадать с моком")
    T.eq(call.data.block.state, 3, "state должен совпадать с моком")
    T.eq(call.data.block.pos.x, 10)
    T.eq(call.data.block.pos.y, 64)
    T.eq(call.data.block.pos.z, -5)
end)

T.test("block_guard: BlockDestroy и BlockInteract от member вызывают коррекцию с реальным блоком", function()
    local api, registered, told_packets = make_mock_api()
    local opts = make_mock_opts({
        read_block = function(x, y, z)
            return 12, 1
        end,
    })
    block_guard.init(api, opts)

    local client_member = {
        account = { identity = "bob", role = "member", is_logged = true },
    }

    -- BlockDestroy (id = 102)
    local pkt_destroy = { pos = { x = 1, y = 10, z = 2 } }
    local res1 = registered[102](client_member, pkt_destroy, {})
    T.eq(res1, false)
    T.eq(#told_packets, 1)
    T.eq(told_packets[1].data.block.id, 12)
    T.eq(told_packets[1].data.block.pos.x, 1)

    -- BlockInteract (id = 103)
    local pkt_interact = { pos = { x = 5, y = 20, z = 8 } }
    local res2 = registered[103](client_member, pkt_interact, {})
    T.eq(res2, false)
    T.eq(#told_packets, 2)
    T.eq(told_packets[2].data.block.id, 12)
    T.eq(told_packets[2].data.block.pos.x, 5)
end)

T.test("block_guard: BlockRegion* переводит относительную позицию через region_pos в абсолютную", function()
    local api, registered, told_packets = make_mock_api()
    local queried_coords = {}
    local opts = make_mock_opts({
        read_block = function(x, y, z)
            table.insert(queried_coords, { x = x, y = y, z = z })
            return 5, 0
        end,
    })
    block_guard.init(api, opts)

    local client_with_region = {
        account = { identity = "charlie", role = "member", is_logged = true },
        player = {
            region_pos = { x = 2, y = 0, z = -1 },
        },
    }

    -- BlockRegionUpdate (104): rel_x = 5, y = 64, rel_z = 10 -> abs_x = 2*64+5 = 133, abs_z = -1*64+10 = -54
    local pkt_reg_update = {
        block = {
            pos = { x = 5, y = 64, z = 10 },
            id = 2,
            state = 0,
        },
    }
    local res = registered[104](client_with_region, pkt_reg_update, {})
    T.eq(res, false)
    T.eq(#told_packets, 1)
    T.eq(told_packets[1].data.block.pos.x, 133)
    T.eq(told_packets[1].data.block.pos.y, 64)
    T.eq(told_packets[1].data.block.pos.z, -54)
    T.eq(queried_coords[1].x, 133)
    T.eq(queried_coords[1].z, -54)

    -- BlockRegionDestroy (105): rel_x = -3, y = 15, rel_z = 0 -> abs_x = 125, abs_z = -64
    local pkt_reg_destroy = { pos = { x = -3, y = 15, z = 0 } }
    registered[105](client_with_region, pkt_reg_destroy, {})
    T.eq(#told_packets, 2)
    T.eq(told_packets[2].data.block.pos.x, 125)
    T.eq(told_packets[2].data.block.pos.y, 15)
    T.eq(told_packets[2].data.block.pos.z, -64)
end)

T.test("block_guard: Мастер не вызывает tell (коррекция не отправляется)", function()
    local api, registered, told_packets = make_mock_api()
    local opts = make_mock_opts()
    block_guard.init(api, opts)

    local client_gm = {
        account = { identity = "master_bob", role = "master", is_logged = true },
    }
    local pkt = { block = { pos = { x = 10, y = 64, z = -5 } } }
    local res = registered[101](client_gm, pkt, {})
    T.eq(res, true)
    T.eq(#told_packets, 0, "для Мастера tell вызываться не должен")
end)

T.test("block_guard: y = 300 или read_block вернул nil: tell не вызывается, пакет отклонён, лог block_guard_correction_skipped", function()
    local api, registered, told_packets = make_mock_api()
    local opts = make_mock_opts({
        read_block = function(x, y, z)
            if x == 999 then return nil end -- симуляция незагруженного блока
            return 1, 0
        end,
    })
    block_guard.init(api, opts)

    local logged_skipped = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[block_guard_correction_skipped]", 1, true) then
            table.insert(logged_skipped, line)
        end
    end

    local client = { account = { identity = "user", role = "member", is_logged = true } }

    -- y = 300 (вне 0..255)
    local pkt_bad_y = { block = { pos = { x = 0, y = 300, z = 0 } } }
    local res1 = registered[101](client, pkt_bad_y, {})
    T.eq(res1, false)
    T.eq(#told_packets, 0)
    T.truthy(#logged_skipped >= 1)

    -- read_block вернул nil
    local pkt_nil_block = { block = { pos = { x = 999, y = 64, z = 0 } } }
    local res2 = registered[101](client, pkt_nil_block, {})
    T.eq(res2, false)
    T.eq(#told_packets, 0)
    T.truthy(#logged_skipped >= 2)

    log_mod.sink = orig_sink
end)

T.test("block_guard: tell бросает ошибку: перехватчик возвращает false, лог block_guard_error", function()
    local api, registered = make_mock_api()
    api.protocol.tell = function()
        error("network socket error in tell")
    end
    local opts = make_mock_opts()
    block_guard.init(api, opts)

    local logged_errors = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[block_guard_error]", 1, true) then
            table.insert(logged_errors, line)
        end
    end

    local client = { account = { identity = "user", role = "member", is_logged = true } }
    local pkt = { block = { pos = { x = 10, y = 64, z = 0 } } }
    local res = registered[101](client, pkt, {})

    log_mod.sink = orig_sink

    T.eq(res, false, "даже при ошибке tell перехватчик должен вернуть false")
    T.truthy(#logged_errors >= 1)
    T.truthy(logged_errors[1]:find("network socket error in tell", 1, true))
end)

T.test("block_guard: add_interceptor бросает ошибку для одного пакета: остальные регистрируются, init возвращает false, missing", function()
    local api, registered = make_mock_api()
    local orig_add = api.interceptors.receive.add_interceptor
    api.interceptors.receive.add_interceptor = function(packet_id, handler)
        if packet_id == 102 then -- BlockDestroy
            error("simulated registration crash")
        end
        orig_add(packet_id, handler)
    end

    local logged_errors = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[block_guard_error]", 1, true) then
            table.insert(logged_errors, line)
        end
    end

    local ok, missing = block_guard.init(api)
    log_mod.sink = orig_sink

    T.eq(ok, false)
    T.truthy(type(missing) == "table")
    T.eq(#missing, 1)
    T.eq(missing[1], "BlockDestroy")
    T.truthy(#logged_errors >= 1, "ошибка add_interceptor должна логироваться в block_guard_error")

    -- Остальные 7 пакетов зарегистрированы
    local count = 0
    for _ in pairs(registered) do count = count + 1 end
    T.eq(count, 7)
    T.truthy(registered[101] ~= nil)
end)

T.test("block_guard: init(api) без opts или без protocol: защита активна, лог block_guard_correction_unavailable", function()
    local api, registered = make_mock_api()
    -- Удаляем protocol
    api.protocol = nil

    local logged_unavailable = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[block_guard_correction_unavailable]", 1, true) then
            table.insert(logged_unavailable, line)
        end
    end

    local ok = block_guard.init(api)
    log_mod.sink = orig_sink

    T.eq(ok, true, "init должен вернуть true, так как перехватчики зарегистрированы")
    T.truthy(#logged_unavailable >= 1, "должен быть лог block_guard_correction_unavailable")

    -- Проверяем, что защита активна
    local client = { account = { identity = "user", role = "member", is_logged = true } }
    local res = registered[101](client, { block = { pos = { x = 0, y = 0, z = 0 } } }, {})
    T.eq(res, false, "отказ в правах работает даже без коррекции")
end)

T.test("block_guard: 30 отказов подряд: 30 вызовов tell, 2 записи auth_denied", function()
    local api, registered, told_packets = make_mock_api()
    local opts = make_mock_opts()
    block_guard.init(api, opts)

    local logged_auth_denied = {}
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("[auth_denied]", 1, true) and line:find("user_30_test", 1, true) then
            table.insert(logged_auth_denied, line)
        end
    end

    local client = { account = { identity = "user_30_test", role = "member", is_logged = true } }
    local pkt = { block = { pos = { x = 1, y = 2, z = 3 } } }

    for i = 1, 30 do
        registered[101](client, pkt, {})
    end

    log_mod.sink = orig_sink

    T.eq(#told_packets, 30, "tell должен быть вызван на каждый отказ ровно 30 раз")
    T.eq(#logged_auth_denied, 2, "auth_denied должен логироваться только на 1-й и 20-й вызов")
end)

T.test("block_guard: EntitySpawnAttempt и EntityInteract коррекции не требуют", function()
    local api, registered, told_packets = make_mock_api()
    local opts = make_mock_opts()
    block_guard.init(api, opts)

    local client = { account = { identity = "user_ent", role = "member", is_logged = true } }

    -- EntitySpawnAttempt (107)
    local res1 = registered[107](client, {}, {})
    T.eq(res1, false)

    -- EntityInteract (108)
    local res2 = registered[108](client, {}, {})
    T.eq(res2, false)

    T.eq(#told_packets, 0, "для сущностей tell вызываться не должен")
end)
