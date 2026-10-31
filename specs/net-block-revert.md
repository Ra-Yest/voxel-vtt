# Спека: net/block-revert (откат блока на экране игрока, проверка входа)

**Файлы (закрытый список, правило 11 ослаблено только для этой задачи):**
- `vtt/modules/net/block_guard.lua`
- `vtt/modules/net/identity.lua` (новые функции `region_of`, проверка `is_logged`)
- `vtt/modules/server/world.lua` (одна новая функция чтения `get_block_state`)
- `vtt/scripts/world.lua` (только передача чтения мира в `block_guard.init`)
- `tools/api_allowlist.lua` (новые вызовы)
- тесты: `tests/block_guard_test.lua`, `tests/identity_test.lua`, `tests/world_test.lua` (если нет, создать и добавить в `tests/all.lua`)

**Слой:** net (+ server: только чтение)
**Исполнитель:** сильная модель
**Риск:** красный (права и безопасность)

## Назначение

Сейчас после отказа `block_guard` игрок видит у себя «фантомный» блок до перезахода: ядро при `false` из receive-перехватчика ничего клиенту не шлёт. Нужно после отказа отправить клиенту пакет-коррекцию с реальным блоком. Заодно закрыть вход незалогиненных клиентов и ошибку запуска перехватчика.

## Факты, на которые опирается спека

- `protocol.tell(client, packet_type, data)` отправляет пакет клиенту (`docs/neutron/api/libraries/protocol.md`). Данные почти не валидируются, пакет проходит через send-интерцепторы.
- `ServerMsg.BlockChanged`: `pid` (число, `-1` для сервера), `block = {id, state, pos = {x, y, z}}`; `x`, `z` int32, `y` uint8 (`annotation_server.yaml`). Клиент при `pid = -1` применяет блок принудительно (подтверждено агентом по коду Neutron-Client).
- Клиент использует `BlockRegionUpdate/Destroy/Interact` для блоков в пределах ±127 от региона игрока, иначе `BlockUpdate/Destroy/Interact` (`reports/2026-10-29-neutron-audit-2.md`, п. 5). Позиции в `BlockRegion*` относительные, `x`, `z` int8, `y` uint8.
- Identity присылает клиент в `JoinGame`; при `password_auth = false` его никто не проверяет. Незалогиненный клиент имеет `account.is_logged = false`.

## Шаг 0 (обязателен, до кода)

Прочитай код Neutron и ответь в отчёте, строка и файл на каждый пункт:
1. Как из кода пака получить модуль `protocol` (через `api.*`, `$Multiplayer` или другим способом)? Что принимает `tell` в `packet_type`: числовой ID (как `api.interceptors.packets.ServerMsg.BlockChanged`) или строку?
2. Формулы перевода относительной позиции `BlockRegion*` в абсолютную (клиент: `modules/api/v2/sandbox.lua` и серверный разбор в `handlers/main.lua`). Единицы региона (блоки или чанки), что именно хранит `client.player.region_pos` и совпадает ли оно с `CLIENT_PLAYER.region` клиента.
3. Какой вызов движка читает состояние блока (`block.get_states` или другой) и есть ли он в `docs/engine/scripting/builtins/libblock.md`.

Если пункт 1 или 3 не подтверждается документацией или кодом, остановись и запиши в `UNVERIFIED.md`. Если не подтверждается пункт 2, реализуй откат только для пакетов с абсолютными координатами (`BlockUpdate`, `BlockDestroy`), а для `BlockRegion*` пиши `log("block_guard_region_unresolved", {...})` и запиши в `UNVERIFIED.md`.

## Интерфейс

### server/world.lua

- `M.get_block_state(x, y, z) -> id, state | nil`: `id` из `block.get`, `state` из вызова движка из шага 0. Возвращает `nil`, если блок не загружен или `id` некорректен. Только чтение, `block.set` не трогать. Ссылки `-- docs:` обязательны.

### net/identity.lua

- `sender_of(client)`: возвращает `nil, nil`, если `account.is_logged ~= true` (поле разрешено `extra-classes.md`). Лог `auth_denied` с причиной `not_logged` при первом таком вызове для `identity`.
- `region_of(client) -> {x, y, z} | nil`: читает `client.player.region_pos`, возвращает `nil` при отсутствии или нечисловых значениях. Единственное место, где читается `client.player`.

### net/block_guard.lua

