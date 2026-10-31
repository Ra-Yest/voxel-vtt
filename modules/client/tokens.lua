-- client/tokens.lua
-- Слой: client
-- Спека: specs/client-tokens.md
-- Назначение: Клиентское состояние токенов: выбор, превью перемещения и отправка намерения на сервер.
-- Публичные функции:
--   select(token_id)
--   get_selected()
--   preview_move(token_id, target_cell)
--   confirm_move()
--   cancel_preview()

local channel = require("net/channel")

local M = {}

M.selected_token_id = nil
M.preview_target = nil

-- Выбор токена кликом
function M.select(token_id)
    M.selected_token_id = token_id
    M.preview_target = nil
end

-- Получение текущего выбранного токена
function M.get_selected()
    return M.selected_token_id
end

-- Установка целевой клетки для превью перемещения
function M.preview_move(token_id, target_cell)
    M.selected_token_id = token_id
    M.preview_target = target_cell
end

-- Подтверждение перемещения и отправка намерения на сервер
function M.confirm_move()
    if M.selected_token_id and M.preview_target then
        channel.send("MoveToken", {
            token_id = M.selected_token_id,
            target_cell = M.preview_target,
        })
        M.preview_target = nil
        return true
    end
    return false
end

-- Отмена предпросмотра перемещения
function M.cancel_preview()
    M.preview_target = nil
end

return M
