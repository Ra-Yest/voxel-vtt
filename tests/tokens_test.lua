-- tests/tokens_test.lua
-- Тесты модуля server/tokens (спавн, поиск поверхности find_surface_y, entity_id, move с разным CELL_SIZE, despawn, отказ при ошибках)

local T = require("lib")
local mock = require("engine_mock")

mock.install(_G)

local tokens = require("server/tokens")
local grid = require("core/grid")
local block_interceptor = require("net/block_interceptor")

-- Состояние моков
local world_blocks = {}
local world_solid = {}
local world_replaceable = {}
local spawned_entities = {}
local despawned_uids = {}
local pos_updates = {}
local entity_seq = 1000

local function reset_mocks()
    mock.reset()
    tokens.registry = {}
    world_blocks = {}
    world_solid = {}
    world_replaceable = {}
    spawned_entities = {}
    despawned_uids = {}
    pos_updates = {}
    entity_seq = 1000

    -- Мок block.raycast
    mock.override("block.raycast", function(start, dir, max_distance)
        local sx, sy, sz = start[1], start[2], start[3]
        local bx = math.floor(sx)
        local bz = math.floor(sz)
        local key_col = bx .. "," .. bz
        local top_y = world_blocks[key_col]
        if top_y then
            return {
                block = 1,
                endpoint = { sx, top_y + 1.0, sz },
                iendpoint = { bx, top_y, bz },
                length = sy - top_y,
                normal = { 0, 1, 0 },
            }
        end
        return nil
    end)

    -- Мок block.is_solid_at
    mock.override("block.is_solid_at", function(x, y, z)
        local key = x .. "," .. y .. "," .. z
        if world_solid[key] ~= nil then
            return world_solid[key]
        end
        return true -- по умолчанию блоки твердые
    end)

    -- Мок block.is_replaceable_at
    mock.override("block.is_replaceable_at", function(x, y, z)
        local key = x .. "," .. y .. "," .. z
        if world_replaceable[key] ~= nil then
            return world_replaceable[key]
        end
        return false -- по умолчанию не заменяемые
    end)

    -- Мок entities.spawn
    mock.override("entities.spawn", function(name, pos)
        entity_seq = entity_seq + 1
        local uid = entity_seq
        local cur_pos = { pos[1], pos[2], pos[3] }

        local tsf = {
            set_pos = function(self, new_pos)
                cur_pos = { new_pos[1], new_pos[2], new_pos[3] }
                if spawned_entities[uid] then
                    spawned_entities[uid].pos = cur_pos
                end
                pos_updates[#pos_updates + 1] = { uid = uid, pos = cur_pos }
            end,
            get_pos = function(self)
                return cur_pos
            end,
        }

        local ent = {
            get_uid = function(self)
                return uid
            end,
            def_name = function(self)
                return name
            end,
            transform = tsf,
            get_component = function(self, cname)
                if cname == "transform" then return tsf end
                return nil
            end,
            despawn = function(self)
                despawned_uids[#despawned_uids + 1] = uid
                spawned_entities[uid] = nil
            end,
        }

        spawned_entities[uid] = { name = name, pos = cur_pos, entity = ent }
        return ent
    end)

    -- Мок entities.exists
    mock.override("entities.exists", function(uid)
        return spawned_entities[uid] ~= nil
    end)

    -- Мок entities.get
    mock.override("entities.get", function(uid)
        local data = spawned_entities[uid]
        if data then return data.entity end
        return nil
    end)

    -- Мок entities.get_all
    mock.override("entities.get_all", function()
        local res = {}
        for uid, data in pairs(spawned_entities) do
            res[uid] = data.entity
        end
        return res
    end)
end

-- 1. find_surface_y: базовый расчет на ровной твердой поверхности
T.test("tokens: find_surface_y на твердом основании возвращает y + 1.0", function()
    reset_mocks()
    local bx, bz = 5, 10
    world_blocks[bx .. "," .. bz] = 20
    world_solid[bx .. ",20," .. bz] = true
    world_replaceable[bx .. ",20," .. bz] = false

    local sy = tokens.find_surface_y(5.5, 10.5)
    T.eq(sy, 21.0, "токен должен стоять на блоке 20, т.е. Y = 21.0")
end)

-- 2. find_surface_y: пропуск сквозь траву и неполные блоки до твердого грунта
T.test("tokens: find_surface_y спускается сквозь проходимые/неполные блоки", function()
    reset_mocks()
    local bx, bz = 0, 0
    -- Верхний блок трава на Y=12, под ней цветы на Y=11, твердая земля на Y=10
    world_blocks[bx .. "," .. bz] = 12
    world_solid[bx .. ",12," .. bz] = false
    world_replaceable[bx .. ",12," .. bz] = true

    world_solid[bx .. ",11," .. bz] = false
    world_replaceable[bx .. ",11," .. bz] = true

    world_solid[bx .. ",10," .. bz] = true
    world_replaceable[bx .. ",10," .. bz] = false

    local sy = tokens.find_surface_y(0.5, 0.5)
    T.eq(sy, 11.0, "токен должен стоять на твердой земле Y=10, т.е. Y = 11.0")
end)

-- 3. find_surface_y: при отсутствии попадания луча возвращает cell_level or 0
T.test("tokens: find_surface_y при промахе возвращает cell_level или 0", function()
    reset_mocks()
    local sy_default = tokens.find_surface_y(100.5, 100.5)
    T.eq(sy_default, 0, "при промахе и без cell_level возврат 0")

    local sy_level = tokens.find_surface_y(100.5, 100.5, 5)
    T.eq(sy_level, 5, "при промахе возврат переданного cell_level")
end)

-- 4. spawn: создание с дефолтным def, сохранение entity_id и правильный расчет координат центра
T.test("tokens: spawn создает токен с def по умолчанию и сохраняет entity_id", function()
    reset_mocks()
    grid.CELL_SIZE = 3
    local cx, cz = 2, 4
    local wx, wz = grid.center_of(cx, cz) -- 2 * 3 + 1.5 = 7.5, 4 * 3 + 1.5 = 13.5
    world_blocks[math.floor(wx) .. "," .. math.floor(wz)] = 15

    local token_id = tokens.spawn({ cx = cx, cz = cz, level = 0 })
    T.truthy(token_id, "spawn должен вернуть token_id")

    local t = tokens.get(token_id)
    T.truthy(t, "токен должен присутствовать в реестре")
    T.eq(t.id, token_id, "id совпадает")
    T.eq(t.name, "Token", "дефолтное имя Token")
    T.eq(t.asset_id, "vtt:token", "дефолтный ассет vtt:token вместо base:token")
    T.eq(t.cell.cx, cx, "cell.cx сохранен")
    T.eq(t.cell.cz, cz, "cell.cz сохранен")
    T.truthy(t.entity_id, "entity_id из ent:get_uid() должен быть сохранен")
    T.eq(t.entity_id, 1001, "entity_id равен UID созданной сущности")

    -- Проверка позиции в spawned_entities
    local spawned = spawned_entities[t.entity_id]
    T.truthy(spawned, "сущность должна быть в spawned_entities")
    T.eq(spawned.name, "vtt:token", "asset_id vtt:token передан в entities.spawn")
    T.eq(spawned.pos[1], wx, "X координата центра клетки")
    T.eq(spawned.pos[2], 16.0, "Y координата над поверхностью 15 + 1.0 = 16.0")
    T.eq(spawned.pos[3], wz, "Z координата центра клетки")

    -- get_by_entity_id
    local found = tokens.get_by_entity_id(t.entity_id)
    T.truthy(found, "get_by_entity_id находит токен по UID")
    T.eq(found.id, token_id, "id найденного токена совпадает")

    -- get_all
    local all = tokens.get_all()
    T.truthy(all[token_id], "токен присутствует в get_all")
end)

-- 5. spawn: явные параметры id, asset_id, name, owner_id
T.test("tokens: spawn с кастомными def полями", function()
    reset_mocks()
    local cx, cz = 0, 0
    local custom_id = "warrior_1"
    local id = tokens.spawn({ cx = cx, cz = cz }, {
        id = custom_id,
        name = "Krag",
        asset_id = "vtt:warrior",
        owner_id = 42,
    })
    T.eq(id, custom_id, "spawn вернул заданный id")

    local t = tokens.get(custom_id)
    T.eq(t.name, "Krag", "имя Krag")
    T.eq(t.asset_id, "vtt:warrior", "ассет vtt:warrior")
    T.eq(t.owner_id, 42, "owner_id = 42")
end)

-- 6. move: перемещение на новую клетку с пересчетом высоты и проверкой Transform:set_pos
T.test("tokens: move перемещает сущность в центр target_cell с учетом рельефа", function()
    reset_mocks()
    grid.CELL_SIZE = 3
    local id = tokens.spawn({ cx = 0, cz = 0 }, { id = "hero" })

    -- Целевая клетка на холме с Y=30
    local target_cx, target_cz = 3, 5
    local twx, twz = grid.center_of(target_cx, target_cz)
    world_blocks[math.floor(twx) .. "," .. math.floor(twz)] = 30

    local ok = tokens.move(id, { cx = target_cx, cz = target_cz })
    T.truthy(ok, "move успешен")

    local t = tokens.get(id)
    T.eq(t.cell.cx, target_cx, "cell.cx обновлен")
    T.eq(t.cell.cz, target_cz, "cell.cz обновлен")

    -- Проверка вызова set_pos
    T.truthy(#pos_updates > 0, "должен быть зафиксирован вызов set_pos")
    local last_pos = pos_updates[#pos_updates].pos
    T.eq(last_pos[1], twx, "X совпадает с центром target_cell")
    T.eq(last_pos[2], 31.0, "Y пересчитан на холм 30 + 1.0 = 31.0")
    T.eq(last_pos[3], twz, "Z совпадает с центром target_cell")
end)

-- 7. move: зависимость от grid.CELL_SIZE (2x2 vs 3x3)
T.test("tokens: move динамически пересчитывает центр клетки при изменении grid.CELL_SIZE", function()
    reset_mocks()
    local id = tokens.spawn({ cx = 0, cz = 0 }, { id = "scale_token" })

    -- При CELL_SIZE = 2: центр клетки (2, 2) равен (2*2 + 1, 2*2 + 1) = (5, 5)
    grid.CELL_SIZE = 2
    tokens.move(id, { cx = 2, cz = 2 })
    local pos2 = pos_updates[#pos_updates].pos
    T.eq(pos2[1], 5.0, "CELL_SIZE=2: центр X = 5.0")
    T.eq(pos2[3], 5.0, "CELL_SIZE=2: центр Z = 5.0")

    -- При CELL_SIZE = 3: центр клетки (2, 2) равен (2*3 + 1.5, 2*3 + 1.5) = (7.5, 7.5)
    grid.CELL_SIZE = 3
    tokens.move(id, { cx = 2, cz = 2 })
    local pos3 = pos_updates[#pos_updates].pos
    T.eq(pos3[1], 7.5, "CELL_SIZE=3: центр X = 7.5")
    T.eq(pos3[3], 7.5, "CELL_SIZE=3: центр Z = 7.5")
end)

-- 8. move: отказ при неизвестном token_id
T.test("tokens: move возвращает ошибку при неизвестном token_id", function()
    reset_mocks()
    local ok, err = tokens.move("unknown_id", { cx = 1, cz = 1 })
    T.eq(ok, false, "move должен вернуть false")
    T.truthy(err, "должно быть сообщение об ошибке")
end)

-- 9. remove: удаление сущности через Entity:despawn и очистка реестра
T.test("tokens: remove вызывает Entity:despawn и удаляет из реестра", function()
    reset_mocks()
    local id = tokens.spawn({ cx = 1, cz = 1 }, { id = "to_delete" })
    local t = tokens.get(id)
    local uid = t.entity_id

    local ok = tokens.remove(id)
    T.truthy(ok, "remove успешен")
    T.eq(tokens.get(id), nil, "токен удален из реестра")

    T.truthy(#despawned_uids == 1, "Entity:despawn должен быть вызван 1 раз")
    T.eq(despawned_uids[1], uid, "despawn вызван для правильного entity UID")
end)

-- 10. remove: отказ при неизвестном token_id
T.test("tokens: remove возвращает ошибку при неизвестном token_id", function()
    reset_mocks()
    local ok, err = tokens.remove("ghost_token")
    T.eq(ok, false, "remove должен вернуть false")
    T.truthy(err, "должно быть сообщение об ошибке")
end)

-- 11. Регистрация синхронизации и консольных команд в net/block_interceptor
T.test("block_interceptor: регистрирует синхронизацию токена и 3 консольные команды", function()
    reset_mocks()
    local registered_sync = {}
    local registered_commands = {}

    local mock_api = {
        entities = {
            register = function(name, cfg)
                registered_sync[name] = cfg
            end,
            eval = {
                VectorNotEquals = function() return 0 end,
            },
        },
        console = {
            set_command = function(scheme, perms, handler, unauth)
                registered_commands[scheme] = {
                    perms = perms,
                    handler = handler,
                    unauth = unauth,
                }
            end,
        },
        interceptors = {
            send = {
                add_interceptor = function() end,
                add_generic_interceptor = function() end,
            },
        },
    }

    block_interceptor.register_token_sync(mock_api)
    T.truthy(registered_sync["vtt:token"], "vtt:token зарегистрирован в api.entities")
    T.truthy(registered_sync["vtt:token"].standard_fields.tsf_pos, "tsf_pos настроен в standard_fields")
    T.truthy(registered_sync["vtt:token"].custom_fields.pos, "pos настроен в custom_fields")
    T.eq(registered_sync["vtt:token"].custom_fields.pos.maximum_deviation, 0.01, "maximum_deviation = 0.01")
    T.truthy(type(registered_sync["vtt:token"].custom_fields.pos.provider) == "function", "provider является функцией")

    local commands = require("server/commands")
    commands.init(tokens)
    block_interceptor.register_token_commands(mock_api, commands, tokens)
    local has_spawn, has_move, has_remove, has_owner = false, false, false, false
    for scheme, _ in pairs(registered_commands) do
        if scheme:find("token_spawn") then has_spawn = true end
        if scheme:find("token_move") then has_move = true end
        if scheme:find("token_remove") then has_remove = true end
        if scheme:find("token_owner") then has_owner = true end
    end
    T.truthy(has_spawn, "команда token_spawn зарегистрирована")
    T.truthy(has_move, "команда token_move зарегистрирована")
    T.truthy(has_remove, "команда token_remove зарегистрирована")
    T.truthy(has_owner, "команда token_owner зарегистрирована")

    -- Тест исполнения команды token_spawn
    local spawn_cmd = nil
    for scheme, cmd in pairs(registered_commands) do
        if scheme:find("token_spawn") then spawn_cmd = cmd; break end
    end
    spawn_cmd.handler({ cx = "3", cz = "4", id = "cmd_token" }, { account = { identity = "gm_admin", role = "master" } })
    local t_cmd = tokens.get("cmd_token")
    T.truthy(t_cmd, "токен создан через чат-команду token_spawn")
    T.eq(t_cmd.cell.cx, 3, "cx = 3")
    T.eq(t_cmd.cell.cz, 4, "cz = 4")

    -- Тест custom_fields.pos.provider
    local provider_fn = registered_sync["vtt:token"].custom_fields.pos.provider
    local ppos = provider_fn(t_cmd.entity_id, "pos")
    T.truthy(ppos, "provider вернул позицию для активного токена")
    T.eq(ppos[1], 10.5, "pos.x соответствует клетке 3 при CELL_SIZE 3 (3 * 3 + 1.5 = 10.5)")
    T.eq(ppos[3], 13.5, "pos.z соответствует клетке 4 при CELL_SIZE 3 (4 * 3 + 1.5 = 13.5)")
    T.eq(provider_fn(999999, "pos"), nil, "provider возвращает nil для несуществующего uid")

    -- Тест исполнения команды token_move
    local move_cmd = nil
    for scheme, cmd in pairs(registered_commands) do
        if scheme:find("token_move") then move_cmd = cmd; break end
    end
    move_cmd.handler({ id = "cmd_token", cx = "10", cz = "20" }, { account = { identity = "gm_admin", role = "master" } })
    T.eq(t_cmd.cell.cx, 10, "cx перемещен на 10")
    T.eq(t_cmd.cell.cz, 20, "cz перемещен на 20")

    -- Тест исполнения команды token_remove
    local remove_cmd = nil
    for scheme, cmd in pairs(registered_commands) do
        if scheme:find("token_remove") then remove_cmd = cmd; break end
    end
    remove_cmd.handler({ id = "cmd_token" }, { account = { identity = "gm_admin", role = "master" } })
    T.eq(tokens.get("cmd_token"), nil, "токен удален через чат-команду token_remove")
end)

-- 12. Клиентский обработчик set_handler в net/block_interceptor
T.test("block_interceptor: register_token_client регистрирует set_handler и обновляет transform:set_pos", function()
    reset_mocks()
    local registered_client_handlers = {}

    local mock_client_api = {
        entities = {
            set_handler = function(triggers, handler)
                for _, name in ipairs(triggers) do
                    registered_client_handlers[name] = handler
                end
            end,
        },
    }

    block_interceptor.init_client(mock_client_api)
    local token_handler = registered_client_handlers["vtt:token"]
    T.truthy(token_handler, "обработчик vtt:token зарегистрирован в api.entities.set_handler")

    -- Создаем тестовую сущность токена
    local token_id = tokens.spawn({ cx = 1, cz = 1, level = 0 }, { id = "client_sync_token" })
    local t = tokens.get(token_id)
    T.truthy(t and t.entity_id, "токен создан с entity_id")

    -- Симулируем входящий пакет EntityUpdate от сервера с dirty.pos (дистанция 3 блока)
    local target_pos = { 4.5, 69.0, 49.5 }
    token_handler(t.entity_id, 1, { pos = target_pos })

    local cur_ent = spawned_entities[t.entity_id]
    T.truthy(cur_ent, "сущность найдена")
    T.eq(cur_ent.pos[1], 4.5, "X обновился на клиенте до 4.5 в обход client:controller")
    T.eq(cur_ent.pos[2], 69.0, "Y обновился на клиенте до 69.0")
    T.eq(cur_ent.pos[3], 49.5, "Z обновился на клиенте до 49.5")

    -- Вызов без поля pos не должен менять координаты
    token_handler(t.entity_id, 1, { other = 123 })
    T.eq(cur_ent.pos[1], 4.5, "X остался неизменным без dirty.pos")

    -- Вызов для несуществующего uid не падает
    token_handler(999999, 1, { pos = { 0, 0, 0 } })
end)

-- 13. Синхронизация custom_fields.token_id и маппинг client_tokens
T.test("block_interceptor: custom_fields.token_id и клиентский маппинг client_tokens", function()
    reset_mocks()
    local registered_entities = {}
    local registered_client_handlers = {}

    local mock_api = {
        entities = {
            register = function(name, cfg)
                registered_entities[name] = cfg
            end,
            set_handler = function(triggers, handler)
                for _, name in ipairs(triggers) do
                    registered_client_handlers[name] = handler
                end
            end,
            eval = {
                NotEquals = function() return 0 end,
                VectorNotEquals = function() return 0 end,
            },
        },
    }

    block_interceptor.register_token_sync(mock_api)
    local cfg = registered_entities["vtt:token"]
    T.truthy(cfg, "vtt:token зарегистрирован")
    T.truthy(cfg.custom_fields and cfg.custom_fields.token_id, "custom_fields.token_id присутствует")

    -- Создаем токен на сервере
    local token_id = tokens.spawn({ cx = 2, cz = 3, level = 0 }, { id = "token_mapped" })
    local t = tokens.get(token_id)

    -- Проверяем провайдер token_id
    local provider_val = cfg.custom_fields.token_id.provider(t.entity_id, "token_id")
    T.eq(provider_val, "token_mapped", "provider возвращает token.id по entity_id")

    -- Клиентская сторона
    block_interceptor.init_client(mock_api)
    local handler = registered_client_handlers["vtt:token"]

    -- Приходит пакет с dirty.token_id и dirty.pos
    handler(t.entity_id, 1, { token_id = "token_mapped", pos = { 7.5, 0.0, 10.5 } })

    local client_tok = block_interceptor.get_client_token(t.entity_id)
    T.truthy(client_tok, "токен сохранен в client_tokens")
    T.eq(client_tok.token_id, "token_mapped")
    T.eq(client_tok.cell.cx, 2)
    T.eq(client_tok.cell.cz, 3)

    -- Поиск токена по клетке
    local found, found_uid = block_interceptor.get_client_token_by_cell(2, 3)
    T.truthy(found ~= nil, "токен найден по клетке (2, 3)")
    T.eq(found_uid, t.entity_id)

    -- Поддержка передачи таблицы сущности в get_client_token
    local by_table = block_interceptor.get_client_token({ uid = t.entity_id })
    T.truthy(by_table ~= nil, "get_client_token работает с таблицей { uid = ... }")
end)

-- 14. Отправка и прием сетевого намерения MoveToken
T.test("block_interceptor: send_move_token и register_server_messages через Message", function()
    reset_mocks()
    package.loaded["net/channel"] = nil
    local sent_messages = {}
    local message_handlers = {}

    -- Mock Message API
    _G.Message = {
        new = function(pack, event, schema)
            local msg_obj = {
                pack = pack,
                event = event,
                schema = schema,
                send = function(self, data)
                    sent_messages[#sent_messages + 1] = { name = event, data = data }
                end,
                on = function(self, handler)
                    message_handlers[event] = handler
                end,
            }
            return msg_obj
        end,
    }

    local commands = require("server/commands")
    commands.init()

    -- Спавним токен для перемещения
    local token_id = tokens.spawn({ cx = 0, cz = 0, level = 0 }, { id = "network_token", owner_id = "GM_User" })

    -- Регистрируем обработку серверных сообщений
    block_interceptor.register_server_messages(commands, tokens)
    T.truthy(message_handlers["MoveToken"] ~= nil, "обработчик MoveToken зарегистрирован")

    -- Клиент отправляет MoveToken
    block_interceptor.send_move_token("network_token", { cx = 4, cz = 5, level = 0 })
    T.eq(#sent_messages, 1, "сообщение MoveToken отправлено")
    T.eq(sent_messages[1].name, "MoveToken")
    T.eq(sent_messages[1].data.payload.token_id, "network_token")
    T.eq(sent_messages[1].data.payload.target_cell.cx, 4)
    T.eq(sent_messages[1].data.payload.target_cell.cz, 5)

    -- Сервер принимает сообщение от клиента-Мастера
    local mock_client = {
        account = { identity = "GM_User", role = "master" },
    }
    local handler = message_handlers["MoveToken"]
    handler(mock_client, sent_messages[1].data)

    -- Проверяем, что токен на сервере переместился
    local moved_t = tokens.get("network_token")
    T.eq(moved_t.cell.cx, 4, "сервер переместил токен в cx = 4")
    T.eq(moved_t.cell.cz, 5, "сервер переместил токен в cz = 5")
end)

-- 15. tokens.set_owner и отказ при неизвестном токен_id
T.test("tokens: set_owner меняет владельца и отклоняет некорректные параметры", function()
    reset_mocks()
    local token_id = tokens.spawn({ cx = 0, cz = 0, level = 0 }, { id = "t_owner", owner_id = "alice" })
    local t = tokens.get(token_id)
    T.eq(t.owner_id, "alice")

    -- Смена на bob
    local ok1 = tokens.set_owner(token_id, "bob")
    T.eq(ok1, true)
    T.eq(t.owner_id, "bob")

    -- Снятие владельца (nil)
    local ok2 = tokens.set_owner(token_id, nil)
    T.eq(ok2, true)
    T.eq(t.owner_id, nil)

    -- Неизвестный токен
    local ok3, err3 = tokens.set_owner("non_existent", "alice")
    T.eq(ok3, false)
    T.truthy(tostring(err3):find("Токен не найден", 1, true))

    -- Некорректный владелец (пустая строка)
    local ok4, err4 = tokens.set_owner(token_id, "")
    T.eq(ok4, false)
    T.truthy(tostring(err4):find("Некорректный владелец", 1, true))
end)

-- 16. tokens.get не вызывает sync_from_world (мок-счётчик) и не ищет по entity_id / cell
T.test("tokens: tokens.get не вызывает sync_from_world и не угадывает токен", function()
    reset_mocks()
    local sync_calls = 0
    local orig_sync = tokens.sync_from_world
    tokens.sync_from_world = function()
        sync_calls = sync_calls + 1
        return orig_sync()
    end

    tokens.registry = {}
    local res = tokens.get("missing_token")
    T.eq(res, nil)
    T.eq(sync_calls, 0, "tokens.get не должен вызывать sync_from_world")

    -- Создаем токен с entity_id = 1001 и cell = (2, 2)
    local tid = tokens.spawn({ cx = 2, cz = 2, level = 0 }, { id = "token_strict" })
    local t = tokens.get(tid)
    local ent_id = t.entity_id

    -- Поиск по числовому entity_id или fallback_cell через tokens.get должен возвращать nil
    T.eq(tokens.get(ent_id), nil, "tokens.get не должен находить по числовому entity_id")
    T.eq(tokens.get("1001"), nil, "tokens.get не должен находить по строковому entity_id")
    T.eq(tokens.get(nil, { cx = 2, cz = 2 }), nil, "tokens.get не должен искать по fallback_cell")

    tokens.sync_from_world = orig_sync
end)

-- 17. block_interceptor: MoveToken без identity -> отказ sender_unknown без вызова dispatch
T.test("block_interceptor: MoveToken без identity -> нет вызова dispatch, auth_denied sender_unknown", function()
    reset_mocks()
    package.loaded["net/channel"] = nil
    local message_handlers = {}
    _G.Message = {
        new = function(pack, event, schema)
            return {
                send = function() end,
                on = function(self, handler) message_handlers[event] = handler end,
            }
        end,
    }

    local dispatch_called = false
    local mock_commands = {
        init = function() end,
        get = function() return true end,
        dispatch = function()
            dispatch_called = true
            return true
        end,
    }

    local log_mod = require("core/log")
    local auth_denied_reason = nil
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("auth_denied") and line:find("sender_unknown") then
            auth_denied_reason = "sender_unknown"
        end
        orig_sink(line)
    end

    block_interceptor.register_server_messages(mock_commands, tokens)
    local handler = message_handlers["MoveToken"]
    T.truthy(handler ~= nil, "handler MoveToken должен быть зарегистрирован")

    -- Клиент без account / identity
    local client_no_id = { player = { username = "anon" } }
    handler(client_no_id, { payload = { token_id = "t1", target_cell = { cx = 1, cz = 1, level = 0 } } })

    log_mod.sink = orig_sink

    T.eq(dispatch_called, false, "dispatch не должен вызываться для клиента без identity")
    T.eq(auth_denied_reason, "sender_unknown", "в логе должно быть зафиксировано auth_denied с reason sender_unknown")
end)

-- 18. block_interceptor: MoveToken с ролью master vs обычный игрок
T.test("block_interceptor: MoveToken с ролью master -> успех; с обычным игроком и чужим токеном -> отказ", function()
    reset_mocks()
    package.loaded["net/channel"] = nil
    local message_handlers = {}
    _G.Message = {
        new = function(pack, event, schema)
            return {
                send = function() end,
                on = function(self, handler) message_handlers[event] = handler end,
            }
        end,
    }

    local commands = require("server/commands")
    commands.init()

    -- Токен принадлежит alice
    local token_id = tokens.spawn({ cx = 0, cz = 0, level = 0 }, { id = "alice_token", owner_id = "alice" })

    block_interceptor.register_server_messages(commands, tokens)
    local handler = message_handlers["MoveToken"]
    T.truthy(handler ~= nil, "handler MoveToken должен быть зарегистрирован")

    -- 1. Игрок bob пытается двигать токен alice -> отказ, координаты не меняются
    local client_bob = {
        account = { identity = "bob", role = "player" },
    }
    handler(client_bob, { payload = { token_id = "alice_token", target_cell = { cx = 1, cz = 1, level = 0 } } })
    T.eq(tokens.get("alice_token").cell.cx, 0)
    T.eq(tokens.get("alice_token").cell.cz, 0)

    -- 2. Мастер двигает токен alice на любую дистанцию -> успех
    local client_master = {
        account = { identity = "gm_admin", role = "master" },
    }
    handler(client_master, { payload = { token_id = "alice_token", target_cell = { cx = 10, cz = 10, level = 0 } } })
    T.eq(tokens.get("alice_token").cell.cx, 10)
    T.eq(tokens.get("alice_token").cell.cz, 10)
end)

-- 19. sync_from_world подтягивает существующие в мире vtt:token сущности при пустом registry
T.test("tokens: sync_from_world обнаруживает сущности в мире и восстанавливает registry", function()
    reset_mocks()
    -- Спавним сущность напрямую через entities.spawn
    local raw_ent = entities.spawn("vtt:token", { 4.5, 0, 7.5 })
    tokens.registry = {} -- реестр пуст (симуляция перезапуска сервера)

    -- Явный вызов sync_from_world восстанавливает сущности
    tokens.sync_from_world()
    local by_ent = tokens.get_by_entity_id(raw_ent:get_uid())
    T.truthy(by_ent ~= nil, "токен найден по entity_id после явного sync_from_world")
    T.eq(by_ent.entity_id, raw_ent:get_uid())
    T.eq(by_ent.cell.cx, 1)
    T.eq(by_ent.cell.cz, 2)
end)
