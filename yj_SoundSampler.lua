-- @description yj_SoundSampler
-- @author Yeji Jung
-- @version 1.0
-- @about
--   Plays sounds picked in yj_SoundPicker from a MIDI keyboard.
--	 Definitely not inspired by R*****.
--   Eight slots, each with its own key range, root note, in and out points, ADSR envelope, LFO modulation and loop. Each slot is a ReaSamplomatic5000 on one track, so REAPER plays and records it.
--   Requires ReaImGui.

local R = reaper
if not R.ImGui_CreateContext then
  R.MB('yj_SoundSampler needs ReaImGui.\n\nExtensions > ReaPack > Browse packages, search for ReaImGui.',
    'Missing ReaImGui', 0)
  return
end
package.path = R.ImGui_GetBuiltinPath and (R.ImGui_GetBuiltinPath() .. '/?.lua') or package.path
local ok_imgui, ImGui = pcall(function() return require 'imgui' '0.9' end)
if not ok_imgui then
  R.MB('yj_SoundSampler needs ReaImGui 0.9 or newer.\n\nUpdate it in ReaPack, then restart REAPER.',
    'ReaImGui too old', 0)
  return
end

local VERSION = '1.0'
local SLOTS = 8
local EXT = 'yj_SoundSampler'
local PICK_SECTION = 'yj_SoundPicker' -- where SoundPicker publishes the current pick

--- Settings -----------------------------------------------------------------

local S = {
  theme = 'simple', mode = 'dark', font_size = 13, tips = true,
  follow = true,   -- a new pick in SoundPicker drops into the selected slot
  spread = true,   -- keep key ranges tiled across the keyboard
  base = 24,       -- the split covers C1 up to C7, so one slot alone answers
  top = 96,        -- to most of the keyboard instead of a single octave
}

local function load_settings()
  for k, v in pairs(S) do
    local raw = R.GetExtState(EXT, k)
    if raw ~= '' then
      if type(v) == 'boolean' then S[k] = raw == '1'
      elseif type(v) == 'number' then S[k] = tonumber(raw) or v
      else S[k] = raw end
    end
  end
  -- theme follows soundpicker
  for _, k in ipairs({ 'theme', 'mode', 'font_size', 'tips' }) do
    local raw = R.GetExtState(PICK_SECTION, k)
    if raw ~= '' then
      if type(S[k]) == 'number' then S[k] = tonumber(raw) or S[k]
      elseif type(S[k]) == 'boolean' then S[k] = raw == '1' or raw == 'true'
      else S[k] = raw end
    end
  end
end

local function save_settings()
  for k, v in pairs(S) do
    local raw = (type(v) == 'boolean') and (v and '1' or '0') or tostring(v)
    R.SetExtState(EXT, k, raw, true)
  end
end

--- Slots --------------------------------------------------------------------

-- One ReaSamplomatic5000 per slot.
local slots = {}
for i = 1, SLOTS do
  slots[i] = {
    path = nil, name = '', len = 0,
    root = 60, lo = 60, hi = 60,
    st = 0, en = 1,
    gain = 0, pan = 0,      
    att = 0, dec = 0, sus = 1, rel = 0.008,
    loop = false, pitched = true,
    flat_vel = true,
    -- one LFO per target
    lfos = { { sh = 0, spd = 0.25, str = 0.3 }, { sh = 0, spd = 0.25, str = 0.3 },
             { sh = 0, spd = 0.25, str = 0.3 } },
    lfo_tab = 1,
    mute = false, solo = false,
    fx = nil,                -- index of this slot's RS5k on the track
  }
end
local sel = 1

local function used(sl) return sl.path ~= nil end

local function any_solo()
  for i = 1, SLOTS do if slots[i].solo then return true end end
  return false
end

--- The track ----------------------------------------------------------------

local track = nil

local function track_valid()
  return track and R.ValidatePtr2(0, track, 'MediaTrack*')
end

-- The marker survives save and load
local function find_track()
  for i = 0, R.CountTracks(0) - 1 do
    local tr = R.GetTrack(0, i)
    local _, v = R.GetSetMediaTrackInfo_String(tr, 'P_EXT:yj_sampler', '', false)
    if v == '1' then return tr end
  end
end

local function make_track()
  local n = R.CountTracks(0)
  R.InsertTrackAtIndex(n, true)
  local tr = R.GetTrack(0, n)
  R.GetSetMediaTrackInfo_String(tr, 'P_NAME', 'yj_SoundSampler', true)
  R.GetSetMediaTrackInfo_String(tr, 'P_EXT:yj_sampler', '1', true)
  -- every MIDI device, every channel, armed and monitoring, so a keyboard just works
  R.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', 4096 | (63 << 5))
  R.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
  R.SetMediaTrackInfo_Value(tr, 'I_RECMON', 1)
  R.SetMediaTrackInfo_Value(tr, 'I_RECMODE', 0)
  return tr
end

--- RS5k ---------------------------------------------------------------------

-- RS5k's parameter numbers are undocumented and have moved between REAPER versions, so each is looked up by name once per instance.
local pcache = {}
local capture_defaults

