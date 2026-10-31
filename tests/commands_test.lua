local T = require("lib")
local commands = require("server/commands")
local log_mod = require("core/log")

local function make_mock_session(gm_id, tokens_mod)
    return {
        tokens_module = tokens_mod,
        is_gm = function(pid) return pid == gm_id end,
    }
end

T.test("commands: init регистрирует команды MVP-0", function()
    commands.init()
    T.truthy(commands.get("SpawnToken") ~= nil)
    T.truthy(commands.get("MoveToken") ~= nil)
    T.truthy(commands.get("RemoveToken") ~= nil)
    T.truthy(commands.get("SetTokenOwner") ~= nil)
    T.truthy(commands.get("Roll") ~= nil)
    T.truthy(commands.get("Chat") ~= nil)
end)

T.test("commands: dispatch валидирует схему и базовые права", function()
    local mock_session = {
        is_gm = function(pid) return pid == "gm_user" end,
    }

    -- 1. Успешный Roll от обычного игрока
    local ok1, res1 = commands.dispatch("Roll", "player2", { formula = "1d20+2" }, mock_session)
    T.eq(ok1, true)
    T.truthy(res1 ~= nil)

    -- 2. Ошибка схемы: SpawnToken без поля cell
    local ok2, err2 = commands.dispatch("SpawnToken", "gm_user", { asset_id = "goblin", name = "G1" }, mock_session)
    T.eq(ok2, false)
    T.truthy(tostring(err2):find("Отсутствует обязательное поле", 1, true))

    -- 3. Ошибка прав: игрок (не GM) пытается заспавнить токен
    local ok3, err3 = commands.dispatch("SpawnToken", "player2", {
        asset_id = "goblin",
        cell = { cx = 0, cz = 0, level = 0 },
        name = "G1",
    }, mock_session)
    T.eq(ok3, false)
    T.truthy(tostring(err3):find("Только Мастер", 1, true))
end)

T.test("commands: SpawnToken с owner='alice' сохраняет owner_id='alice'; без owner токен без владельца", function()
    local spawned_tokens = {}
    local mock_tokens = {
        spawn = function(cell, def)
            local id = "token_" .. tostring(#spawned_tokens + 1)
            spawned_tokens[id] = {
                id = id,
                cell = cell,
                name = def.name,
                owner_id = def.owner_id,
            }
            return id
        end,
        get = function(id) return spawned_tokens[id] end,
    }
    local session = make_mock_session("master", mock_tokens)

    -- 1. С owner = "alice"
    local ok1, res1 = commands.dispatch("SpawnToken", "master", {
        asset_id = "vtt:token",
        cell = { cx = 1, cz = 1, level = 0 },
        name = "AliceToken",
        owner = "alice",
    }, session)
    T.eq(ok1, true)
    local t1 = spawned_tokens[res1.token_id]
    T.truthy(t1 ~= nil)
    T.eq(t1.owner_id, "alice")

    -- 2. Без owner
    local ok2, res2 = commands.dispatch("SpawnToken", "master", {
        asset_id = "vtt:token",
        cell = { cx = 2, cz = 2, level = 0 },
        name = "NeutralToken",
    }, session)
    T.eq(ok2, true)
    local t2 = spawned_tokens[res2.token_id]
    T.truthy(t2 ~= nil)
    T.eq(t2.owner_id, nil)
end)

T.test("commands: SetTokenOwner от мастера меняет владельца; от игрока -> отказ, владелец не меняется; неизвестный token_id -> отказ", function()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice" },
    }
    local mock_tokens = {
        get = function(id) return registry[id] end,
        set_owner = function(id, owner)
            if not registry[id] then return false, "Токен не найден" end
            registry[id].owner_id = owner
            return true
        end,
    }
    local session = make_mock_session("master", mock_tokens)

    -- 1. Игрок пытается изменить владельца -> отказ, владелец не меняется
    local ok_player, err_p = commands.dispatch("SetTokenOwner", "bob", {
        token_id = "t1",
        owner = "bob",
    }, session)
    T.eq(ok_player, false)
    T.eq(registry["t1"].owner_id, "alice")
    T.truthy(tostring(err_p):find("Только Мастер может менять владельца", 1, true))

    -- 2. Мастер меняет владельца для неизвестного token_id -> отказ
    local ok_unknown, err_u = commands.dispatch("SetTokenOwner", "master", {
        token_id = "ghost",
        owner = "bob",
    }, session)
    T.eq(ok_unknown, false)
    T.truthy(tostring(err_u):find("Токен не найден", 1, true))

    -- 3. Мастер успешно меняет владельца на bob
    local ok_master, res_m = commands.dispatch("SetTokenOwner", "master", {
        token_id = "t1",
        owner = "bob",
    }, session)
    T.eq(ok_master, true)
    T.eq(registry["t1"].owner_id, "bob")

    -- 4. Мастер снимает владельца (owner = nil)
    local ok_clear, res_c = commands.dispatch("SetTokenOwner", "master", {
        token_id = "t1",
    }, session)
    T.eq(ok_clear, true)
    T.eq(registry["t1"].owner_id, nil)
end)

