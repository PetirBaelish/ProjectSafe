-- @author альтернативный а4
-- @uid 1

-- ============================================================
--  Scout Pro  |  Neverlose CS2
--  Всё в одном: Force Head + Pointscale, Hit Chance на земле и в
--  прыжке, Adaptive Min Damage, Anti-Miss, Lethal, Adaptive Stop,
--  Auto-Peek. Работает только со Scout.
-- ============================================================

-- ========== МЕНЮ ==========
local tab    = ui.tab("Scout Pro")
local g_main = tab:group("MAIN")
local g_acc  = tab:group("ТОЧНОСТЬ")
local g_air  = tab:group("ТВОЙ ПРЫЖОК")
local g_tgt  = tab:group("ЦЕЛИ")
local g_peek = tab:group("AUTO-PEEK")

local enable     = g_main:checkbox("Включить Scout Pro", false)
local force_head = g_main:checkbox("Force Head (только голова и шея)", true)
local head_strict = g_main:checkbox("Строго голова (тело и таз не выбирать)", true)
local ps_val     = g_main:slider_int("Head Pointscale (%)", 10, 100, 45, "%d%%")

local hc_ground  = g_acc:slider_int("Hit Chance на земле", 0, 100, 70, "%d%%")
local hc_air     = g_acc:slider_int("Hit Chance в прыжке", 0, 100, 50, "%d%%")
local md_adapt   = g_acc:checkbox("Adaptive Min Damage (101 / HP+5 через стену)", true)
local stop_on    = g_acc:checkbox("Adaptive Stop (микро-контрстрейф)", true)

local air_stop   = g_air:checkbox("Остановка ввода в воздухе", true)
local air_gate   = g_air:checkbox("Стрелять в прыжке только у пика", true)
local apex       = g_air:slider_int("Окно пика (вертик. скорость, u/s)", 10, 120, 50)

local fast_body  = g_tgt:checkbox("Тело против бегущих и летящих целей", false)
local air_safe   = g_tgt:checkbox("Safe Points против летящих целей", false)
local lethal_on  = g_tgt:checkbox("Добивание в тело (Lethal)", false)
local lethal_hp  = g_tgt:slider_int("Lethal HP Threshold", 1, 100, 40)
local anti_miss  = g_tgt:checkbox("Anti-Miss (Safe Points + таз после промаха)", true)

local peek_key
do
    local ok, k = pcall(function() return g_peek:keybind("Кнопка для Auto-Peek", nil, "Hold") end)
    if not ok or not k then k = g_peek:keybind("Кнопка для Auto-Peek") end
    peek_key = k
end

-- ========== КОНСТАНТЫ ==========
local ACCURATE_PCT  = 0.34   -- доля макс. скорости, при которой Scout точен
local HC_DROP       = 7      -- минус к Hit Chance по быстрой цели
local LETHAL_HC_DROP = 15    -- минус к Hit Chance при добивании
local FAST_SPEED    = 135    -- цель быстрее этой скорости считается бегущей (u/s)

local MD_VISIBLE    = 101    -- Min Damage по прямо видимой цели
local MD_WALL_EXTRA = 5      -- через стену: HP врага + это значение
local MISS_WINDOW   = 0.35   -- сколько секунд ждём попадания после выстрела

local RETURN_TIME   = 0.9    -- максимум времени возврата Auto-Peek, сек
local REACH         = 14     -- ближе этого к точке пути она считается пройденной
local CRUMB_STEP    = 24     -- шаг записи пути, юниты
local MAX_CRUMBS    = 64     -- максимум точек пути
local STUCK_TIME    = 0.15   -- столько секунд без прогресса = застрял, отмена