local function params_of(tr, fx)
  local key = tostring(R.TrackFX_GetFXGUID(tr, fx) or fx)
  local p = pcache[key]
  if p then return p end
  p = { names = {} }
  for i = 0, R.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, nm = R.TrackFX_GetParamName(tr, fx, i)
    nm = (nm or ''):lower()
    p[nm] = i
    p.names[#p.names + 1] = nm -- kept in plugin order: pairs() has none
  end
  pcache[key] = p
  return p
end

local function pindex(p, ...)
  for _, want in ipairs({ ... }) do
    if p[want] then return p[want] end
  end
  for _, want in ipairs({ ... }) do
    for _, nm in ipairs(p.names) do
      if nm:find(want, 1, true) then return p[nm] end
    end
  end
end

-- Writes a parameter in its own units and returns where that sits in its range
local function set_p(tr, fx, idx, value)
  if not idx then return nil end
  local _, mn, mx = R.TrackFX_GetParam(tr, fx, idx)
  if not mn or mx == mn then return nil end
  local v = math.max(mn, math.min(value, mx))
  R.TrackFX_SetParam(tr, fx, idx, v)
  return (v - mn) / (mx - mn)
end

-- 0..1 across the parameter's own range, for the ones measured in odd units.
local function set_n(tr, fx, idx, frac)
  if not idx then return false end
  R.TrackFX_SetParamNormalized(tr, fx, idx, math.max(0, math.min(frac, 1)))
  return true
end

-- RS5k renames itself after the sample it loads, so its display name proves nothing.
local function is_rs5k(tr, fx)
  local ok, nm = R.TrackFX_GetNamedConfigParm(tr, fx, 'original_name')
  if ok and nm ~= '' then return nm:lower():find('samplomatic') ~= nil end
  local _, disp = R.TrackFX_GetFXName(tr, fx)
  if (disp or ''):lower():find('samplomatic') then return true end
  return (R.TrackFX_GetNamedConfigParm(tr, fx, 'FILE0')) == true
end

-- Tagged on the track, so a reopen finds it however REAPER has renamed it.
local function remember(i)
  if not track_valid() then return end
  local sl = slots[i]
  -- centre and unity ride along, so a reopen does not read gain as the new zero
  local tag = sl.fx and ('%s|%s|%s'):format(R.TrackFX_GetFXGUID(track, sl.fx) or '',
    tostring(sl.pan0 or ''), tostring(sl.vol0 or '')) or ''
  R.GetSetMediaTrackInfo_String(track, 'P_EXT:yj_slot' .. i, tag, true)
end

local function fx_by_guid(guid)
  if not guid or guid == '' then return nil end
  for fx = 0, R.TrackFX_GetCount(track) - 1 do
    if R.TrackFX_GetFXGUID(track, fx) == guid then return fx end
  end
end

local function add_rs5k(tr)
  local fx = R.TrackFX_AddByName(tr, 'ReaSamplomatic5000', false, -1)
  if fx < 0 then
    fx = R.TrackFX_AddByName(tr, 'ReaSamplomatic5000 (Cockos)', false, -1)
  end
  return fx >= 0 and fx or nil
end

-- REAPER modulates parameters itself, so the LFOs run in its engine: sample
-- accurate, and still running with this window closed.
local function lfo_targets(p, which)
  if which == 0 then return { pindex(p, 'volume', 'gain') } end
  if which == 1 then return { pindex(p, 'pan') } end
  -- both ends move together, or the key mapping bends as the LFO sweeps
  return { pindex(p, 'pitch for start note', 'pitch@start'),
           pindex(p, 'pitch for end note', 'pitch@end') }
end

local function set_mod(fx, idx, on, sl, baseline, strength, L)
  if not idx then return end
  local pre = ('param.%d.'):format(idx)
  local function put(k, v) R.TrackFX_SetNamedConfigParm(track, fx, pre .. k, tostring(v)) end
  if not on then
    put('lfo.active', 0)
    put('mod.active', 0)
    return
  end
  put('mod.active', 1)
  -- the value the slot asked for, never one read back while modulation runs
  put('mod.baseline', baseline or R.TrackFX_GetParamNormalized(track, fx, idx))
  put('lfo.active', 1)
  put('lfo.shape', L.sh)
  put('lfo.speed', L.spd)
  put('lfo.strength', strength)
  put('lfo.temposync', L.sync and 1 or 0)
  put('lfo.dir', 0)
  put('lfo.free', 0)
end

-- Pitch runs over -80..80 semitones, so a raw depth would swing six octaves.
local DEPTH_SCALE = { 1, 1, 0.075 }

local function push_lfo(i)
  if not track_valid() then return end
  local sl = slots[i]
  if not sl.fx or not R.TrackFX_GetFXGUID(track, sl.fx) then return end
  local p = params_of(track, sl.fx)
  for which = 1, 3 do
    local L = sl.lfos[which]
    L.bound, L.taken = nil, nil
    local names = {}
    for _, idx in ipairs(lfo_targets(p, which - 1)) do
      set_mod(sl.fx, idx, L.on, sl, sl.base and sl.base[idx], L.str * DEPTH_SCALE[which], L)
      names[#names + 1] = p.names[idx + 1] or ('#' .. idx)
      if L.on then
        local ok, got = R.TrackFX_GetNamedConfigParm(track, sl.fx, ('param.%d.lfo.active'):format(idx))
        L.taken = (ok and got == '1') or false
      end
    end
    L.bound = (#names > 0) and table.concat(names, ' + ') or false
  end
end

local function push_slot(i)
  if not track_valid() then return end
  local sl = slots[i]
  if not sl.fx or not R.TrackFX_GetFXGUID(track, sl.fx) then return end
  local fx, p = sl.fx, params_of(track, sl.fx)
  sl.base = {} -- each parameter's own centre, for the LFO to swing around

  set_n(track, fx, pindex(p, 'note range start'), sl.lo / 127)
  set_n(track, fx, pindex(p, 'note range end'), sl.hi / 127)
  -- RS5k pitches from the bottom of the range, so the root sets the offset
  local semis = sl.pitched and (sl.root - sl.lo) or 0
  -- each pitch parameter keeps its own centre
  local pit = pindex(p, 'pitch for start note', 'pitch@start')
  local pit2 = pindex(p, 'pitch for end note', 'pitch@end')
  if pit then sl.base[pit] = set_p(track, fx, pit, -semis) end
  if pit2 then
    sl.base[pit2] = set_p(track, fx, pit2, sl.pitched and (sl.hi - sl.lo - semis) or 0)
  end
  set_n(track, fx, pindex(p, 'sample start offset', 'start offset'), sl.st)
  set_n(track, fx, pindex(p, 'sample end offset', 'end offset'), sl.en)
  -- relative to what the plugin started with, so 0 dB is its unity and 0 its
  -- centre, whatever scale this build of RS5k reports
  local vidx = pindex(p, 'volume', 'gain')
  if vidx then sl.base[vidx] = set_p(track, fx, vidx, (sl.vol0 or 1) * 10 ^ (sl.gain / 20)) end
  local pidx = pindex(p, 'pan')
  if pidx then
    local c = sl.pan0 or 0.5
    local want = (sl.pan < 0) and (c * (1 + sl.pan)) or (c + (1 - c) * sl.pan)
    set_n(track, fx, pidx, want)
    sl.base[pidx] = want
  end
  -- the quietest key gets the same gain as the hardest
  local midv = pindex(p, 'gain for minimum velocity', 'minimum velocity', 'min vel')
  if midv and vidx then
    local full = (R.TrackFX_GetParam(track, fx, vidx))
    if sl.flat_vel then
      set_p(track, fx, midv, full or 1)
    elseif sl.vel0 then
      set_p(track, fx, midv, sl.vel0)
    end
  end
  set_p(track, fx, pindex(p, 'attack'), sl.att)
  set_p(track, fx, pindex(p, 'decay'), sl.dec)
  set_p(track, fx, pindex(p, 'sustain'), sl.sus)
  set_p(track, fx, pindex(p, 'release'), sl.rel)
  set_n(track, fx, pindex(p, 'loop'), sl.loop and 1 or 0)

  local off = sl.mute or (any_solo() and not sl.solo)
  R.TrackFX_SetEnabled(track, fx, not off)
  push_lfo(i)
end

local function push_all()
  for i = 1, SLOTS do push_slot(i) end
end

-- Builds the track and one plugin per filled slot, reusing what is there.
local function sync(force)
  if not track_valid() then track = find_track() end
  local filled = false
  for i = 1, SLOTS do if used(slots[i]) then filled = true end end
  if not filled and not track_valid() then return end
  if not track_valid() then track = make_track() end
  R.PreventUIRefresh(1)
  for i = 1, SLOTS do
    local sl = slots[i]
    -- the plugin may be gone: a rebuilt track, or one deleted by hand
    if sl.fx and not R.TrackFX_GetFXGUID(track, sl.fx) then
      sl.fx, sl.fresh, sl.pan0, sl.vol0 = nil, true, nil, nil
    end
    if used(sl) then
      if not sl.fx then
        sl.fx = add_rs5k(track)
        sl.fresh = true
        if sl.fx then capture_defaults(sl) end
      end
      -- a slot keeps one plugin for life and reloads it, rather than stacking
      if sl.fx and (sl.fresh or force) then
        -- clearing first, or a slot that already held a sound keeps it
        R.TrackFX_SetNamedConfigParm(track, sl.fx, '-FILE*', '')
        R.TrackFX_SetNamedConfigParm(track, sl.fx, 'FILE0', sl.path)
        R.TrackFX_SetNamedConfigParm(track, sl.fx, 'DONE', '')
        R.TrackFX_SetNamedConfigParm(track, sl.fx, 'RSMODE', '0') -- no time stretch
        R.TrackFX_SetOpen(track, sl.fx, false)
        sl.fresh = false
        remember(i)
      end
      push_slot(i)
    elseif sl.fx then
      local gone = sl.fx
      R.TrackFX_Delete(track, gone)
      sl.fx = nil
      for j = 1, SLOTS do -- only the ones after it shuffle down
        if slots[j].fx and slots[j].fx > gone then slots[j].fx = slots[j].fx - 1 end
      end
    end
  end
  R.PreventUIRefresh(-1)
  R.TrackList_AdjustWindows(false)
end

-- What each control looks for, in the order the Plugin map lists them.
local PMAP = {
  { 'gain', 'volume', 'gain' }, { 'pan', 'pan' },
  { 'min vel', 'gain for minimum velocity', 'minimum velocity', 'min vel' },
  { 'note lo', 'note range start' }, { 'note hi', 'note range end' },
  { 'pitch lo', 'pitch for start note', 'pitch@start' },
  { 'pitch hi', 'pitch for end note', 'pitch@end' },
  { 'in', 'sample start offset', 'start offset' },
  { 'out', 'sample end offset', 'end offset' },
  { 'attack', 'attack' }, { 'decay', 'decay' },
  { 'sustain', 'sustain' }, { 'release', 'release' }, { 'loop', 'loop' },
}

-- The gain and pan a fresh plugin came with, read before the slot writes any.
function capture_defaults(sl)
  if not sl.fx or not track_valid() then return end
  local p = params_of(track, sl.fx)
  -- with modulation off: a modulated reading would become the new unity
  for _, nm in ipairs({ 'pan', 'volume', 'gain' }) do
    local idx = p[nm]
    if idx then
      R.TrackFX_SetNamedConfigParm(track, sl.fx, ('param.%d.lfo.active'):format(idx), '0')
      R.TrackFX_SetNamedConfigParm(track, sl.fx, ('param.%d.mod.active'):format(idx), '0')
    end
  end
  local pidx = pindex(p, 'pan')
  if pidx then sl.pan0 = R.TrackFX_GetParamNormalized(track, sl.fx, pidx) end
  local vidx = pindex(p, 'volume', 'gain')
  if vidx then sl.vol0 = (R.TrackFX_GetParam(track, sl.fx, vidx)) end
  if not sl.vol0 or sl.vol0 <= 0 then sl.vol0 = 1 end
  local midv = pindex(p, 'gain for minimum velocity', 'minimum velocity', 'min vel')
  if midv then sl.vel0 = (R.TrackFX_GetParam(track, sl.fx, midv)) end
end

-- Reads a plugin back into its slot, so the window shows what is really set.
local function pull_slot(i)
  local sl = slots[i]
  if not sl.fx or not track_valid() then return end
  local fx, p = sl.fx, params_of(track, sl.fx)
  local function gn(idx) return idx and R.TrackFX_GetParamNormalized(track, fx, idx) or nil end
  local function gp(idx) return idx and (R.TrackFX_GetParam(track, fx, idx)) or nil end
  sl.lo = math.floor((gn(pindex(p, 'note range start')) or 0) * 127 + 0.5)
  sl.hi = math.floor((gn(pindex(p, 'note range end')) or 1) * 127 + 0.5)
  local ps = gp(pindex(p, 'pitch for start note', 'pitch@start')) or 0
  local pe = gp(pindex(p, 'pitch for end note', 'pitch@end')) or 0
  sl.root = math.max(0, math.min(sl.lo - math.floor(ps + 0.5), 127))
  sl.pitched = pe ~= ps
  sl.st = gn(pindex(p, 'sample start offset', 'start offset')) or 0
  sl.en = gn(pindex(p, 'sample end offset', 'end offset')) or 1
  local vol = gp(pindex(p, 'volume', 'gain'))
  sl.gain = (vol and vol > 0) and (20 * math.log(vol / (sl.vol0 or 1), 10)) or 0
  local c = sl.pan0 or 0.5
  local pn = gn(pindex(p, 'pan')) or c
  sl.pan = (pn < c) and ((c > 0) and (pn / c - 1) or 0)
    or ((c < 1) and ((pn - c) / (1 - c)) or 0)
  sl.att = gp(pindex(p, 'attack')) or 0
  sl.dec = gp(pindex(p, 'decay')) or 0
  sl.sus = gp(pindex(p, 'sustain')) or 1
  sl.rel = gp(pindex(p, 'release')) or 0.008
  sl.loop = (gn(pindex(p, 'loop')) or 0) > 0.5
end

--- Loading a sound ----------------------------------------------------------

local function source_len(path)
  local src = R.PCM_Source_CreateFromFile(path)
  if not src then return 0 end
  local len = R.GetMediaSourceLength(src)
  R.PCM_Source_Destroy(src)
  return len or 0
end

-- Filled slots share the span evenly; each root sits mid band.
local function tile_ranges()
  if not S.spread then return end
  local n = 0
  for i = 1, SLOTS do if used(slots[i]) then n = n + 1 end end
  if n == 0 then return end
  local lo_k = math.max(0, math.min(S.base, S.top))
  local hi_k = math.min(127, math.max(S.base, S.top))
  local width = (hi_k - lo_k + 1) / n
  local k = 0
  for i = 1, SLOTS do
    local sl = slots[i]
    if used(sl) then
      sl.lo = math.floor(lo_k + k * width + 0.5)
      sl.hi = (k == n - 1) and hi_k or math.max(sl.lo, math.floor(lo_k + (k + 1) * width - 0.5))
      sl.root = math.floor((sl.lo + sl.hi) / 2)
      k = k + 1
    end
  end
end

local function load_into(i, path, st, en)
  local sl = slots[i]
  sl.path = path
  sl.name = path:match('[^\\/]+$') or path
  sl.len = source_len(path)
  sl.st = (st and sl.len > 0) and math.max(0, math.min(st / sl.len, 1)) or 0
  sl.en = (en and sl.len > 0) and math.max(sl.st, math.min(en / sl.len, 1)) or 1
  sl.pk = nil -- peaks belong to the old sound
  sl.fresh = true -- the plugin it already owns needs the new file
  tile_ranges()
  sync()
end

local function clear_slot(i)
  local sl = slots[i]
  if sl.fx and track_valid() then
    R.TrackFX_Delete(track, sl.fx)
    for j = 1, SLOTS do
      if slots[j].fx and slots[j].fx > sl.fx then slots[j].fx = slots[j].fx - 1 end
    end
  end
  sl.path, sl.name, sl.len, sl.fx, sl.pk = nil, '', 0, nil, nil
  sl.pan0, sl.vol0 = nil, nil
  remember(i)
  sl.st, sl.en = 0, 1
  tile_ranges()
  sync()
end

-- The counter tells a repeat from a fresh pick, so the same sound reloads.
local last_pick = tonumber(R.GetExtState(PICK_SECTION, 'pick_n')) or 0

local function poll_pick()
  local n = tonumber(R.GetExtState(PICK_SECTION, 'pick_n')) or 0
  if n == last_pick then return end
  last_pick = n
  if not S.follow then return end
  local raw = R.GetExtState(PICK_SECTION, 'pick')
  if raw == '' then return end
  local path, st, en = raw:match('^(.-)\31([^\31]*)\31([^\31]*)')
  if not path or path == '' then return end
  load_into(sel, path, tonumber(st), tonumber(en))
end

--- Note names ---------------------------------------------------------------

local NOTES = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }
local function note_name(n)
  return NOTES[n % 12 + 1] .. tostring(math.floor(n / 12) - 1)
end

--- Look --------------------------------------------------------------------

-- Keyed to whichever theme SoundPicker is set to.
local PAL = {
  simple  = { lt = 0xE8E8E8, dk = 0x2B2B2E, ac = 0x6E8FA8 },
  rose    = { lt = 0xE9D2D2, dk = 0x3A2B2E, ac = 0xB5717F },
  sage    = { lt = 0xD7DCD2, dk = 0x2C332C, ac = 0x7E9478 },
  rainbow = { lt = 0xEDEAE4, dk = 0x2E2E31, ac = 0x8E7BB5 },
}

local T = {}

local function mix(a, b, f)
  local out = 0
  for sh = 16, 0, -8 do
    local ca, cb = (a >> sh) & 255, (b >> sh) & 255
    out = out | (math.floor(ca + (cb - ca) * f + 0.5) << sh)
  end
  return out
end

local function build_theme()
  local p = PAL[S.theme] or PAL.simple
  local dark = S.mode ~= 'light'
  local bg = dark and p.dk or p.lt
  local fg = dark and 0xF0F0F0 or 0x1E1E20
  T.bg, T.panel = (bg << 8) | 0xFF, (mix(bg, fg, 0.07) << 8) | 0xFF
  T.panel_hi = (mix(bg, fg, 0.14) << 8) | 0xFF
  T.text, T.dim = (fg << 8) | 0xFF, (mix(bg, fg, 0.63) << 8) | 0xFF
  T.accent = (p.ac << 8) | 0xFF
  T.accent_dim = (mix(bg, p.ac, 0.45) << 8) | 0xFF
  T.line = (mix(bg, fg, 0.22) << 8) | 0xFF
  T.key_w, T.key_b = 0xDCDCDCFF, 0x2A2A2CFF
end

-- Hover guides follow SoundPicker's setting, gated at the source.
do
  local raw = ImGui.SetTooltip
  ImGui.SetTooltip = function(c, text) if S.tips then raw(c, text) end end
end

local ctx = ImGui.CreateContext('yj_SoundSampler')

-- Shape and colour are taken from SoundPicker so the two windows read as one
-- tool. PopupBg is in the colour list because tooltips use it, and ImGui's
-- default is near black whatever the theme.
local VARS = {}
for _, v in ipairs({
  { 'WindowRounding', 8 }, { 'ChildRounding', 6 }, { 'FrameRounding', 6 },
  { 'PopupRounding', 6 }, { 'ScrollbarRounding', 6 }, { 'GrabRounding', 4 },
  { 'TabRounding', 6 }, { 'WindowPadding', 12, 10 }, { 'FramePadding', 9, 5 },
  { 'ItemSpacing', 8, 7 }, { 'CellPadding', 7, 4 }, { 'FrameBorderSize', 1 },
  { 'WindowBorderSize', 1 }, { 'PopupBorderSize', 1 }, { 'ScrollbarSize', 12 },
  { 'GrabMinSize', 10 },
}) do
  local id = ImGui['StyleVar_' .. v[1]]
  if id then VARS[#VARS + 1] = { id, v[2], v[3] } end
end

local STYLE = {}
for _, m in ipairs({
  { 'Col_WindowBg', 'bg' }, { 'Col_ChildBg', 'panel' }, { 'Col_PopupBg', 'panel' },
  { 'Col_Text', 'text' }, { 'Col_TextDisabled', 'dim' },
  { 'Col_Button', 'panel_hi' }, { 'Col_ButtonHovered', 'accent_dim' }, { 'Col_ButtonActive', 'accent' },
  { 'Col_FrameBg', 'panel_hi' }, { 'Col_FrameBgHovered', 'accent_dim' }, { 'Col_FrameBgActive', 'accent_dim' },
  { 'Col_SliderGrab', 'accent' }, { 'Col_SliderGrabActive', 'accent' },
  { 'Col_CheckMark', 'accent' },
  { 'Col_Header', 'accent_dim' }, { 'Col_HeaderHovered', 'accent_dim' }, { 'Col_HeaderActive', 'accent' },
  { 'Col_Separator', 'line' }, { 'Col_Border', 'line' },
  { 'Col_TitleBg', 'panel' }, { 'Col_TitleBgActive', 'panel_hi' },
}) do
  local c = ImGui[m[1]]
  if c then STYLE[#STYLE + 1] = { c, m[2] } end
end
local font = ImGui.CreateFont('sans-serif', S.font_size)
ImGui.Attach(ctx, font)
local font_made = S.font_size

--- Widgets ------------------------------------------------------------------

local function tip(text)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, text) end
end

-- A small toggle that reads as pressed when on.
local function toggle(label, on, hint, w)
  local n = 0
  if on then
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, T.accent)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, T.accent)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    n = 3
  end
  local hit = ImGui.Button(ctx, label, w or 0, 0)
  ImGui.PopStyleColor(ctx, n)
  if hint then tip(hint) end
  return hit
end

local function ctrl_down() return (ImGui.GetKeyMods(ctx) & ImGui.Mod_Ctrl) ~= 0 end

-- Ctrl+click and right-click reset a control. NoInput keeps the widget from
-- taking the ctrl+click for text entry; the latch holds through the drag.
local reset_pending = {}
local function with_reset(label, changed, v, default)
  if ImGui.IsItemActivated(ctx) and ctrl_down() then reset_pending[label] = true end
  if reset_pending[label] then
    v, changed = default, true
    if not ImGui.IsItemActive(ctx) then reset_pending[label] = nil end
  end
  if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then v, changed = default, true end
  return changed, v
end

-- Drag field for a MIDI note, shown by name rather than number.
local function note_drag(label, value, lo, hi, default)
  ImGui.SetNextItemWidth(ctx, 62)
  local changed, v = ImGui.DragInt(ctx, label, value, 0.2, lo or 0, hi or 127,
    note_name(value), ImGui.SliderFlags_NoInput)
  if default then return with_reset(label, changed, v, default) end
  return changed, v
end

-- Slider that also answers ctrl+click and right-click by going back to default.
local function slider(label, value, lo, hi, fmt, default, width)
  ImGui.SetNextItemWidth(ctx, width or 150)
  local changed, v = ImGui.SliderDouble(ctx, label, value, lo, hi, fmt, ImGui.SliderFlags_NoInput)
  changed, v = with_reset(label, changed, v, default)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, ('%s  (ctrl+click or right-click for %s)'):format(
      label:match('^[^#]*') or label, tostring(default)))
  end
  return changed, v
