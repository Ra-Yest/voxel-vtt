-- luacheck: ловит неизвестные глобальные переменные, в том числе выдуманные API.
std = "luajit"
codes = true
read_globals = {
    -- Библиотеки движка (уточнить по docs/api-notes.md)
    "block", "world", "player", "entities", "cameras", "input", "hud", "gfx",
}
exclude_files = { "docs/**" }