T.test("commands: После смены владельца прежний владелец получает отказ на ход, новый проходит", function()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "alice" },
    }
    local mock_tokens = {
        get = function(id) return registry[id] end,
        set_owner = function(id, owner)
            if not registry[id] then return false, "Токен не найден" end
            registry[id].owner_id = owner
            return true
        end,
        move = function(id, target_cell)
            if not registry[id] then return false, "Токен не найден" end
            registry[id].cell = { cx = target_cell.cx, cz = target_cell.cz, level = target_cell.level or 0 }
            return true
        end,
    }
    local session = make_mock_session("master", mock_tokens)

    -- Alice может ходить
    local ok1 = commands.dispatch("MoveToken", "alice", {
        token_id = "t1",
        target_cell = { cx = 1, cz = 1, level = 0 },
    }, session)
    T.eq(ok1, true)
    T.eq(registry["t1"].cell.cx, 1)

    -- Мастер передает токен Bob'у
    local ok_set = commands.dispatch("SetTokenOwner", "master", {
        token_id = "t1",
        owner = "bob",
    }, session)
    T.eq(ok_set, true)

    -- Прежний владелец Alice получает отказ
    local ok_alice, err_alice = commands.dispatch("MoveToken", "alice", {
        token_id = "t1",
        target_cell = { cx = 2, cz = 2, level = 0 },
    }, session)
    T.eq(ok_alice, false)
    T.truthy(tostring(err_alice):find("Нет прав на управление данным токеном", 1, true))

    -- Новый владелец Bob успешно ходит
    local ok_bob = commands.dispatch("MoveToken", "bob", {
        token_id = "t1",
        target_cell = { cx = 2, cz = 2, level = 0 },
    }, session)
    T.eq(ok_bob, true)
    T.eq(registry["t1"].cell.cx, 2)
end)

T.test("commands: dispatch('MoveToken') с неизвестным token_id -> false, auth_denied, токены не двигались", function()
    local moved = false
    local mock_tokens = {
        get = function(id) return nil end,
        move = function() moved = true; return true end,
    }
    local session = make_mock_session("master", mock_tokens)

    local ok, err = commands.dispatch("MoveToken", "alice", {
        token_id = "unknown_xyz",
        target_cell = { cx = 1, cz = 1, level = 0 },
    }, session)
    T.eq(ok, false)
    T.truthy(tostring(err):find("Токен не найден", 1, true))
    T.eq(moved, false)
end)

T.test("commands: Подложенный payload.token для чужого токена -> отказ", function()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, owner_id = "bob" },
    }
    local mock_tokens = {
        get = function(id) return registry[id] end,
        move = function(id, target_cell) return true end,
    }
    local session = make_mock_session("master", mock_tokens)

    -- Атакующий подкладывает payload.token со своим owner_id = "eve"
    local ok, err = commands.dispatch("MoveToken", "eve", {
        token_id = "t1",
        target_cell = { cx = 1, cz = 1, level = 0 },
        token = { id = "t1", owner_id = "eve", cell = { cx = 0, cz = 0, level = 0 } },
    }, session)
    T.eq(ok, false)
    T.truthy(tostring(err):find("Нет прав на управление данным токеном", 1, true))
end)

T.test("commands: Числовой entity_id вместо token_id -> отказ", function()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 0, cz = 0, level = 0 }, entity_id = 1005, owner_id = "alice" },
    }
    local mock_tokens = {
        get = function(id) return registry[id] end,
        move = function() return true end,
    }
    local session = make_mock_session("master", mock_tokens)

    -- Попытка передать строковый или числовой entity_id "1005" вместо token_id
    local ok, err = commands.dispatch("MoveToken", "alice", {
        token_id = "1005",
        target_cell = { cx = 1, cz = 1, level = 0 },
    }, session)
    T.eq(ok, false)
    T.truthy(tostring(err):find("Токен не найден", 1, true))
end)

T.test("commands: from_cell другой клетки -> ход применяется к токену из token_id, в логе from_cell_mismatch", function()
    local registry = {
        ["t1"] = { id = "t1", cell = { cx = 5, cz = 5, level = 0 }, owner_id = "alice" },
    }
    local moved_cell = nil
    local mock_tokens = {
        get = function(id) return registry[id] end,
        move = function(id, target_cell)
            moved_cell = target_cell
            registry[id].cell = { cx = target_cell.cx, cz = target_cell.cz, level = target_cell.level or 0 }
            return true
        end,
    }
    local session = make_mock_session("master", mock_tokens)

    local logged_mismatch = false
    local orig_sink = log_mod.sink
    log_mod.sink = function(line)
        if line:find("from_cell_mismatch") then
            logged_mismatch = true
        end
        orig_sink(line)
    end

    local ok, err = commands.dispatch("MoveToken", "alice", {
        token_id = "t1",
        target_cell = { cx = 6, cz = 5, level = 0 },
        from_cell = { cx = 99, cz = 99, level = 0 }, -- не совпадает с реальной клеткой t1 (5, 5)
    }, session)

    log_mod.sink = orig_sink

    T.eq(ok, true)
    T.eq(logged_mismatch, true, "должно быть залогировано from_cell_mismatch")
    T.eq(registry["t1"].cell.cx, 6)
    T.eq(registry["t1"].cell.cz, 5)
end)