end

--- Keyboard strip -----------------------------------------------------------

local BLACK = { [1] = true, [3] = true, [6] = true, [8] = true, [10] = true }

local kb_held = nil

-- Into REAPER's virtual keyboard, which the armed sampler track hears.
local function kb_play(note)
  if note == kb_held then return end
  if kb_held then R.StuffMIDIMessage(0, 0x80, kb_held, 0) end
  if note then R.StuffMIDIMessage(0, 0x90, note, 100) end
  kb_held = note
end

-- A real keyboard: white keys across the full width, black keys narrower and
-- shorter on top, with the slot ranges as a band above it.
local function keyboard(w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local lo_n, hi_n = 21, 108
  local band = math.max(6, h * 0.28)
  local ky, kh = y + band + 2, h - band - 2
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.panel)

  local white, wi = {}, {}
  for n = lo_n, hi_n do
    if not BLACK[n % 12] then white[#white + 1] = n; wi[n] = #white end
  end
  local kw = w / #white
  local bw = kw * 0.62

  -- left and right edge of any note, black keys sitting astride a white border
  local function span(n)
    if wi[n] then return x + (wi[n] - 1) * kw, x + wi[n] * kw end
    local below = wi[n - 1] and (n - 1) or (n - 2)
    local edge = x + wi[below] * kw
    return edge - bw / 2, edge + bw / 2
  end

  -- the keybed shows through between the white keys
  ImGui.DrawList_AddRectFilled(dl, x, ky, x + w, ky + kh, T.key_b)
  for i, n in ipairs(white) do
    local kx = x + (i - 1) * kw
    ImGui.DrawList_AddRectFilled(dl, kx + 0.5, ky, kx + kw - 1.2, ky + kh, T.key_w)
    if n % 12 == 0 and kw > 7 then
      ImGui.DrawList_AddText(dl, kx + 1, ky + kh - 12, T.key_b, 'C' .. (n // 12 - 1))
    end
  end
  for n = lo_n, hi_n do
    if BLACK[n % 12] then
      local a, b = span(n)
      ImGui.DrawList_AddRectFilled(dl, a, ky, b, ky + kh * 0.62, T.key_b)
    end
  end

  for i = 1, SLOTS do
    local sl = slots[i]
    if used(sl) then
      local a = (span(math.max(lo_n, sl.lo)))
      local _, b = span(math.min(hi_n, sl.hi))
      local col = (i == sel) and T.accent or T.accent_dim
      ImGui.DrawList_AddRectFilled(dl, a, y + 1, b, y + band, col, 2)
      if sl.root >= lo_n and sl.root <= hi_n then
        local ra, rb = span(sl.root)
        ImGui.DrawList_AddRectFilled(dl, ra, y + 1, rb, y + band, T.text)
      end
    end
  end

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.InvisibleButton(ctx, '##kb', w, h)
  if ImGui.IsItemActive(ctx) then
    local mx, my = ImGui.GetMousePos(ctx)
    local note
    if my < ky + kh * 0.62 then -- black keys sit on top, so they answer first
      for n = lo_n, hi_n do
        if BLACK[n % 12] then
          local a, b = span(n)
          if mx >= a and mx <= b then note = n; break end
        end
      end
    end
    if not note then
      note = white[math.max(1, math.min(math.floor((mx - x) / kw) + 1, #white))]
    end
    kb_play(note)
    if kb_held then
      local a, b = span(kb_held)
      local bh = BLACK[kb_held % 12] and (kh * 0.62) or kh
      ImGui.DrawList_AddRectFilled(dl, a, ky, b, ky + bh, T.accent)
    end
  elseif kb_held then
    kb_play(nil)
  end
end

--- Slot list ----------------------------------------------------------------

-- Cuts a name to the room it has, so a long one cannot push the row wider.
-- Cached per slot: the search costs a handful of text measurements, and the
-- answer only changes when the name or the width does.
local fit_cache = {}
local function fit_text(key, text, room)
  local c = fit_cache[key]
  if c and c.text == text and c.room == room then return c.out end
  local out = text
  if ImGui.CalcTextSize(ctx, text) > room then
    local lo, hi = 0, #text
    while lo < hi do
      local mid = (lo + hi + 1) // 2
      if ImGui.CalcTextSize(ctx, text:sub(1, mid) .. '...') <= room then lo = mid else hi = mid - 1 end
    end
    out = text:sub(1, lo) .. '...'
  end
  fit_cache[key] = { text = text, room = room, out = out }
  return out
end

local function slot_list(w, h)
  if not ImGui.BeginChild(ctx, '##slots', w, h, ImGui.ChildFlags_Border) then return end
  local avail = ImGui.GetContentRegionAvail(ctx)
  -- a button is its label plus the frame padding on both sides
  local padx = 9
  if ImGui.GetStyleVar and ImGui.StyleVar_FramePadding then
    local ok, px = pcall(ImGui.GetStyleVar, ctx, ImGui.StyleVar_FramePadding)
    if ok and px then padx = px end
  end
  local btn = math.ceil(ImGui.CalcTextSize(ctx, 'M') + padx * 2)
  -- a button is taller than plain text, so every row takes that height
  local rowh = ImGui.GetFrameHeight(ctx)
  for i = 1, SLOTS do
    local sl = slots[i]
    ImGui.PushID(ctx, i)
    local keep = used(sl) and (btn * 2 + 14) or 0
    local label = ('%d  %s'):format(i, used(sl) and sl.name or 'empty')
    local x0 = ImGui.GetCursorPosX(ctx)
    if ImGui.Selectable(ctx, fit_text(i, label, avail - keep), i == sel, 0, avail - keep, rowh) then
      -- ctrl+click empties a slot instead of selecting it
      if used(sl) and (ImGui.GetKeyMods(ctx) & ImGui.Mod_Ctrl) ~= 0 then clear_slot(i) else sel = i end
    end
    if used(sl) and ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, ('%s\n%s to %s\nCtrl+click to empty this slot'):format(
        sl.name, note_name(sl.lo), note_name(sl.hi)))
    end
    if used(sl) then
      ImGui.SameLine(ctx, x0 + avail - keep + 6)
      if toggle('S', sl.solo, 'Solo this slot', btn) then sl.solo = not sl.solo; push_all() end
      ImGui.SameLine(ctx, 0, 4)
      if toggle('M', sl.mute, 'Mute this slot', btn) then sl.mute = not sl.mute; push_all() end
    end
    ImGui.PopID(ctx)
  end
  ImGui.EndChild(ctx)
end

--- Waveform -----------------------------------------------------------------

local WAVE_N = 900

-- One mixed-down pair of peak arrays per slot, read once and kept on the slot.
local function peaks_of(sl)
  if sl.pk then return sl.pk end
  if not sl.path then return nil end
  local src = R.PCM_Source_CreateFromFile(sl.path)
  if not src then return nil end
  local len = R.GetMediaSourceLength(src)
  local nch = math.max(1, R.GetMediaSourceNumChannels(src) or 1)
  local buf = R.new_array(WAVE_N * nch * 2)
  local rv = math.floor(R.PCM_Source_GetPeaks(src, WAVE_N / math.max(len, 0.001), 0, nch, WAVE_N, 0, buf))
  R.PCM_Source_Destroy(src)
  local got = rv % 1048576
  if got <= 0 then sl.pk = { n = 0 }; return sl.pk end
  local t = buf.table()
  local hi, lo = {}, {}
  for i = 0, got - 1 do
    local a, b = -1, 1
    for c = 1, nch do
      local mx = t[i * nch + c] or 0
      local mn = t[WAVE_N * nch + i * nch + c] or 0
      if mx > a then a = mx end
      if mn < b then b = mn end
    end
    hi[i + 1], lo[i + 1] = a, b
  end
  sl.pk = { hi = hi, lo = lo, n = got }
  return sl.pk
end

-- The waveform with the slot's in and out points. Drag an edge to move it, drag
-- across the middle for a new range, double-click for the whole file.
local function wave_edit(sl, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.panel_hi, 3)
  local pk = peaks_of(sl)
  local mid = y + h / 2
  local ax, bx = x + sl.st * w, x + sl.en * w
  -- the kept range sits on a tint of the accent
  ImGui.DrawList_AddRectFilled(dl, ax, y, bx, y + h, (T.accent & 0xFFFFFF00) | 0x33)
  if pk and pk.n > 0 then
    local amp = h / 2 - 2
    for col = 0, math.floor(w) - 1 do
      local i = math.floor(col / w * pk.n) + 1
      local a, b = (pk.hi[i] or 0) * amp, (pk.lo[i] or 0) * amp
      local t1, b1 = mid - a, mid - b
      if b1 - t1 < 1 then b1 = t1 + 1 end
      ImGui.DrawList_AddRectFilled(dl, x + col, t1, x + col + 1, b1, T.text)
    end
  else
    ImGui.DrawList_AddLine(dl, x, mid, x + w, mid, T.dim)
  end
  -- washed toward the panel, which fades it in a light theme as well as a dark
  local veil = (T.panel & 0xFFFFFF00) | 0xC4
  ImGui.DrawList_AddRectFilled(dl, x, y, ax, y + h, veil)
  ImGui.DrawList_AddRectFilled(dl, bx, y, x + w, y + h, veil)
  ImGui.DrawList_AddLine(dl, ax, y, ax, y + h, T.accent, 2)
  ImGui.DrawList_AddLine(dl, bx, y, bx, y + h, T.accent, 2)

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.InvisibleButton(ctx, '##wave', w, h)
  local hot = ImGui.IsItemHovered(ctx)
  if hot or ImGui.IsItemActive(ctx) then
    local mx = ImGui.GetMousePos(ctx)
    local f = math.max(0, math.min((mx - x) / w, 1))
    if ImGui.IsItemClicked(ctx) then
      local grab = 8 / w
      sl.drag = (math.abs(f - sl.st) < grab and 'a')
        or (math.abs(f - sl.en) < grab and 'b') or 'new'
      -- anchored where it started, so it drags either way
      if sl.drag == 'new' then sl.anchor, sl.st, sl.en = f, f, f end
    end
    if ImGui.IsItemActive(ctx) and sl.drag then
      if sl.drag == 'a' then sl.st = math.min(f, sl.en)
      elseif sl.drag == 'b' then sl.en = math.max(f, sl.st)
      else sl.st, sl.en = math.min(sl.anchor, f), math.max(sl.anchor, f) end
      push_slot(sel)
    end
  end
  if not ImGui.IsItemActive(ctx) then sl.drag = nil end
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    sl.st, sl.en = 0, 1
    push_slot(sel)
  end
  if hot then
    ImGui.SetTooltip(ctx, 'Drag an edge to move it, drag across for a new range,\ndouble-click for the whole file')
  end
end

--- Envelope and LFO drawings ------------------------------------------------

-- Attack up, decay to the sustain level, a held stretch, then release. The
-- three corners drag.
local ENV_HOLD = 0.9 -- the stretch a held key adds, in the same units as the times

local function adsr_graph(sl, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.panel_hi, 4)
  local top, bot = y + 7, y + h - 7
  for i = 1, 3 do
    local gy = top + (bot - top) * i / 4
    ImGui.DrawList_AddLine(dl, x + 2, gy, x + w - 2, gy, (T.line & 0xFFFFFF00) | 0x60)
  end
  -- Idle, the axis is the envelope's own length. It freezes during a drag so
  -- the curve cannot slide under the mouse, and grows only past the right edge.
  local span = sl.env_span or math.max(0.6, sl.att + sl.dec + ENV_HOLD + sl.rel)
  local function px(t)
    return math.max(x + 5, math.min(x + 5 + (w - 10) * (t / span), x + w - 5))
  end
  local function py(v) return bot - (bot - top) * math.max(0, math.min(v, 1)) end
  local function time_at(mx) return math.max(0, (mx - x - 5) / (w - 10) * span) end
  local ax, dx = px(sl.att), px(sl.att + sl.dec)
  local hx, rx = px(sl.att + sl.dec + ENV_HOLD), px(sl.att + sl.dec + ENV_HOLD + sl.rel)
  local sy = py(sl.sus)

  ImGui.DrawList_PathClear(dl)
  ImGui.DrawList_PathLineTo(dl, px(0), py(0))
  ImGui.DrawList_PathLineTo(dl, ax, py(1))
  ImGui.DrawList_PathLineTo(dl, dx, sy)
  ImGui.DrawList_PathLineTo(dl, hx, sy)
  ImGui.DrawList_PathLineTo(dl, rx, py(0))
  ImGui.DrawList_PathStroke(dl, T.accent, 0, 2)
  ImGui.DrawList_AddLine(dl, hx, top, hx, bot, (T.text & 0xFFFFFF00) | 0x40)

  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.InvisibleButton(ctx, '##adsr', w, h)
  local handles = { { 'a', ax, py(1) }, { 'd', dx, sy }, { 'r', rx, py(0) } }
  local mx, my = ImGui.GetMousePos(ctx)
  if ImGui.IsItemClicked(ctx) then
    local best, bd = nil, 1e9
    for _, hd in ipairs(handles) do
      local dd = (hd[2] - mx) ^ 2 + (hd[3] - my) ^ 2
      if dd < bd then best, bd = hd[1], dd end
    end
    sl.env_drag, sl.env_span = best, span
  end
  if ImGui.IsItemActive(ctx) and sl.env_drag then
    local right = x + w - 5
    if mx > right then sl.env_span = span * 1.04 end -- pushing past the edge zooms out
    local t = time_at(math.max(x + 5, math.min(mx, right)))
    if sl.env_drag == 'a' then
      sl.att = math.min(t, 4)
    elseif sl.env_drag == 'd' then
      sl.dec = math.max(0, math.min(t - sl.att, 4))
      sl.sus = math.max(0, math.min((bot - my) / (bot - top), 1))
    else
      sl.rel = math.max(0, math.min(t - sl.att - sl.dec - ENV_HOLD, 8))
    end
    push_slot(sel)
  elseif not ImGui.IsItemActive(ctx) then
    -- the frozen axis goes with the drag
    sl.env_drag, sl.env_span = nil, nil
  end

  local hot = ImGui.IsItemHovered(ctx)
  for _, hd in ipairs(handles) do
    local near = hot and math.abs(hd[2] - mx) < 9
    ImGui.DrawList_AddCircleFilled(dl, hd[2], hd[3], (sl.env_drag == hd[1] or near) and 5 or 3.5, T.text)
  end
  if hot then
    ImGui.SetTooltip(ctx, ('attack %.2fs, decay %.2fs, sustain %d%%, release %.2fs\ndrag a point to change it')
      :format(sl.att, sl.dec, math.floor(sl.sus * 100 + 0.5), sl.rel))
  end
end

local LFO_SHAPES = { 'Sine', 'Square', 'Saw down', 'Saw up', 'Triangle', 'Random' }

-- Two cycles of whatever shape is selected, at the chosen depth.
local function lfo_graph(sl, L, w, h)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.panel_hi, 4)
  local mid, amp = y + h / 2, (h / 2 - 5) * (L.on and math.max(L.str, 0.04) or 0.04)
  ImGui.DrawList_AddLine(dl, x + 2, mid, x + w - 2, mid, (T.line & 0xFFFFFF00) | 0x80)
  local cycles = 1 + L.spd * 5
  local col = L.on and T.accent or T.dim
  ImGui.DrawList_PathClear(dl)
  local steps = math.max(24, math.floor(w / 2))
  for i = 0, steps do
    local u = i / steps
    local ph = (u * cycles) % 1
    local v
    local sh = L.sh
    if sh == 0 then v = math.sin(ph * math.pi * 2)
    elseif sh == 1 then v = (ph < 0.5) and 1 or -1
    elseif sh == 2 then v = 1 - ph * 2
    elseif sh == 3 then v = ph * 2 - 1
    elseif sh == 4 then v = (ph < 0.5) and (ph * 4 - 1) or (3 - ph * 4)
    else v = math.sin(math.floor(ph * 8) * 12.9898) end
    ImGui.DrawList_PathLineTo(dl, x + 4 + (w - 8) * u, mid - v * amp)
  end
  ImGui.DrawList_PathStroke(dl, col, 0, 2)
  ImGui.Dummy(ctx, w, h)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, ('%s%s'):format(LFO_SHAPES[L.sh + 1] or '?', L.on and '' or '  (off)'))
  end
end

--- Slot editor --------------------------------------------------------------

local function slot_editor(w, h)
  if not ImGui.BeginChild(ctx, '##edit', w, h, ImGui.ChildFlags_Border) then return end
  local sl = slots[sel]
  if not used(sl) then
    ImGui.TextDisabled(ctx, 'Slot ' .. sel .. ' is empty.')
    ImGui.TextDisabled(ctx, 'Pick a sound in SoundPicker, or drop a file on this window.')
    ImGui.EndChild(ctx)
    return
  end
  local c, v
  ImGui.Text(ctx, sl.name)
  ImGui.TextDisabled(ctx, ('%.2f s'):format(sl.len))

  ImGui.SeparatorText(ctx, 'Keys')
  c, v = note_drag('Root##root', sl.root, 0, 127, math.floor((sl.lo + sl.hi) / 2))
  if c then sl.root = v; push_slot(sel) end
  tip('The key that plays the sound at its own pitch.\nCtrl+click or right-click centres it in the range.')
  ImGui.SameLine(ctx)
  c, v = note_drag('Low##lo', sl.lo, 0, 127)
  if c then sl.lo = math.min(v, sl.hi); push_slot(sel) end
  ImGui.SameLine(ctx)
  c, v = note_drag('High##hi', sl.hi, 0, 127)
  if c then sl.hi = math.max(v, sl.lo); push_slot(sel) end
  ImGui.SameLine(ctx)
  c, v = ImGui.Checkbox(ctx, 'Follow the keyboard', sl.pitched)
  if c then sl.pitched = v; push_slot(sel) end
  tip('Off: every key plays the sound at its own pitch, like a one-shot pad')
  ImGui.SameLine(ctx)
  c, v = ImGui.Checkbox(ctx, 'Ignore velocity', sl.flat_vel)
  if c then sl.flat_vel = v; push_slot(sel) end
  tip('On: however hard you play, the sound comes out at full level')

  ImGui.SeparatorText(ctx, 'Sound')
  local ww = math.max(120, ImGui.GetContentRegionAvail(ctx) - 8)
  wave_edit(sl, ww, 70) -- its own hit area already takes the space
  ImGui.TextDisabled(ctx, ('in %.2f s   out %.2f s   (%.2f s)'):format(
    sl.st * sl.len, sl.en * sl.len, (sl.en - sl.st) * sl.len))
  c, v = slider('Gain dB##g', sl.gain, -24, 12, '%.1f', 0)
  if c then sl.gain = v; push_slot(sel) end
  ImGui.SameLine(ctx)
  c, v = slider('Pan##p', sl.pan, -1, 1, '%.2f', 0)
  if c then sl.pan = v; push_slot(sel) end
  ImGui.SameLine(ctx)
  c, v = ImGui.Checkbox(ctx, 'Loop', sl.loop)
  if c then sl.loop = v; push_slot(sel) end

  ImGui.SeparatorText(ctx, 'Envelope')
  adsr_graph(sl, ww, 64)
  for _, e in ipairs({ { 'Attack', 'att', 0, 4, 0 }, { 'Decay', 'dec', 0, 4, 0 },
                       { 'Sustain', 'sus', 0, 1, 1 }, { 'Release', 'rel', 0, 8, 0.008 } }) do
    c, v = slider(e[1] .. '##' .. e[2], sl[e[2]], e[3], e[4], '%.3f', e[5])
    if c then sl[e[2]] = v; push_slot(sel) end
    if e[2] == 'att' or e[2] == 'sus' then ImGui.SameLine(ctx) end
  end

  ImGui.SeparatorText(ctx, 'LFO')
  local TARGETS = { 'Volume', 'Pan', 'Pitch' }
  for n = 1, 3 do
    local L = sl.lfos[n]
    ImGui.PushID(ctx, 100 + n)
    if toggle(TARGETS[n], sl.lfo_tab == n, nil, 62) then sl.lfo_tab = n end
    ImGui.SameLine(ctx, 0, 4)
    c, v = ImGui.Checkbox(ctx, '##on', L.on or false)
    if c then L.on = v; sl.lfo_tab = n; push_lfo(sel) end
    tip('Run an LFO on this slot\'s ' .. TARGETS[n]:lower())
    if L.on then
      ImGui.SameLine(ctx)
      if L.taken == false then
        ImGui.TextColored(ctx, 0xE0A040FF, 'REAPER did not take it')
      elseif L.bound == false then
        ImGui.TextColored(ctx, 0xE06C6CFF, 'no such control here')
      else
        ImGui.TextDisabled(ctx, '-> ' .. (L.bound or '?'))
      end
    end
    ImGui.PopID(ctx)
    if n < 3 then ImGui.SameLine(ctx, 0, 14) end
  end

  local L = sl.lfos[sl.lfo_tab]
  ImGui.SetNextItemWidth(ctx, 110)
  c, v = ImGui.Combo(ctx, '##shape', L.sh, 'Sine\0Square\0Saw down\0Saw up\0Triangle\0Random\0')
  if c then L.sh = v; push_lfo(sel) end
  tip(TARGETS[sl.lfo_tab] .. ' LFO shape')
  ImGui.SameLine(ctx)
  c, v = ImGui.Checkbox(ctx, 'Sync', L.sync or false)
  if c then L.sync = v; push_lfo(sel) end
  tip('Lock the rate to the project tempo')
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, TARGETS[sl.lfo_tab])
  lfo_graph(sl, L, ww, 44)
  c, v = slider('Rate##lfospd', L.spd, 0, 1, '%.3f', 0.25)
  if c then L.spd = v; push_lfo(sel) end
  ImGui.SameLine(ctx)
  c, v = slider('Depth##lfostr', L.str, 0, 1, '%.3f', 0.3)
  if c then L.str = v; push_lfo(sel) end

  ImGui.Spacing(ctx)
  if ImGui.Button(ctx, 'Clear slot') then clear_slot(sel) end
  tip('Empties this slot and removes its sampler')
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Show plugin') and track_valid() and sl.fx then
    R.TrackFX_SetOpen(track, sl.fx, true)
  end
  tip('Opens this slot\'s ReaSamplomatic5000 for anything not covered here')
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Plugin map') then ImGui.OpenPopup(ctx, 'pmap') end
  tip('Which ReaSamplomatic5000 parameter each control is driving')
  if ImGui.BeginPopup(ctx, 'pmap') then
    if track_valid() and sl.fx then
      local p = params_of(track, sl.fx)
      for _, want in ipairs(PMAP) do
        local idx = pindex(p, table.unpack(want, 2))
        if idx then
          local raw, mn, mx = R.TrackFX_GetParam(track, sl.fx, idx)
          ImGui.Text(ctx, ('%-9s -> #%d %s = %.3f  [%.2f..%.2f]'):format(
            want[1], idx, p.names[idx + 1] or '?', raw or 0, mn or 0, mx or 0))
        else
          ImGui.TextDisabled(ctx, ('%-9s -> no match'):format(want[1]))
        end
      end
    else
      ImGui.TextDisabled(ctx, 'no plugin for this slot yet')
    end
    ImGui.EndPopup(ctx)
  end
  ImGui.EndChild(ctx)
end

--- Window -------------------------------------------------------------------

local function top_bar()
  local c, v
  if ImGui.Button(ctx, 'Build track') then sync(true) end
  tip('Creates the sampler track, or rebuilds every slot on it')
  ImGui.SameLine(ctx)
  if toggle('Follow SoundPicker', S.follow,
      'On: the sound you pick in SoundPicker drops into the selected slot') then
    S.follow = not S.follow
  end
  ImGui.SameLine(ctx)
  if toggle('Tile keys', S.spread,
      'Keeps the filled slots side by side across the keyboard') then
    S.spread = not S.spread
    if S.spread then tile_ranges(); push_all() end
  end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 70)
  c, v = ImGui.DragInt(ctx, 'from##base', S.base, 0.2, 0, 115, note_name(S.base))
  if c then S.base = v; tile_ranges(); push_all() end
  tip('Lowest key of the split')
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 70)
  c, v = ImGui.DragInt(ctx, 'to##top', S.top, 0.2, 12, 127, note_name(S.top))
  if c then S.top = v; tile_ranges(); push_all() end
  tip('Highest key of the split. The filled slots share everything between.')

  ImGui.SameLine(ctx)
  local x = ImGui.GetContentRegionAvail(ctx)
  ImGui.SameLine(ctx, 0, math.max(8, x - 96))
  if ImGui.Button(ctx, 'Clear all') then
    for i = 1, SLOTS do clear_slot(i) end
  end
  tip('Empties every slot and removes their samplers')