- `M.init(api, opts)`: `opts.read_block = function(x, y, z) -> id, state | nil` (передаёт `scripts/world.lua`, значение `world.get_block_state`). `block_guard` не делает `require("server/...")`.
- Каждый вызов `add_interceptor` обернуть в `pcall`: при ошибке добавить имя в `missing` и `log("block_guard_error", ...)`, остальные продолжать.
- После отказа для пакетов с изменением блока (`BlockUpdate`, `BlockDestroy`, `BlockInteract`, `BlockRegion*`) вызвать `send_correction(client, pos)`:
  1. абсолютная `pos`: из `original.block.pos` (`BlockUpdate`) или `original.pos` (`BlockDestroy`, `BlockInteract`); для `BlockRegion*` через формулу из шага 0 и `identity.region_of(client)`;
  2. `y` вне 0..255 или `pos` не получена: коррекции нет, `log("block_guard_correction_skipped", {name, reason})`;
  3. `id, state = opts.read_block(x, y, z)`; `nil` -> коррекции нет, тот же лог;
  4. `protocol.tell(client, <BlockChanged из шага 0>, {pid = -1, block = {id = id, state = state, pos = {x = x, y = y, z = z}}})`.
- Коррекция отправляется на каждый отказ (не прореживается). Прореживается только лог `auth_denied`, как раньше.
- Ошибка внутри `send_correction` перехватывается (`pcall`), логируется `block_guard_error`, перехватчик всё равно возвращает `false`.
- `EntitySpawnAttempt` и `EntityInteract` коррекции не требуют.
- Если `opts.read_block` или `protocol` недоступны, `init` пишет `block_guard_correction_unavailable`, но защита (отказ) остаётся активной.

### scripts/world.lua

- В серверной ветке вызов принимает вид `require("net/block_guard").init(api, { read_block = world.get_block_state })`. Больше ничего в файле не менять.

## Правила и ограничения

- Новые API: только `protocol.tell`, чтение состояния блока и `account.is_logged`, каждый со ссылкой `-- docs:` и записью в `tools/api_allowlist.lua`.
- `net/block_guard.lua` не требует `server/*` и не читает `client.account` и `client.player` напрямую, только через `net/identity`.
- Ответ при отказе не должен давать игроку возможность изменить мир: коррекция только уменьшает расхождение.
- Не блокировать дополнительные пакеты, не менять `GUARDED_PACKETS`.

## Критерий готовности

`tests/block_guard_test.lua` (моки `api`, `protocol.tell`, `opts.read_block`):
- `BlockUpdate` от `member` с позицией (10, 64, -5): `tell` вызван один раз с реальными `id` и `state` из мока, `pid = -1`, `pos` совпадает;
- то же для `BlockDestroy`; для `BlockInteract` коррекция с реальным блоком;
- `BlockRegion*` (если шаг 0 подтвердил формулу): известная относительная позиция и `region_pos` дают ожидаемую абсолютную; иначе `block_guard_region_unresolved`, `tell` не вызывается;
- Мастер: `tell` не вызывается;
- `y = 300` или `read_block` вернул `nil`: `tell` не вызывается, пакет всё равно отклонён, лог `block_guard_correction_skipped`;
- `tell` бросает ошибку: перехватчик возвращает `false`, лог `block_guard_error`;
- `add_interceptor` бросает ошибку для одного пакета: остальные регистрируются, `init` возвращает `false, missing`;
- `init(api)` без `opts` или без `protocol`: защита активна, лог `block_guard_correction_unavailable`;
- 30 отказов подряд: 30 вызовов `tell`, 2 записи `auth_denied`.

`tests/identity_test.lua`: клиент с `is_logged = false` или без поля -> `nil, nil`; `region_of` с корректными данными, без `player`, с нечисловыми значениями; `client.player` читается только в `net/identity.lua` (статическая проверка по `vtt/**.lua`).

`tests/world_test.lua`: `get_block_state` возвращает пару из мока `block`, `nil` для незагруженного блока.

`run_tests` и `luajit tools/verify_allowlist.lua` проходят.

Как проверить человеку (шаги и что прислать):
1. Игрок `member` ставит блок и ломает блок рядом с собой: блок сразу возвращается в исходное состояние без перезахода. Повторить на расстоянии больше 127 блоков от региона, где клиент использует `BlockUpdate`.
2. Игрок кликает ПКМ по двери, сундуку, блоку с интерфейсом: окно не должно оставаться открытым.
3. Мастер ставит и ломает блоки: проходит как раньше.
4. С `password_auth = true`: клиент без `/login` не может перемещать токены и выполнять консольные команды Мастера.
5. Прислать: `[block_guard_active]`, строки `[auth_denied]`, `[block_guard_correction_skipped]`, `[block_guard_region_unresolved]` (если есть), описание того, что видит игрок.

## Вне задачи

- Видимость моделей игроков (`base:player`).
- Блокировка `EntityDespawn`, инвентаря, `PlayerCheats`.
- Разделение `block_interceptor.lua`, единая инициализация реестра команд.
- Автоматическое назначение Мастера кодом пака (запрещено: роль принадлежит Neutron).
