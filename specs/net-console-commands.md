# Спека: net/console-commands (консольные команды через реестр, защита от обхода)

**Файлы (закрытый список, правило 11 ослаблено только для этой задачи):**
- `vtt/modules/net/identity.lua`
- `vtt/modules/net/block_interceptor.lua` (только функции: `handle_packet`, `register_command`, `register_token_commands`, `register_server_messages`, `init_lifecycle`, `init`)
- `vtt/modules/server/commands.lua` (только команды `SpawnToken`, новая `SetBlock`)
- `vtt/modules/core/schema.lua` (только схемы `SpawnToken`, новая `SetBlock`)
- `tools/api_allowlist.lua` (добавить `api.console.tell`)
- тесты: новый `tests/console_commands_test.lua` (+ строка в `tests/all.lua`), правки `tests/identity_test.lua`, `tests/tokens_test.lua`

**Слой:** net + server (+ core: только схемы)
**Исполнитель:** сильная модель
**Риск:** красный (права и безопасность)

## Назначение

Закрыть обходы, оставшиеся после задачи `server-move-validation`: консольные команды `token_spawn`, `token_move`, `token_remove`, `block_set` вызывают `tokens.*` и `world.set_block` напрямую, без проверки роли. Сделать так, чтобы любое изменение токенов и блоков, откуда бы оно ни пришло (сеть или консоль), шло через `commands.dispatch`.

## Что известно из docs (и что нет)

- `api.console.set_command(схема, {permissions={...}}, исполнитель(args, client), [без_авторизации])`, пустая таблица прав `{}` открывает команду всем (`docs/neutron/api/libraries/console.md`).
- Роли и права задаёт `server_config.json` в `root/config` сервера, не пак. По умолчанию роль `member` имеет `role_management`, то есть при дефолтном конфиге каждый игрок проходит проверку `permissions = {"role_management"}`. Опираться на конфиг как на защиту нельзя.
- Свойства `Account`: только `identity`, `active`, `is_logged`, `role`. Пример в `console.md` использует `account.username`, этого поля нет в списке разрешённых, не использовать.
- API назначения роли аккаунту в `accounts.md` нет (только чтение). Не подтверждено, проверяет ли Neutron `permissions` команды и что лежит в `Account.role` у игрока с дефолтной ролью.

## Интерфейс

### net/identity.lua

- `M.MASTER_ROLE = "master"` (единственное место, где зашито имя роли Мастера).
- `M.is_master(role) -> boolean`: `role == M.MASTER_ROLE`.
- `M.label(client) -> string`: `account.identity`, иначе `player.username`, иначе `"unknown"`. Для логов. Чтение `client.account` и `client.player` только здесь (`player.username` разрешено `extra-classes.md`).
- `sender_of(client)`: логика без изменений, но лог `identity` пишется один раз для каждой пары `(identity, role)`, а не на каждый вызов.

### net/block_interceptor.lua

- Все 6 чтений `client.account` заменить вызовами `identity.label` / `identity.sender_of`. После правки `client.account` в `vtt/` остаётся только в `net/identity.lua`.
- Внутренняя функция `exec_via_registry(api, commands_module, tokens_module, client, name, payload)`:
  1. `sender_id, role = identity.sender_of(client)`; если `sender_id == nil`: `log("auth_denied", {name = name, reason = "sender_unknown"})`, ответ клиенту, выход без `dispatch`;
  2. `session_ctx = { tokens_module = tokens_module, is_gm = function(id) return id == sender_id and identity.is_master(role) end }`;
  3. `ok, res = commands_module.dispatch(name, sender_id, payload, session_ctx)`;
  4. ответ клиенту через `api.console.tell(text, client)` (при отказе текст причины, при успехе короткое подтверждение). Если `api.console.tell` отсутствует, пропустить без ошибки.
- Консольные команды (схема, затем команда реестра, payload):
  - `token_spawn: cx=<number>, cz=<number>, id=[string], owner=[string] -> Spawn token` -> `SpawnToken` `{cell={cx,cz,level=0}, asset_id="vtt:token", name=id or "Token", id=id, owner=owner}`;
  - `token_move: id=<string>, cx=<number>, cz=<number> -> Move token` -> `MoveToken` `{token_id=id, target_cell={cx,cz,level=0}}`;
  - `token_remove: id=<string> -> Remove token` -> `RemoveToken` `{token_id=id}`;
  - `token_owner: id=<string>, owner=[string] -> Set or clear token owner` -> `SetTokenOwner` `{token_id=id, owner=owner}` (без `owner` владелец снимается);
  - `block_set: x=<number>, y=<number>, z=<number>, id=[number] -> Set Block` -> `SetBlock` `{x,y,z,id}`.
- Прямые вызовы `tokens_module.spawn/move/remove` и `world_module.set_block` из функций регистрации команд удалить. Параметр `world_module` в `register_command` больше не нужен: убрать.
- Права команд в `set_command` оставить `{permissions = {"role_management"}}` как вторую линию защиты, но комментарий «только администраторы» заменить на точный: «по умолчанию `member` тоже имеет это право, решение принимает `commands.dispatch`».
- Обработчик сообщения `MoveToken`: использовать `exec_via_registry`-логику без второго лога `command_error` после `auth_denied` (причина отказа уже залогирована в `dispatch`). Ошибки `pcall` логировать как раньше.
- Защита от отсутствия Neutron: `init(api, ...)`, `register_interceptors`, `register_command`, `register_token_sync`, `register_token_commands`, `init_lifecycle` проверяют наличие нужных подсистем (`api`, `api.interceptors`, `api.console`, `api.entities`, `events`). Если нет: `log("neutron_api_missing", {part = "<имя>"})` и пропуск этой части. Падения быть не должно ни при `api == nil`, ни при частично заполненной таблице.
- Подписка на `register_token_commands(api, commands_module)`: сигнатура меняется (вместо `tokens_module` получает `commands_module`). `commands_module` получать тем же способом, что и в `register_server_messages`; новых `require("server/...")` не добавлять.

