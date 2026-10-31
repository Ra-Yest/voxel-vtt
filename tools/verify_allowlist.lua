-- tools/verify_allowlist.lua
-- Проверяет белый список API по документации. Запуск из корня репозитория:
--   luajit tools/verify_allowlist.lua      (Windows: luajit tools\verify_allowlist.lua)
-- Результат печатается и пишется в tools/verify_allowlist_result.txt.
--
-- Что проверяется:
--  1. Для каждой записи api_allowlist.lua существует файл документации, на который она ссылается.
--  2. Имя функции встречается в тексте этого файла (с фрагментом строки для глазной проверки).
--  3. Код в vtt/ не вызывает ничего, чего нет в белом списке.
--  4. Комментарии "-- docs: путь" в коде указывают на существующие файлы.
--  5. Какие файлы документации не использованы ни одной записью (пробелы покрытия).
--
-- Совпадение по имени не доказывает, что функция называется и работает именно так:
-- это отсев очевидно выдуманного. Остальное смотрит человек по фрагментам.

local ALLOW_PATH = "tools/api_allowlist.lua"
local OUT_PATH = "tools/verify_allowlist_result.txt"

local out = {}
local function p(s) out[#out + 1] = s; print(s) end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

local function list_files(dir)
    local win = package.config:sub(1, 1) == "\\"
    local cmd
    if win then
        cmd = 'dir /b /s "' .. (dir:gsub("/", "\\")) .. '" 2>nul'
    else
        cmd = 'find "' .. dir .. '" -type f 2>/dev/null'
    end
    local res = {}
    local h = io.popen(cmd)
    if h then
        for line in h:lines() do
            line = line:gsub("\r", "")
            if line ~= "" then res[#res + 1] = line end
        end
        h:close()
    end
    return res
end

local function basename(path) return path:match("([^/\\]+)$") or path end

-- Поиск слова с учётом границ; возвращает позицию начала или nil.
local function find_word(text, name)
    local pat = esc(name)
    if name:sub(1, 1):match("[%w_]") then pat = "%f[%w_]" .. pat end
    if name:sub(-1):match("[%w_]") then pat = pat .. "%f[^%w_]" end
    return text:find(pat)
end

local function line_at(text, i)
    local s = text:sub(1, i):match(".*\n()") or 1
    local e = text:find("\n", i, true) or (#text + 1)
    local line = trim(text:sub(s, e - 1))
    if #line > 110 then
        local cut = 107
        -- не резать посреди многобайтного символа UTF-8
        while cut > 0 do
            local b = line:byte(cut + 1)
            if not b or b < 0x80 or b >= 0xC0 then break end
            cut = cut - 1
        end
        line = line:sub(1, cut) .. "..."
    end
    return line
end

local function split_name(key)
    local parts = {}
    for seg in key:gmatch("[^%.:]+") do parts[#parts + 1] = seg end
    return parts
end

-- Варианты имени от строгого к слабому.
local function name_variants(key)
    local v = {}
    local seen = {}
    local function add(level, label, name)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            v[#v + 1] = { level = level, label = label, name = name }
        end
    end
    add(1, "полное имя", key)
    add(1, "полное имя", (key:gsub(":", ".")))
    if key:sub(1, 4) == "api." then add(2, "без префикса api", key:sub(5)) end
    local parts = split_name(key)
    if #parts >= 2 then
        add(3, "две последние части", parts[#parts - 1] .. "." .. parts[#parts])
        add(3, "две последние части", parts[#parts - 1] .. ":" .. parts[#parts])
    end
    add(4, "только имя функции", parts[#parts])
    return v
end

-- Достаёт первый путь к файлу из ссылки "docs/x/y.md#anchor".
local function ref_path(ref)
    if type(ref) ~= "string" then return nil end
    local path = ref:match("([%w_%./%-\\]+%.%a+)")
    return path
end

-- ---------- загрузка ----------

local chunk, err = loadfile(ALLOW_PATH)
if not chunk then
    print("Не удалось загрузить " .. ALLOW_PATH .. ": " .. tostring(err))
    os.exit(2)
end
local allow = chunk()
local entries = {}
for k, v in pairs(allow.functions or {}) do entries[k] = v end
for k, v in pairs(allow.methods or {}) do entries[k] = v end
local libs = allow.libs or {}

local doc_files = list_files("docs")
local by_base = {}
for _, f in ipairs(doc_files) do by_base[basename(f)] = by_base[basename(f)] or f end

local function resolve(path)
    if read(path) then return path, nil end
    local alt = by_base[basename(path)]
    if alt then return alt, "путь неверен, файл найден как " .. alt end
    return nil, "файл не найден"
end

-- ---------- 1-2. записи белого списка ----------

local keys = {}
for k in pairs(entries) do keys[#keys + 1] = k end
table.sort(keys)

local stats = { ok = 0, weak = 0, badpath = 0, nofile = 0, notfound = 0 }
local lines_ok, lines_weak, lines_bad = {}, {}, {}
local used_docs = {}

for _, key in ipairs(keys) do
    local ref = entries[key]
    local path = ref_path(ref)
    if not path then
        stats.nofile = stats.nofile + 1
        lines_bad[#lines_bad + 1] = "НЕТ ССЫЛКИ    " .. key .. "  (ссылка: " .. tostring(ref) .. ")"
    else
        local real, note = resolve(path)
        if not real then
            stats.nofile = stats.nofile + 1
            lines_bad[#lines_bad + 1] = "НЕТ ФАЙЛА     " .. key .. "  -> " .. path
        else
            used_docs[basename(real)] = true
            local text = read(real)
            local found
            for _, var in ipairs(name_variants(key)) do
                local i = find_word(text, var.name)
                if i then found = { var = var, line = line_at(text, i) }; break end
            end
            if not found then
                stats.notfound = stats.notfound + 1
                lines_bad[#lines_bad + 1] = "НЕ НАЙДЕНО    " .. key .. "  в " .. real
            else
                if note then
                    stats.badpath = stats.badpath + 1
                    lines_bad[#lines_bad + 1] = "ПУТЬ НЕВЕРЕН  " .. key .. "  -> " .. path .. " | " .. note
                end
                local entry = key .. "  [" .. found.var.label .. ", " .. basename(real) .. "]\n      > " .. found.line
                if found.var.level <= 3 then
                    stats.ok = stats.ok + 1
                    lines_ok[#lines_ok + 1] = entry
                else
                    stats.weak = stats.weak + 1
                    lines_weak[#lines_weak + 1] = entry
                end
            end
        end
    end
end

p("=== Проверка белого списка API ===")
p(string.format("Записей: %d | подтверждено по имени: %d | слабое совпадение: %d | неверный путь: %d | нет файла/ссылки: %d | не найдено: %d",
    #keys, stats.ok, stats.weak, stats.badpath, stats.nofile, stats.notfound))

p("\n--- ПРОБЛЕМЫ (вероятно выдумано или неверная ссылка) ---")
if #lines_bad == 0 then p("нет") end
for _, l in ipairs(lines_bad) do p(l) end

p("\n--- СЛАБОЕ СОВПАДЕНИЕ (найдено только имя функции, проверить глазами) ---")
if #lines_weak == 0 then p("нет") end
for _, l in ipairs(lines_weak) do p(l) end

p("\n--- ПОДТВЕРЖДЕНО ПО ИМЕНИ (с фрагментом документации) ---")
if #lines_ok == 0 then p("нет") end
for _, l in ipairs(lines_ok) do p(l) end

-- ---------- 3-4. код в vtt/ ----------

-- Корни, которые сканируются всегда, даже если их нет в белом списке:
-- именно так выдуманные api.* и Replication.* проходили мимо проверки.
local extra_roots = { "api", "Message", "Replication", "Replicator", "gui", "player", "entities", "cameras" }
local prefixes = {}
for _, l in ipairs(extra_roots) do prefixes[l] = true end
for _, l in ipairs(libs) do prefixes[l] = true end
for _, k in ipairs(keys) do prefixes[split_name(k)[1]] = true end

local function in_allow(chain)
    for _, k in ipairs(keys) do
        local kk = k:gsub(":", ".")
        local cc = chain:gsub(":", ".")
        if cc == kk or cc:sub(1, #kk + 1) == kk .. "." then return true end
        if kk:sub(1, #cc + 1) == cc .. "." then return true end -- пространство имён, например api.messages
    end
    return false
end

local code_issues = {}
local doc_comment_issues = {}
local vtt_files = {}
for _, f in ipairs(list_files("vtt")) do
    if f:match("%.lua$") then vtt_files[#vtt_files + 1] = f end
end
table.sort(vtt_files)

for _, f in ipairs(vtt_files) do
    local text = read(f) or ""
    local n = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local code = line:gsub("%-%-.*$", "")
        for chain in code:gmatch("[%a_][%w_]*[%.:][%w_%.:]*") do
            chain = chain:gsub("[%.:]+$", "")
            local first = split_name(chain)[1]
            if prefixes[first] and not in_allow(chain) then
                code_issues[#code_issues + 1] = f .. ":" .. n .. "  " .. chain
            end
        end
        local dpath = line:match("%-%-%s*docs:%s*([%w_%./%-\\]+%.%a+)")
        if dpath then
            local real, note = resolve(dpath)
            if not real then
                doc_comment_issues[#doc_comment_issues + 1] = f .. ":" .. n .. "  " .. dpath .. " (" .. note .. ")"
            elseif note then
                doc_comment_issues[#doc_comment_issues + 1] = f .. ":" .. n .. "  " .. dpath .. " (" .. note .. ")"
            else
                used_docs[basename(real)] = true
            end
        end
    end
end

p("\n=== Код в vtt/ ===")
p("Файлов Lua: " .. #vtt_files)
p("\n--- Вызовы, которых нет в белом списке ---")
if #code_issues == 0 then p("нет") end
for _, l in ipairs(code_issues) do p(l) end
p("\n--- Подсказка ---")
p("Имена вида session.* и rules.* в vtt/ могут быть ложными срабатываниями: это ваши модули,")
p("а не библиотеки движка. Из-за такого совпадения имён модули лучше переименовать.")
p("\n--- Комментарии '-- docs:' с неверными путями ---")
if #doc_comment_issues == 0 then p("нет") end
for _, l in ipairs(doc_comment_issues) do p(l) end

-- ---------- 5. покрытие документации ----------

p("\n=== Покрытие документации ===")
local unused = {}
for _, f in ipairs(doc_files) do
    local b = basename(f)
    if (b:match("%.md$") or b:match("%.html$") or b:match("%.txt$")) and b ~= "README.md" and not used_docs[b] then
        unused[#unused + 1] = f
    end
end
table.sort(unused)
p("Файлов документации: " .. #doc_files .. ", не использованы ни одной записью: " .. #unused)
for _, f in ipairs(unused) do p("  " .. f) end

local bad = #lines_bad + #code_issues + #doc_comment_issues
p("\nИтог: " .. (bad == 0 and "критичных проблем не найдено" or (bad .. " проблем(ы), см. выше")))

local f = io.open(OUT_PATH, "wb")
if f then f:write(table.concat(out, "\n"), "\n"); f:close() end
os.exit(bad == 0 and 0 or 1)
