# Спека: server/move-validation (серверная проверка хода и владельца токена)

**Файлы (закрытый список, правило 11 ослаблено только для этой задачи):**
- `vtt/modules/net/identity.lua` (новый, единственное место, где читается `client.account`)
- `vtt/modules/core/gm_rules.lua` (правила)
- `vtt/modules/server/commands.lua` (только `check` и `handler` у `SpawnToken`, `MoveToken`, `RemoveToken`, новая команда `SetTokenOwner`)
- `vtt/modules/server/tokens.lua` (только `get`, `move`, `spawn`, новая `set_owner`)
- `vtt/modules/net/block_interceptor.lua` (только обработчик `MoveToken` в `register_server_messages`: получение отправителя через `net/identity`)
- `vtt/modules/core/schema.lua` (только схемы `SpawnToken` и новой `SetTokenOwner`)
- тесты: `tests/gm_rules_test.lua`, `tests/commands_test.lua`, `tests/tokens_test.lua`, новый `tests/identity_test.lua`

**Слой:** core + server + net
**Исполнитель:** сильная модель
**Риск:** красный (права и безопасность)

## Решения, на которые опирается спека

1. **Роль Мастера** берётся из `client.account.role` (значение `"master"`), которое задаёт конфиг Neutron. Роль не хранится в нашем коде и не выводится из порядка входа.
2. **Пак не зависит от Neutron жёстко.** Все обращения к `client.account` и к `api.*` идут только через `net/identity.lua` и `net/channel.lua`. `core` и `server` работают с обычными таблицами (`identity` строка, `role` строка) и не знают о Neutron. Если API Neutron недоступен или поля нет, пак загружается, логирует предупреждение и отказывает в действиях, требующих идентичности. Падения при загрузке и в обработчиках быть не должно.
3. **Владелец токена назначается при спавне** (`SpawnToken.payload.owner`, строка `identity`, необязательное поле). Менять владельца можно командой `SetTokenOwner` (только Мастер). Интерфейса нет, это вне MVP-0. Токен без владельца двигает только Мастер.

## Проблемы, которые закрывает спека

1. Обработчик `MoveToken` ставит `is_gm = true` всем и подставляет `sender_id = 1`.
2. `MoveToken.check` берёт токен из `payload.token` или создаёт фиктивный `{owner_id = sender_id}`.
3. `can_move_token` пропускает токены без `owner_id` и не проверяет дальность.
4. `tokens.get` угадывает токен по `from_cell`, по числовому entity_id и по «единственному токену».
5. Владельца нельзя задать при спавне, поэтому игрок не может двигать свой токен.
6. Тесты проверяют только успех.

## Интерфейс

### net/identity.lua (новый)

- `M.init(api)`: сохраняет ссылку на api Neutron. Может вызываться без аргумента (тогда работает только в режиме «нет Neutron»).
- `M.sender_of(client) -> identity | nil, role | nil`:
  - если `client`, `client.account`, `client.account.identity` не заданы, возвращает `nil, nil`;
  - роль возвращается как строка из `client.account.role` или `nil`.
  - Никаких значений по умолчанию (`1`, `"player"`) не подставляет.
- Ссылки `-- docs:` на поля `account.identity` и `account.role` обязательны. Если в `docs/neutron/` их нет, строка добавляется в `UNVERIFIED.md` и функция возвращает `nil, nil` (строгий отказ).

### core/gm_rules.lua

- `M.DEFAULT_MOVE_STEPS = 5`.
- `can_move_token(token, target_cell, player_id, is_gm, max_steps) -> true | false, reason`, проверки по порядку, первая сработавшая даёт отказ:
  1. `token == nil` -> `"Токен не найден"`.
  2. `target_cell` без числовых `cx`, `cz` -> `"Некорректная целевая клетка"`.
  3. `(target_cell.level or 0) ~= (token.cell.level or 0)` -> `"Ход между уровнями запрещён"`.
  4. `target_cell` совпадает с `token.cell` -> `"Токен уже в этой клетке"`.
  5. `is_gm == true` -> разрешено (Мастер без ограничения дальности и владения).
  6. `player_id == nil` -> `"Игрок не определён"`.
  7. `token.owner_id == nil` или `token.owner_id ~= player_id` -> `"Нет прав на управление данным токеном"`.
  8. `grid.distance(token.cell, target_cell) > (max_steps or token.max_steps or DEFAULT_MOVE_STEPS)` -> `"Слишком далеко"`.