### server/commands.lua и core/schema.lua

- `SpawnToken`: схема получает необязательное `id` (string). `check`: если задан `payload.id` и `tokens.get(payload.id) ~= nil`, отказ `"Токен с таким id уже существует"`. `handler` передаёт в `tokens.spawn` `id = payload.id`.
- Новая команда `SetBlock` и схема `{x, y, z = number обязательные, id = number необязательное}`. `check`: `gm_rules.can_modify_world(sender_id, is_gm)`. `handler`: `world.set_block(x, y, z, payload.id or 1, 0)`. Модуль `server/world` получать как токены: `table_session.world_module or M.world or package.loaded["server/world"] or require("server/world")`. `init(tokens_mod, world_mod)`: второй параметр необязательный.
- Остальные команды и `dispatch` не менять.

## Правила и ограничения

- Новых API Neutron и движка, кроме `api.console.tell` (`docs/neutron/api/libraries/console.md`), не использовать. Добавить его в `tools/api_allowlist.lua` со ссылкой.
- Разделение `block_interceptor.lua` на модули и вынос оставшихся `require("server/*")` из `net` в этой задаче не делается (следующая задача). Нельзя добавлять новые.
- Автоинициализацию реестра команд не трогать.
- В `UNVERIFIED.md` добавить строки: (1) как назначить роль `master` аккаунту (в `accounts.md` нет API записи, права `role_management` намекают на встроенную команду); (2) проверяет ли Neutron `permissions` команд против роли клиента; (3) что лежит в `Account.role` у игрока с `default_role`.

## Критерий готовности

`tests/console_commands_test.lua` (мок `api.console.set_command` запоминает исполнителей; мок клиентов с `account.identity` и `account.role`):
- `token_spawn` от `master` с `id=t1 owner=alice` создаёт токен `t1` с `owner_id = "alice"`; от `member` отказ, токен не создан, `tokens.spawn` не вызывался.
- `token_spawn` с уже занятым `id` отказ, исходный токен цел.
- `token_move` (политика одна для сети и консоли, решает `gm_rules`): `master` двигает любой токен на любую дистанцию; `member` двигает чужой токен или токен без владельца: отказ по владельцу, токен не сдвинулся; `member`-владелец на расстояние > 5: отказ `"Слишком далеко"`; `member`-владелец на расстояние <= 5: успех.
- `token_remove`: `master` удаляет; `member` отказ.
- `token_owner`: `master` меняет и снимает владельца; `member` отказ.
- `block_set`: `master` вызывает `world.set_block` один раз; `member` отказ, `world.set_block` не вызывался.
- Клиент без `account.identity` для любой команды: нет `dispatch`, `auth_denied` с `sender_unknown`.
- Клиенту отправляется `api.console.tell` с причиной отказа; при отсутствии `api.console.tell` ошибки нет.
- `init(nil)` и `init({})` не падают, пишут `neutron_api_missing`.
- `identity.label`, `identity.is_master`, однократный лог пары `(identity, role)`.
- Статическая проверка: в `vtt/**.lua` строка `client.account` встречается только в `net/identity.lua` (тест читает файлы через `io.open`).
- Статическая проверка: в `block_interceptor.lua` нет вызовов `tokens_module.spawn`, `tokens_module.move`, `tokens_module.remove`, `world_module.set_block`.

`run_tests` и `luajit tools/verify_allowlist.lua` проходят.

Как проверить человеку (шаги и что прислать, логи сервера и скриншот чата):
1. В `server_config.json` (`root/config`) поставить `default_role = "master"`, перезапустить сервер, подключиться. В чате клиента выполнить `/token_spawn cx=0 cz=0 id=t1 owner=<identity игрока>` -> токен `t1` создан, в чате ответ об успехе. Затем `/token_move id=t1 cx=10 cz=10` проходит.
2. Поставить `default_role = "member"` (и убрать у `member` право `role_management`, как в рекомендованном конфиге), перезапустить, подключиться. Те же команды -> отказ с причиной в чате, в логе `[auth_denied]`, токен не создан и не двигался. `/block_set x=0 y=70 z=0 id=1` -> отказ.
3. Прислать: строки `[identity]`, `[auth_denied]`, `[command_result]`, ответы чата, `Account.role` из лога и результат проверки: блокирует ли Neutron команду раньше нашего кода (если команда не доходит до `[command_exec...]`/`[command]`, значит, права конфига работают).

## Вне задачи

- Разделение `block_interceptor.lua` по слоям и перенос клиентского реестра токенов.
- Назначение роли `master` аккаунту (нет API, фиксируется в `UNVERIFIED.md`).
- Подключение `table_session`, правка `hud.lua`, `scripts/world.lua`, `overlay.lua`, `picking.lua`.
- Проверка, что `allow-destroy = false` блокирует игроков (отдельная проверка S0.3).
- Проходимость клеток, анимация хода.