end

local function status()
  if not track_valid() then
    ImGui.TextDisabled(ctx, 'No track yet. Fill a slot, or press Build track.')
    return
  end
  local n = 0
  for i = 1, SLOTS do if used(slots[i]) then n = n + 1 end end
  local armed = R.GetMediaTrackInfo_Value(track, 'I_RECARM') == 1
  ImGui.TextDisabled(ctx, ('%d slot%s on the sampler track%s'):format(
    n, n == 1 and '' or 's', armed and ', armed for your keyboard' or ''))
  ImGui.SameLine(ctx)
  ImGui.TextDisabled(ctx, '  v' .. VERSION)
  if not armed then
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, 'arm it') then
      R.SetMediaTrackInfo_Value(track, 'I_RECARM', 1)
      R.SetMediaTrackInfo_Value(track, 'I_RECMON', 1)
    end
  end
end

local function drops()
  if not ImGui.BeginDragDropTarget(ctx) then return end
  local ok, count = ImGui.AcceptDragDropPayloadFiles(ctx)
  if ok then
    for i = 0, (count or 1) - 1 do
      local got, fn = ImGui.GetDragDropPayloadFile(ctx, i)
      if got then
        local slot = sel + i
        if slot <= SLOTS then load_into(slot, fn) end
      end
    end
  end
  ImGui.EndDragDropTarget(ctx)