- `can_spawn_token(player_id, is_gm, owner)`: Мастер может всегда. Если `owner` задан, он должен быть непустой строкой, иначе `"Некорректный владелец"`.
- `can_set_token_owner(player_id, is_gm)`: только Мастер, иначе `"Только Мастер может менять владельца"`.
- `can_remove_token`: без изменений по логике, только Мастер.
- `core` вызовов движка не делает. `gm_rules` может требовать `core/grid`.

### server/tokens.lua

- `spawn(cell, def)`: `def.owner_id` (строка или `nil`) сохраняется в реестре. Логика `find_surface_y` и сущности не меняется.
- `set_owner(token_id, owner_id) -> true | false, reason`: меняет `owner_id` существующего токена (`owner_id` строка или `nil`, `nil` означает «только Мастер»).
- `get(token_id)`: возвращает `M.registry[token_id]` или `nil`. Убрать поиск по entity_id, по `fallback_cell`, по «единственному токену» и вызов `sync_from_world` изнутри `get`.
- `move(token_id, target_cell)`: параметр `from_cell` убрать. Остальное не менять.
- `get_by_entity_id`, `get_by_cell`, `sync_from_world` оставить, но из `get` и `move` не вызывать.

### server/commands.lua

- `SpawnToken`: `check` вызывает `gm_rules.can_spawn_token(sender_id, is_gm, payload.owner)`; `handler` передаёт `owner` в `tokens.spawn` как `owner_id`.
- `SetTokenOwner` (новая, регистрируется в реестре): `payload = { token_id, owner }` (`owner` строка или `nil` для снятия владельца). `check`: `can_set_token_owner`, плюс токен существует через `tokens.get`. `handler`: `tokens.set_owner`.
- `MoveToken.check`: `token = tokens.get(payload.token_id)`. Если `nil`, отказ `"Токен не найден"`. Затем `gm_rules.can_move_token(token, payload.target_cell, sender_id, is_gm)`. Если `from_cell` пришла и не совпадает с `token.cell`, `log("from_cell_mismatch", ...)`, решение не меняется.
- `MoveToken.handler`: `tokens.move(payload.token_id, payload.target_cell)`.
- `RemoveToken.check`: токен только через `tokens.get(payload.token_id)`, без `payload.token`.
- `dispatch` не менять. Все отказы логируются `auth_denied` с полем `reason`.

### core/schema.lua

- `SpawnToken` получает поле `owner` (`type = "string"`, необязательное).
- Новая схема `SetTokenOwner`: `token_id` (string, обязательно), `owner` (string, необязательно).
- `MoveToken.from_cell` остаётся необязательным полем.

### net/block_interceptor.lua (обработчик `MoveToken`)

- Отправитель получается через `identity.sender_of(client)`. Если `identity == nil`, `log("auth_denied", {name = "MoveToken", reason = "sender_unknown"})` и выход без `dispatch`.
- `session_ctx = { tokens_module = tokens_module, is_gm = function(id) return id == sender_id and role == "master" end }`. Константы `true` нет.
- `sender_id` передаётся в `dispatch` строкой `identity`. Значения `1` и `player.id` не используются.
- Никаких прямых вызовов `client.account` вне `net/identity.lua`.

## Правила и ограничения

- Новые API движка и Neutron не использовать. Нужны только поля из `docs/neutron/`, с комментарием `-- docs:`. Если поля в документации не найдены, записать в `UNVERIFIED.md` и остановиться на этом месте.
- Никаких молчаливых веток: любой отказ логируется `auth_denied` с `reason`.
- Нет fallback при поиске токена, даже если ход перестанет работать.
- `core` и `server` не `require` ни `net/identity`, ни Neutron-специфичных модулей. `server/commands` получает `identity` и `role` аргументами через `session_ctx`, а не читает их сам.
- Пак должен загружаться и проходить тесты без Neutron (тесты используют мок `identity`). Отсутствие Neutron не должно приводить к ошибке при загрузке.
- `table_session.lua` не подключать и не менять.
- Интерфейса выбора владельца нет. Только команда `SetTokenOwner` и параметр спавна.