-- ========== ЭЛЕМЕНТЫ ВСТРОЕННОГО МЕНЮ ==========
local function variants(...)
    local out = {}
    for _, name in ipairs({...}) do
        out[#out + 1] = {"Aimbot", "Rage", "Selection", name}
        out[#out + 1] = {"Rage", "Selection", name}
        out[#out + 1] = {"Aimbot", "Rage", name}
    end
    return out
end

local PATHS = {
    hit_chance  = variants("Hit Chance"),
    min_damage  = variants("Min Damage"),
    hitboxes    = variants("Hitboxes"),
    safe_points = variants("Safe Points", "Safe Point"),
    head_scale  = variants("Head Pointscale", "Head Scale", "Pointscale", "Point Scale"),
}

local ctl, resolved = {}, false

local function resolve()
    resolved = true
    for key, list in pairs(PATHS) do
        for _, path in ipairs(list) do
            local ok, c = pcall(function() return ui.find(unpack(path)) end)
            if ok and c and pcall(function() return c:get_type() end) then
                ctl[key] = c
                break
            end
        end
        if not ctl[key] then log.console("[scout pro] не найден: " .. key) end
    end
end

-- ========== ПЕРЕОПРЕДЕЛЕНИЕ И ВОЗВРАТ ТВОИХ ЗНАЧЕНИЙ ==========
local saved, applied = {}, {}

local function override(key, value)   -- value: значение или функция(оригинал)
    local c = ctl[key]
    if not c then return end
    if saved[key] == nil then
        local ok, v = pcall(function() return c:get_value() end)
        if not ok or v == nil then return end
        saved[key] = { v }
    end
    local nv = value
    if type(value) == "function" then nv = value(saved[key][1]) end
    if applied[key] == nv then return end
    applied[key] = nv
    pcall(function() c:set_value(nv) end)
end

local function release(key)
    local c = ctl[key]
    if c and saved[key] ~= nil then
        pcall(function() c:set_value(saved[key][1]) end)
    end
    saved[key], applied[key] = nil, nil
end

-- хитбоксы: nil (твои), "head" (голова и шея), "body" (живот и таз), "pelvis" (таз)
local HB_SETS = {
    head   = { head = true, neck = true },
    body   = { stomach = true, pelvis = true },
    pelvis = { pelvis = true },
}
local hb_mode, saved_hb = nil, nil

local function set_hitbox_mode(mode)
    if hb_mode == mode then return end
    local c = ctl.hitboxes
    if not c then hb_mode = mode return end

    if mode == nil then
        if saved_hb ~= nil then pcall(function() c:set_values(saved_hb) end) end
        saved_hb, hb_mode = nil, nil
        return
    end

    if saved_hb == nil then
        local ok, v = pcall(function() return c:get_values() end)
        if ok then saved_hb = v end
    end

    local items, want = {}, {}
    pcall(function() items = c:get_items() end)
    for _, it in ipairs(items) do
        if HB_SETS[mode][tostring(it):lower()] then want[#want + 1] = it end
    end
    if #want == 0 then return end

    local ok = pcall(function() c:set_values(want) end)
    if not ok then
        local map = {}
        for _, it in ipairs(want) do map[it] = true end
        pcall(function() c:set_values(map) end)
    end
    hb_mode = mode
end

local function release_scout()
    release("min_damage")
    release("hit_chance")
    release("safe_points")
    release("head_scale")
    set_hitbox_mode(nil)
end

-- ========== ХЕЛПЕРЫ ==========
local move_scale = nil   -- масштаб ввода движения (определяется по твоим нажатиям)

local function weapon_info(me)
    local info
    pcall(function()
        local w = me:weapon()
        info = w and w:weapon_info()
    end)
    return info
end

local function weapon_name(info)
    if not info then return "" end
    return tostring(info.name or info.display or ""):lower()
end

local function is_scout(info)
    local n = weapon_name(info)
    return n:find("ssg") ~= nil or n:find("scout") ~= nil
end

local function visible_to(me, from, pawn)
    local targets = { pawn:eye_position(), pawn:origin() + vector(0, 0, 40) }
    for _, to in ipairs(targets) do
        local r = trace.line(from, to, { skip = me, mask = trace.mask.shot })
        if r and (r.fraction >= 0.97 or r.entity == pawn) then return true end
    end
    return false
end

-- можно ли нанести урон врагу сквозь стену (кэш на 50 мс на врага)
local pen_cache = {}
local function penetrable(pawn, key, now)
    local c = pen_cache[key]
    if c and now - c.t < 0.05 then return c.v end
    local v = false
    pcall(function()
        local d1 = trace.damage(pawn, pawn:eye_position())
        local d2 = trace.damage(pawn, pawn:origin() + vector(0, 0, 40))
        v = (d1 or 0) > 0 or (d2 or 0) > 0
    end)
    pen_cache[key] = { t = now, v = v }
    return v
end

-- возвращает: ближайший прямо видимый враг, ближайший простреливаемый за стеной
-- запись: { key, hp, dist, air, fast }
local function scan(me, now)
    local vis, wall
    pcall(function()
        local from, origin = me:eye_position(), me:origin()
        for _, e in ipairs(entity.players()) do
            local pawn, ctrl = e.pawn, e.controller
            if pawn and pawn:alive() and pawn:is_enemy() then
                local d = origin:dist(pawn:origin())
                local key = ctrl and ctrl:address() or 0
                local in_air = not pawn:on_ground()
                local rec = {
                    key = key, hp = pawn:health(), dist = d, air = in_air,
                    fast = in_air or pawn:velocity():length2d() > FAST_SPEED,
                }
                if visible_to(me, from, pawn) then
                    if not vis or d < vis.dist then vis = rec end
                elseif penetrable(pawn, key, now) then
                    if not wall or d < wall.dist then wall = rec end
                end
            end
        end
    end)
    return vis, wall
end

-- направить модель к точке (dx, dy в мировых координатах) с полным вводом
local function move_towards(cmd, dx, dy)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 or not move_scale then return end
    local yaw = math.rad(cmd:view_angles().y)
    local c, s = math.cos(yaw), math.sin(yaw)
    local fwd  = dx * c + dy * s
    local side = dx * s - dy * c
    cmd:set_move(fwd / len * move_scale, side / len * move_scale)
end

-- ========== СОБЫТИЯ: ВЫСТРЕЛЫ, ПОПАДАНИЯ, ПРОМАХИ ==========
local fire_pending = false
local miss_flag    = {}    -- [ключ игрока] = true после промаха, до попадания
local shot         = nil   -- { t, key, clean, hit } последний выстрел Scout

events.on("weapon_fire", function(ev)
    pcall(function()
        local c = ev:get_controller("userid")
        if c and c:is_local() then fire_pending = true end
    end)
end)

events.on("player_hurt", function(ev)
    pcall(function()
        local a = ev:get_controller("attacker")
        if not (a and a:is_local()) then return end
        local v = ev:get_controller("userid")
        if v then miss_flag[v:address()] = nil end   -- попал: возвращаем тап в голову
        if shot then shot.hit = true end
    end)
end)

events.on("player_death", function(ev)
    pcall(function()
        local v = ev:get_controller("userid")
        if v then miss_flag[v:address()] = nil end
    end)
end)

events.on("level_init", function()
    miss_flag, pen_cache, shot = {}, {}, nil
end)

-- ========== СОСТОЯНИЕ AUTO-PEEK ==========
local path       = {}      -- путь: [1] = точка при нажатии бинда, дальше хлебные крошки
local key_was    = false
local returning  = false
local return_from = 0
local stuck_d, stuck_t = nil, 0
local last_clip, last_wname = nil, ""

local function reset_peek()
    path, returning, fire_pending, key_was = {}, false, false, false
    stuck_d, last_clip = nil, nil
end

-- ========== ГЛАВНЫЙ ЦИКЛ ==========
events.on("createmove", function(cmd)
    if not enable:get() then
        release_scout()
        reset_peek()
        return
    end
    if not resolved then resolve() end

    local me = entity.local_pawn()
    if not me or not me:alive() then
        release_scout()
        reset_peek()
        return
    end
    if game.freeze_time() then return end

    -- масштаб ввода запоминаем по реальным нажатиям игрока
    local f, sd = cmd:move()
    local m = math.max(math.abs(f or 0), math.abs(sd or 0))
    if m > 0 and (not move_scale or m > move_scale) then move_scale = m end

    local info     = weapon_info(me)
    local scout    = is_scout(info)
    local grounded = me:on_ground()
    local vel      = me:velocity()
    local speed    = vel:length2d()
    local origin   = me:origin()
    local now      = globals.curtime()

    local maxs = (info and info.max_speed) or engine.max_speed() or 230
    if not maxs or maxs <= 0 then maxs = 230 end
    local thr = maxs * ACCURATE_PCT

    -- ---- цели и настройки рейджа (только Scout) ----
    local vis, wall
    if scout then
        vis, wall = scan(me, now)
        local primary = vis or wall

        local lethal = lethal_on:get() and vis ~= nil and vis.hp <= lethal_hp:get()
        local missed = anti_miss:get() and primary ~= nil and miss_flag[primary.key] == true
        local air_target = air_safe:get() and vis ~= nil and vis.air

        -- Hit Chance: своё значение для земли и для прыжка
        local hc = grounded and hc_ground:get() or hc_air:get()
        if vis and vis.fast then hc = hc - HC_DROP end
        if lethal then hc = hc - LETHAL_HC_DROP end
        override("hit_chance", math.max(0, math.min(100, hc)))

        -- Min Damage: добивание, иначе 101 / HP+5 через стену
        if lethal then
            override("min_damage", 1)
        elseif md_adapt:get() and vis then
            override("min_damage", MD_VISIBLE)
        elseif md_adapt:get() and wall then
            override("min_damage", math.min(126, wall.hp + MD_WALL_EXTRA))
        else
            release("min_damage")
        end

        -- Pointscale головы
        if force_head:get() then
            override("head_scale", ps_val:get())
        else
            release("head_scale")
        end

        -- Safe Points: после промаха или против летящей цели
        if missed or air_target then
            override("safe_points", true)
        else
            release("safe_points")
        end

        -- Хитбоксы: таз после промаха > тело (добивание, быстрая цель) > голова
        if force_head:get() and head_strict:get() then
            set_hitbox_mode("head")
        elseif missed then
            set_hitbox_mode("pelvis")
        elseif lethal or air_target or (fast_body:get() and vis and vis.fast) then
            set_hitbox_mode("body")
        elseif force_head:get() then
            set_hitbox_mode("head")
        else
            set_hitbox_mode(nil)
        end
    else
        release_scout()
    end

    -- ---- выстрел в прыжке только у пика (до учёта выстрелов) ----
    if scout and not grounded and air_gate:get() and cmd:has(buttons.attack)
        and math.abs(vel.z) > apex:get() then
        pcall(function() cmd:release(buttons.attack) end)
    end

    -- ---- учёт выстрелов и промахов ----
    if shot and now - shot.t > MISS_WINDOW then
        -- чистый промах: видимая цель, точная скорость, а урона нет
        if not shot.hit and shot.clean and shot.key then miss_flag[shot.key] = true end
        shot = nil
    end

    -- выстрел: событие, либо убыль патронов в магазине, либо нажатая атака
    local wname = weapon_name(info)
    local clip = info and info.clip
    if clip and last_clip and wname == last_wname and clip < last_clip then
        fire_pending = true
    end
    if scout and cmd:has(buttons.attack) and not (info and info.can_shoot == false) then
        fire_pending = true
    end
    last_clip, last_wname = clip, wname

    if fire_pending and scout and not shot then
        shot = {
            t = now, hit = false,
            key = vis and vis.key or nil,
            clean = vis ~= nil and grounded and speed <= thr,
        }
    end

    -- ---- Auto-Peek: только пока зажат бинд ----
    local held = peek_key:active()
    if held and not key_was then
        path = grounded and { origin } or {}
        returning = false
    elseif not held then
        path, returning, fire_pending = {}, false, false
    end
    key_was = held
    if held and #path == 0 and grounded and not returning then path = { origin } end

    if held and not returning and #path > 0 and #path < MAX_CRUMBS then
        local last = path[#path]
        local dx, dy = origin.x - last.x, origin.y - last.y
        if dx * dx + dy * dy > CRUMB_STEP * CRUMB_STEP then path[#path + 1] = origin end
    end

    if fire_pending then
        fire_pending = false
        if held and not returning and #path > 1 and scout and move_scale then
            returning, return_from = true, now
            stuck_d, stuck_t = nil, now
        end
    end

    if returning then
        local tgt = path[#path]
        local dx, dy = tgt.x - origin.x, tgt.y - origin.y
        local d = math.sqrt(dx * dx + dy * dy)
        while d < REACH and #path > 1 do
            path[#path] = nil
            tgt = path[#path]
            dx, dy = tgt.x - origin.x, tgt.y - origin.y
            d = math.sqrt(dx * dx + dy * dy)
        end

        local done = (d < REACH and #path <= 1)
            or (now - return_from) > RETURN_TIME

        -- застревание проверяем только на земле: в воздухе инерция уносит дальше
        if not done and grounded then
            if not stuck_d or d < stuck_d - 2 then
                stuck_d, stuck_t = d, now
            elseif now - stuck_t > STUCK_TIME then
                done = true
            end
        end

        if done then
            returning = false
            path = { path[1] }
        else
            move_towards(cmd, dx, dy)
            return   -- на время возврата торможение не работает
        end
    end

    -- ---- движение Scout ----
    if not scout then return end

    if not grounded then
        -- в прыжке: не разгоняемся, пока видим врага
        if air_stop:get() and vis then cmd:set_move(0, 0) end
        return
    end

    -- Adaptive Stop на земле
    if not stop_on:get() or not vis or cmd:has(buttons.jump) then return end
    if info and info.can_shoot == false then return end   -- между выстрелами не мешаем

    -- уже достаточно медленно для точного выстрела: управление твоё
    if speed <= thr then return end

    if not move_scale then
        cmd:set_move(0, 0)
        return
    end

    -- микро-контрстрейф: ввод против текущей скорости, сила падает у порога
    local strength = math.max(0.3, math.min(1.0, (speed - thr) / speed * 2))
    local yaw  = math.rad(cmd:view_angles().y)
    local c, s = math.cos(yaw), math.sin(yaw)
    local fwd  = vel.x * c + vel.y * s
    local side = vel.x * s - vel.y * c
    local len  = math.sqrt(fwd * fwd + side * side)
    if len < 1 then return end
    cmd:set_move(-fwd / len * strength * move_scale, -side / len * strength * move_scale)
end)

-- ========== ВЫГРУЗКА ==========
events.on("unload", function()
    release_scout()
    reset_peek()
end)
