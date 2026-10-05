addon.name      = 'drawcull';
addon.author    = 'relliko';
addon.version   = '1.2';
addon.desc      = 'Raises the scene draw distance without zone objects popping in or dropping detail early. Replaces drawdistance.';

require 'common';

local chat     = require 'chat';
local settings = require 'settings';

--[[
* How it works:
*   World and entity draw distance: the client multiplies its far clip, fog and entity cull distance by
*   two floats (world and entity multipliers, 1.0 stock). These are the same floats the drawdistance
*   addon writes; this addon sets them itself, saves them, and puts them back to 1.0 on unload.
*
*   Zone object culling: objects that carry their own view range (buildings, trees, props) are culled
*   with
*     distance^2 > scale * range^2
*   where scale is the world multiplier (times the client's own distance setting). The multiplier is
*   applied to a squared distance, so a world multiplier of 10 only pushes those objects out about
*   3.2x (sqrt(10)) while the far clip and fog move 10x, and they pop in well inside the visible range.
*   The scale is computed once per frame by a call that stores it to [renderer+0x39428]; that call is
*   pointed at a small stub that multiplies the result by the world multiplier once more, so object
*   ranges grow by the multiplier itself. At a multiplier of 1 nothing changes.
*
*   Zone object detail (1.2): each object has three meshes and picks one by comparing its squared
*   distance against two fixed squared thresholds ([obj+0xCC], [obj+0xC8]). Nothing scales those, so
*   trees and props swap to a coarser mesh at the same distance whatever the draw distance is. Each
*   "fld [dist2]; fcomp [obj+thr]" pair is replaced by a call to a stub that multiplies the distance by
*   1 / lod^2 before comparing, which moves both switch points out by the lod multiplier.
*
*   Unloading restores every patched byte. Addresses and the traced code are in
*   research/ffxi-re/client-notes.md ("Draw distance and culling").
--]]

local defaults = T{
    world  = 1.0,
    entity = 1.0,
    lod    = 0,         -- 0 = same as world
};

-- Mesh detail compares: fld dword [esp+d]; fcomp dword [reg+0xCC or 0xC8]
local LOD_PATTERNS = {
    'D9442414D899CC000000',
    'D9442414D899C8000000',
    'D9442458D89FCC000000',
    'D9442458D89FC8000000',
};

local state = T{
    settings = nil,
    world    = 0,       -- address of the world multiplier float
    entity   = 0,       -- address of the entity multiplier float
    mem      = 0,       -- +0 culling stub, +32 lod factor, +48 lod stubs (24 bytes each)
    patches  = T{},     -- { addr, backup }
};

local function msg(s) print(chat.header(addon.name):append(chat.message(s))); end
local function err(s) print(chat.header(addon.name):append(chat.error(s))); end

local function le32(v)
    v = bit.tobit(v);
    return { bit.band(v, 0xFF), bit.band(bit.rshift(v, 8), 0xFF), bit.band(bit.rshift(v, 16), 0xFF), bit.band(bit.rshift(v, 24), 0xFF) };
end

local function write_bytes(addr, bytes)
    local ok, prot = ashita.memory.unprotect(addr, #bytes);
    if (not ok) then return false; end
    ashita.memory.write_array(addr, bytes);
    ashita.memory.protect(addr, #bytes, prot);
    return true;
end

-- Writes bytes at addr, remembering the originals for unload.
local function patch(addr, bytes)
    local backup = ashita.memory.read_array(addr, #bytes);
    if (not write_bytes(addr, bytes)) then return false; end
    state.patches:append({ addr = addr, backup = backup });
    return true;
end

local function lod_value()
    local s = state.settings;
    local l = (s.lod ~= nil and s.lod > 0) and s.lod or s.world;
    return math.max(l, 1.0);
end

local function apply()
    if (state.world == 0 or state.settings == nil) then return; end
    ashita.memory.write_float(state.world, state.settings.world);
    ashita.memory.write_float(state.entity, state.settings.entity);
    if (state.mem ~= 0) then
        local l = lod_value();
        ashita.memory.write_float(state.mem + 32, 1.0 / (l * l));
    end
end

local function patch_culling()
    -- mov ecx, [cam]; fstp st(0); call <scale>; fstp dword [ebp+0x39428]
    local p = ashita.memory.find(0, 0, '8B0D????????DDD8E8????????D99D28940300', 0, 0);
    if (p == 0) then
        err('Could not find the object culling code; zone objects will still pop in early.');
        return;
    end
    local site = p + 8;
    local target = bit.tobit(site + 5 + ashita.memory.read_int32(site + 1));

    -- push dword [esp+4]; call <scale>; fmul dword [world]; ret 4
    local stub = state.mem;
    local rel = le32(target - (stub + 9));
    local w = le32(state.world);
    ashita.memory.write_array(stub, {
        0xFF, 0x74, 0x24, 0x04,
        0xE8, rel[1], rel[2], rel[3], rel[4],
        0xD8, 0x0D, w[1], w[2], w[3], w[4],
        0xC2, 0x04, 0x00,
    });
    if (not patch(site + 1, le32(stub - (site + 5)))) then
        err('Could not patch the object culling call; zone objects will still pop in early.');
    end
end

local function patch_lod()
    local k = le32(state.mem + 32);
    local missing = 0;
    for i, pat in ipairs(LOD_PATTERNS) do
        local site = ashita.memory.find(0, 0, pat, 0, 0);
        if (site == 0) then
            missing = missing + 1;
        else
            -- fld dword [esp+d+4]; fmul dword [k]; fcomp dword [reg+thr]; ret
            -- (+4: the call pushed a return address)
            local o = ashita.memory.read_array(site, 10);
            local stub = state.mem + 48 + (i - 1) * 24;
            ashita.memory.write_array(stub, {
                0xD9, 0x44, 0x24, o[4] + 4,
                0xD8, 0x0D, k[1], k[2], k[3], k[4],
                o[5], o[6], o[7], o[8], o[9], o[10],
                0xC3,
            });
            local rel = le32(stub - (site + 5));
            if (not patch(site, { 0xE8, rel[1], rel[2], rel[3], rel[4], 0x90, 0x90, 0x90, 0x90, 0x90 })) then
                missing = missing + 1;
            end
        end
    end
    if (missing > 0) then
        err(('%d of %d mesh detail sites not patched; some objects will still drop detail early.'):fmt(missing, #LOD_PATTERNS));
    end
end

ashita.events.register('load', 'load_cb', function ()
    -- fld [cfg]; ...; fmul [world] / fmul [entity] inside the client's distance scale function.
    local p = ashita.memory.find(0, 0, '8BC1487408D80D', 0, 0);
    if (p == 0) then
        err('Could not find the draw distance values; not loading.');
        return;
    end
    state.world = ashita.memory.read_uint32(p + 0x07);
    state.entity = ashita.memory.read_uint32(p + 0x0F);
    state.settings = settings.load(defaults);

    state.mem = ashita.memory.alloc(160);
    if (state.mem == nil or state.mem == 0) then
        state.mem = 0;
        err('Could not allocate memory; only the draw distance values are applied.');
    else
        ashita.memory.unprotect(state.mem, 160);
        ashita.memory.write_float(state.mem + 32, 1.0);
        patch_culling();
        patch_lod();
    end
    apply();
end);

settings.register('settings', 'drawcull_settings_update', function (s)
    if (s ~= nil) then state.settings = s; end
    apply();
end);

ashita.events.register('unload', 'unload_cb', function ()
    for i = #state.patches, 1, -1 do
        local p = state.patches[i];
        write_bytes(p.addr, p.backup);
    end
    state.patches = T{};
    -- The stubs are left allocated: the render thread may be inside one while we unload.

    if (state.world ~= 0) then
        ashita.memory.write_float(state.world, 1.0);
        ashita.memory.write_float(state.entity, 1.0);
    end
end);

local function show()
    local s = state.settings;
    msg(('world %.2f, entity %.2f, detail %.2f%s'):fmt(s.world, s.entity, lod_value(), (s.lod == nil or s.lod <= 0) and ' (same as world)' or ''));
end

local function print_help()
    msg('/drawcull world <n> - world draw distance multiplier (terrain, objects, fog). 1 = stock.');
    msg('/drawcull entity <n> - entity draw distance multiplier (players, NPCs, mobs). 1 = stock.');
    msg('/drawcull detail <n> - how much further objects keep their detailed mesh. 0 = same as world.');
    msg('/drawcull - shows the current values.');
end

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/drawcull') then return; end
    e.blocked = true;

    if (state.settings == nil) then
        err('Not active (draw distance values not found).');
        return;
    end

    if (#args == 1) then
        show();
        return;
    end

    local n = tonumber(args[3] or '');
    if (#args == 3 and n ~= nil and n > 0 and args[2]:any('world', 'w', 'setworld', 'setw')) then
        state.settings.world = n;
    elseif (#args == 3 and n ~= nil and n > 0 and args[2]:any('entity', 'e', 'mob', 'm', 'setentity', 'sete')) then
        state.settings.entity = n;
    elseif (#args == 3 and n ~= nil and n >= 0 and args[2]:any('detail', 'lod', 'd')) then
        state.settings.lod = n;
    else
        print_help();
        return;
    end
    apply();
    settings.save();
    show();
end);