## Критерий готовности

`tests/identity_test.lua`:
- `sender_of(nil)`, `sender_of({})`, `sender_of({account = {}})` -> `nil, nil`.
- Возврат `identity` и `role` из мок-клиента.
- Отсутствие `api` не приводит к ошибке.

`tests/gm_rules_test.lua`:
- Мастер двигает чужой токен и токен без владельца на любую дистанцию на том же уровне.
- Игрок двигает свой токен на расстояние `<= 5`; на 6 -> `"Слишком далеко"`.
- Игрок двигает чужой токен или токен без владельца -> отказ.
- `player_id == nil` у не-мастера -> отказ.
- Цель = текущая клетка, другой `level`, `token == nil`, цель без `cx` -> отказ.
- `max_steps` токена учитывается; аргумент `max_steps` его перекрывает.
- `can_spawn_token`: игрок без роли -> отказ; мастер с `owner = ""` -> отказ.
- `can_set_token_owner`: игрок -> отказ, мастер -> разрешено.

`tests/commands_test.lua` и `tests/tokens_test.lua`:
- `SpawnToken` с `owner = "alice"` сохраняет `owner_id = "alice"`; без `owner` токен без владельца.
- `SetTokenOwner` от мастера меняет владельца; от игрока -> отказ, владелец не меняется; неизвестный `token_id` -> отказ.
- После смены владельца прежний владелец получает отказ на ход, новый проходит.
- `dispatch("MoveToken")` с неизвестным `token_id` -> `false`, `auth_denied`, токены не двигались.
- Подложенный `payload.token` для чужого токена -> отказ.
- Числовой entity_id вместо `token_id` -> отказ.
- `from_cell` другой клетки -> ход применяется к токену из `token_id`, в логе `from_cell_mismatch`.
- Обработчик `MoveToken` с клиентом без `identity` -> нет вызова `dispatch`, `auth_denied` с `sender_unknown`.
- Тот же обработчик с ролью `master` -> ход проходит; с обычным игроком и чужим токеном -> отказ.
- `tokens.get` не вызывает `sync_from_world` (мок-счётчик).
- Тест «успех с неизвестным UID благодаря from_cell» удалить.

`run_tests` и `luajit tools/verify_allowlist.lua` проходят. Проверка слоёв: в `core/` и `server/` нет `require("net/identity")`, `client.account` нет вне `net/identity.lua`. Добавить эту проверку в `verify_allowlist.lua` (если это пока отдельная задача, записать в отчёт как рекомендацию).

Как проверить человеку (шаги в отчёте, прислать логи сервера и клиента):
1. Мастер (роль `master` в `server_config.json`) создаёт токен со spawn-командой и `owner` игрока `<identity>`. Ход владельца проходит на 5 клеток, в логе `command_result`.
2. Другой игрок пытается двигать этот токен -> `auth_denied`, `reason = "Нет прав на управление данным токеном"`.
3. Владелец пытается ход на 6 клеток -> `auth_denied`, `reason = "Слишком далеко"`.
4. Мастер меняет владельца командой `SetTokenOwner` -> `command_result`. Прежний владелец получает отказ, новый проходит.
5. Игрок без роли (если Neutron не отдаёт `role`) получает `sender_unknown` или отказ, сервер не падает.
6. Прислать строки `[auth_denied]`, `[command_result]`, `[token_move_command]`, и значения `identity` и `role` из лога `identity`.

## Вне задачи

- Интерфейс выбора владельца и панель Мастера.
- Разделение `block_interceptor.lua` и перенос клиентского реестра в `client/tokens.lua` (следующая задача).
- Подключение `table_session.lua`.
- Консольные команды `token_spawn/move/remove` (остаются как есть, но в отчёте отметить, что они обходят реестр).
- Проходимость клеток, анимация хода, ограничение дальности для Мастера.
