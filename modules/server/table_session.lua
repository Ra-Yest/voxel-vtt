-- server/table_session.lua
-- Слой: server
-- Спека: specs/server-table-session.md
-- Назначение: Управление жизненным циклом сессии, учёт игроков и ролей (GM / Player).
-- Публичные функции:
--   init()
--   on_player_join(player_id)
--   on_player_leave(player_id)
--   is_gm(player_id)
--   set_role(player_id, role)
--   get_state()

local log = require("core/log")
local channel = require("net/channel")

local M = {}

M.players = {}
M.state = {
    round = 1,
    active_map = "default",
}

-- Инициализация сессии стола
function M.init()
    M.players = {}
    channel.replicate("session_state", 1, M.state, true)
    log("session_init", { map = M.state.active_map })
end

-- Обработка входа игрока
function M.on_player_join(player_id)
    local is_first = next(M.players) == nil
    local role = is_first and "gm" or "player"
    M.players[player_id] = {
        id = player_id,
        role = role,
        joined_at = os.time(),
    }
    log("player_join", { player_id = player_id, role = role })
    channel.broadcast("player_joined", { player_id = player_id, role = role })
end

-- Обработка выхода игрока
function M.on_player_leave(player_id)
    M.players[player_id] = nil
    log("player_leave", { player_id = player_id })
    channel.broadcast("player_left", { player_id = player_id })
end

-- Проверка роли Мастера (GM)
function M.is_gm(player_id)
    local p = M.players[player_id]
    return p ~= nil and p.role == "gm"
end

-- Назначение роли игроку
function M.set_role(player_id, role)
    if M.players[player_id] then
        M.players[player_id].role = role
        log("role_changed", { player_id = player_id, role = role })
        channel.broadcast("role_changed", { player_id = player_id, role = role })
    end
end

-- Получение текущего состояния сессии
function M.get_state()
    return {
        players = M.players,
        state = M.state,
    }
end

return M