end

local open, beat_at = true, nil
-- SoundPicker's button asks this window to close by stamping a token here.
-- Whatever stands at startup is already spent.
local close_seen = R.GetExtState(EXT, 'close')

local function frame()
  if S.font_size ~= font_made then
    font = ImGui.CreateFont('sans-serif', S.font_size)
    ImGui.Attach(ctx, font)
    font_made = S.font_size
  end
  build_theme()
  poll_pick()
  local t, asked_to_close = R.time_precise(), false
  if t - (beat_at or -9) > 0.25 then
    beat_at = t
    R.SetExtState(EXT, 'alive', tostring(t), false) -- SoundPicker's button looks for this
    local tok = R.GetExtState(EXT, 'close')
    if tok ~= close_seen then close_seen = tok; asked_to_close = true end
    -- follow SoundPicker's look while it is being changed, not only at startup
    local th, md = R.GetExtState(PICK_SECTION, 'theme'), R.GetExtState(PICK_SECTION, 'mode')
    local fs = tonumber(R.GetExtState(PICK_SECTION, 'font_size'))
    local tp = R.GetExtState(PICK_SECTION, 'tips')
    if th ~= '' then S.theme = th end
    if md ~= '' then S.mode = md end
    if fs then S.font_size = fs end
    if tp ~= '' then S.tips = tp == '1' end
  end

  ImGui.PushFont(ctx, font)
  for _, c in ipairs(STYLE) do ImGui.PushStyleColor(ctx, c[1], T[c[2]]) end
  for _, v in ipairs(VARS) do
    if v[3] then ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) else ImGui.PushStyleVar(ctx, v[1], v[2]) end
  end

  ImGui.SetNextWindowSize(ctx, 820, 460, ImGui.Cond_FirstUseEver)
  local visible
  visible, open = ImGui.Begin(ctx, 'yj_SoundSampler###yj_SoundSampler', true)
  if visible then
    top_bar()
    ImGui.Spacing(ctx)
    local w, h = ImGui.GetContentRegionAvail(ctx)
    local kb = 52
    -- the lists take whatever the keyboard, the status line and the two gaps
    -- between them do not, measured rather than guessed, so the window never
    -- overflows into a scrollbar
    local gap = 7
    if ImGui.GetStyleVar and ImGui.StyleVar_ItemSpacing then
      local ok, _, sy = pcall(ImGui.GetStyleVar, ctx, ImGui.StyleVar_ItemSpacing)
      if ok and sy then gap = sy end
    end
    local ch = math.max(60, h - kb - gap * 2 - ImGui.GetTextLineHeight(ctx) - 1)
    local lw = math.max(180, math.min(300, w * 0.32))
    slot_list(lw, ch)
    ImGui.SameLine(ctx)
    slot_editor(w - lw - 8, ch)
    drops()
    keyboard(w, kb)
    status()
  end
  -- End pairs with Begin whichever way it answered. Skipping it while the
  -- window was rolled up left the stack unbalanced, and it never came back.
  ImGui.End(ctx)
  ImGui.PopStyleVar(ctx, #VARS)
  ImGui.PopStyleColor(ctx, #STYLE)
  ImGui.PopFont(ctx)
  -- Begin hands back the window's own open state, so SoundPicker's request has
  -- to be applied after it rather than before
  if asked_to_close then open = false end

  if open then
    R.defer(frame)
  else
    save_settings()
    R.DeleteExtState(EXT, 'alive', false)
  end
end

--- Start --------------------------------------------------------------------

-- Opening the window again finds last session's track. Each slot's plugin is
-- tagged on the track, so they go back to the slots they came from instead of
-- a second set piling up beside them.
local function adopt()
  if not track_valid() then return end
  local claimed = {}
  for i = 1, SLOTS do
    local _, tag = R.GetSetMediaTrackInfo_String(track, 'P_EXT:yj_slot' .. i, '', false)
    local guid, p0, v0 = (tag or ''):match('^(.-)|(.-)|(.*)$')
    if not guid then guid = tag end
    local fx = fx_by_guid(guid)
    if fx then
      local sl = slots[i]
      sl.fx, sl.fresh = fx, false
      sl.pan0, sl.vol0 = tonumber(p0), tonumber(v0)
      claimed[fx] = true
      local got, file = R.TrackFX_GetNamedConfigParm(track, fx, 'FILE0')
      if got and file ~= '' then
        sl.path, sl.name = file, file:match('[^\\/]+$') or file
        sl.len, sl.pk = source_len(file), nil
      end
      if not sl.pan0 or not sl.vol0 then capture_defaults(sl) end
      pull_slot(i)
    end
  end
  -- untagged samplers are leftovers from an older build or a crash: no slot can
  -- reach them, so they only make noise
  for fx = R.TrackFX_GetCount(track) - 1, 0, -1 do
    if not claimed[fx] and is_rs5k(track, fx) then
      R.TrackFX_Delete(track, fx)
      for i = 1, SLOTS do
        if slots[i].fx and slots[i].fx > fx then slots[i].fx = slots[i].fx - 1 end
      end
    end
  end
  for i = 1, SLOTS do if slots[i].fx then remember(i) end end
end

load_settings()
track = find_track()
adopt()
R.defer(frame)
