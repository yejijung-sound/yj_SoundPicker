-- @description yj_SoundPicker
-- @creator Yeji Jung
-- @version 1.0
-- @about
--   Reads your existing Media Explorer databases (MediaDB/*.ReaperFileList).
--   Search: words (AND), OR / comma, NOT / -word, "exact phrase", field:word
--   Tokens: 48k 48k+ 44k-   1ch 2ch+   24b 16b-   2s 0.5s- 10s+ 3s=
--   Preview with waveform, range selection, pitch, fit-to-length, EQ and compressor,
--   then spot or drag to the selected track at the edit cursor.
--   Requires ReaImGui (ReaPack) and the SWS extension (sws-extension.org).

--- Dependencies
-- ReaPack installs no dependencies of its own, so point the way to each one.
local NEED_IMGUI = 'yj_SoundPicker needs ReaImGui 0.9 or newer.\n\n' ..
  'It is on ReaPack: Extensions > ReaPack > Browse packages, then search for ReaImGui.'

if not reaper.ImGui_GetBuiltinPath then
  if reaper.ReaPack_BrowsePackages then
    if reaper.MB(NEED_IMGUI .. '\n\nOpen ReaPack now?', 'yj_SoundPicker', 4) == 6 then
      reaper.ReaPack_BrowsePackages('ReaImGui')
    end
  else
    reaper.MB(NEED_IMGUI, 'yj_SoundPicker', 0)
  end
  return
end
if not reaper.CF_CreatePreview then
  reaper.MB('yj_SoundPicker needs the SWS extension.\n\n' ..
    'SWS does not come from ReaPack: download the installer from sws-extension.org, ' ..
    'run it, then restart REAPER.', 'yj_SoundPicker', 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local got_imgui, ImGui = pcall(function() return require 'imgui' '0.9' end)
if not got_imgui then
  reaper.MB(NEED_IMGUI .. '\n\nAn older version is installed. Synchronize packages to update it, ' ..
    'then restart REAPER.', 'yj_SoundPicker', 0)
  return
end

--- Constants and settings
local SCRIPT        = 'yj_SoundPicker'
local SEP           = package.config:sub(1, 1)
local RESOURCE      = reaper.GetResourcePath()
local WAVE_POINTS   = 4000  -- peaks per file: one per pixel even on a wide window
local MAX_WAVE_LEN  = 900   -- seconds; longer files show no waveform
local TRASH_FRAMES  = 30    -- frames to wait before freeing a stopped preview's source
local GLUE_CMD      = 40362 -- Item: Glue items, ignoring time selection
local PEAKS_CMD     = 40047 -- Peaks: Build any missing peak files

local MARK       = '\nfile ' -- start of every entry in the lowercase search copy
local LOAD_CHUNK = 1048576

local AUDIO_EXT = {
  wav = true, wave = true, bwf = true, w64 = true, rf64 = true,
  aif = true, aiff = true, aifc = true,
  flac = true, mp3 = true, ogg = true, opus = true, wv = true,
}

local function get_num(k, d)
  local v = tonumber(reaper.GetExtState(SCRIPT, k))
  if v == nil then return d end
  return v
end
local function get_bool(k, d)
  local v = reaper.GetExtState(SCRIPT, k)
  if v == '' then return d end
  return v == '1'
end

local S = {
  -- not saved
  vol_db   = 0,
  pitch    = 0,
  fit      = 0,
  reverse  = false,
  eq_on    = false,
  e_hpf = 20, e_lf = 120, e_lg = 0, e_lq = 1, e_mf = 1000, e_mg = 0, e_mq = 0.8,
  e_hf = 8000, e_hg = 0, e_hq = 1, e_lpf = 20000,
  comp_on  = false,
  c_thr = -20, c_ratio = 4, c_att = 10, c_rel = 150, c_mk = 0,
  -- saved
  ppitch   = get_bool('ppitch', true),
  loop     = get_bool('loop', false),
  autoplay = get_bool('autoplay', true),
  outpair  = get_num('outpair', 0),   -- 0 = outputs 1/2, 1 = 3/4, ...
  theme    = ({ rose = 'rose', sage = 'sage', rainbow = 'rainbow', simple = 'simple' })[reaper.GetExtState(SCRIPT, 'theme')] or 'simple',
  mode     = (reaper.GetExtState(SCRIPT, 'mode') == 'light') and 'light' or 'dark',
  font_size = get_num('font_size', 13),
  icons    = (reaper.GetExtState(SCRIPT, 'icons') == 'pixel') and 'pixel' or 'smooth',
  pitch_unit = (reaper.GetExtState(SCRIPT, 'pitch_unit') == 'rate') and 'rate' or 'st',
  mon_db   = get_num('mon_db', 0),
  spectral = get_bool('spectral', true),
  glue     = get_bool('glue', false),
  copy     = get_bool('copy', true),
  advance  = get_bool('advance', true),
  dock     = get_num('dock', 0), -- 0 = floating, negative = REAPER docker
  tips     = get_bool('tips', true),
  settings_win = false,
}
local NO_SAVE = { vol_db = true, pitch = true, fit = true, reverse = true, eq_on = true, comp_on = true, settings_win = true }
for k in pairs(S) do if k:match('^e_') or k:match('^c_') then NO_SAVE[k] = true end end

-- UI state lives in one table: the main chunk is close to Lua's 200-local limit
local UI = { k = 1 }
function UI.sz(n) return math.floor(n * UI.k + 0.5) end

-- the ? button switches every tooltip off
do
  local real_tip = ImGui.SetTooltip
  ImGui.SetTooltip = function(c, text) if S.tips then return real_tip(c, text) end end
end

local function save_settings()
  for k, v in pairs(S) do
    if not NO_SAVE[k] then
      local s = type(v) == 'boolean' and (v and '1' or '0') or tostring(v)
      reaper.SetExtState(SCRIPT, k, s, true)
    end
  end
end

--- Helpers
local function basename(p) return p:match('([^\\/]+)$') or p end

local library_folder
do
  local SMALL_WORDS = { the = 1, ['and'] = 1, of = 1, de = 1, by = 1, ['for'] = 1, la = 1, le = 1,
    el = 1, ['in'] = 1, on = 1, to = 1, at = 1, an = 1, a = 1, my = 1, da = 1, du = 1, von = 1, van = 1 }
  local ACRONYMS = { ip = 1, pse = 1, gdc = 1, sfx = 1, fx = 1, bbc = 1, uk = 1, us = 1, usa = 1,
    ost = 1, vo = 1, ui = 1, hd = 1, ir = 1, ai = 1, dj = 1, nyc = 1 }
  local function pretty_folder(name)
    local words = {}
    for w in name:gmatch('[^%-_%s%.]+') do
      local lw = w:lower()
      if ACRONYMS[lw] then
        w = lw:upper()
      elseif SMALL_WORDS[lw] and #words > 0 then
        w = lw
      elseif w == lw then -- leave words that already have capitals alone
        w = lw:sub(1, 1):upper() .. lw:sub(2)
      end
      words[#words + 1] = w
    end
    return table.concat(words, ' ')
  end

  -- library = the first folder under the database's root
  local function norm_dir(p) return (p:gsub('\\', '/'):gsub('/+$', ''):lower()) end
  library_folder = function(db, path)
    if not db.lib_roots then
      local roots = {}
      for _, r in ipairs(db.roots or {}) do roots[#roots + 1] = norm_dir(r) end
      if #roots == 0 and db.samples and #db.samples > 0 then
        local pre = norm_dir(db.samples[1]):match('^(.*)/') or ''
        for i = 2, #db.samples do
          local d = norm_dir(db.samples[i])
          while pre ~= '' and d:sub(1, #pre + 1) ~= pre .. '/' do pre = pre:match('^(.*)/') or '' end
        end
        if pre ~= '' then roots[1] = pre end
      end
      table.sort(roots, function(a, b) return #a > #b end) -- deepest match first
      db.lib_roots = roots
    end
    local np = path:gsub('\\', '/')
    local lp = np:lower()
    for _, r in ipairs(db.lib_roots) do
      if lp:sub(1, #r + 1) == r .. '/' then
        local folder = np:sub(#r + 2):match('^([^/]+)/')
        return folder and pretty_folder(folder)
      end
    end
  end
end

local function is_audio(p)
  local ext = p:match('%.([%w]+)$')
  return ext ~= nil and AUDIO_EXT[ext:lower()] == true
end

local QUOTES = { ['"'] = true, ["'"] = true, ['`'] = true }
local function read_token(s, i)
  local n = #s
  while i <= n and s:sub(i, i):match('%s') do i = i + 1 end
  if i > n then return nil, i end
  local c = s:sub(i, i)
  if QUOTES[c] then
    local j = s:find(c, i + 1, true) or (n + 1)
    return s:sub(i + 1, j - 1), j + 1
  end
  local j = s:find('%s', i) or (n + 1)
  return s:sub(i, j - 1), j
end

local function fmt_len(l)
  if not l or l <= 0 then return '' end
  if l < 60 then return ('%.2fs'):format(l) end
  return ('%d:%05.2f'):format(math.floor(l / 60), l % 60)
end

local function fmt_sr(sr)
  if not sr or sr <= 0 then return '' end
  local k = sr / 1000
  if k == math.floor(k) then return ('%dk'):format(math.floor(k)) end
  return ('%.1fk'):format(k)
end

local function parse_len(v)
  local h, m, s = v:match('^(%d+):(%d+):([%d%.]+)$')
  if h then return tonumber(h) * 3600 + tonumber(m) * 60 + (tonumber(s) or 0) end
  m, s = v:match('^(%d+):([%d%.]+)$')
  if m then return tonumber(m) * 60 + (tonumber(s) or 0) end
end

-- m:ss.fff = 2, h:mm:ss.fff = 3. Timecode stamps like 01:00:26.00 are not lengths.
local function is_len(v)
  if v:match('^%d+:%d%d%.%d+$') then return 2 end
  if v:match('^[1-9]:%d%d:%d%d%.%d+$') then return 3 end
end

-- specs written into descriptions, e.g. "16bit 44100khz 1:25.891"
local function ci(word)
  return (word:gsub('%a', function(c) return '[' .. c:lower() .. c:upper() .. ']' end))
end
local TECH_NUM = {
  '%d+%s*%-?%s*' .. ci('bit') .. '[sS]?%f[%A]',
  '%d+%.?%d*%s*[kK]?' .. ci('hz') .. '%f[%A]',
  '%d+:%d%d:%d%d%.%d+',
  '%d+:%d%d%.%d+',
}
local TECH_WORDS = { ci('stereo'), ci('mono'), ci('wav'), ci('wave'), ci('khz'), ci('hz'), ci('bit') }

local function tech_from_text(t)
  local l = t:lower()
  local bits = tonumber(l:match('(%d+)%s*%-?%s*bits?%f[%A]'))
  local sr = tonumber(l:match('(%d+%.?%d*)%s*k?hz%f[%A]'))
  if sr and sr < 1000 then sr = sr * 1000 end
  local lv = l:match('(%d+:%d%d%.%d+)')
  return sr, bits, lv and parse_len(lv)
end

-- drops the text when only spec words are left
local function strip_tech(t)
  local s = t
  for _, p in ipairs(TECH_NUM) do s = s:gsub(p, ' ') end
  local rest = s
  for _, p in ipairs(TECH_WORDS) do rest = rest:gsub('%f[%a]' .. p .. '%f[%A]', ' ') end
  if not rest:find('%a%a') then return '' end
  s = s:gsub('%s+', ' '):gsub('^[%s,;:|/%-]+', ''):gsub('[%s,;:|/%-]+$', '')
  return s
end

-- DATA fields: t title, a artist, b album, y year, g genre, c comment, p BPM
-- Unlabelled numbers are told apart by their shape; artwork tags are dropped.
local DATA_KEYS = { t = 'title', a = 'artist', b = 'album', y = 'year', g = 'genre', c = 'comment', p = 'bpm' }

local function junk(v)
  return v:find('^mime:') or v:find('^image/') or (#v > 60 and not v:find('%s'))
end

local function parse_data(line)
  local d = { desc = {}, small = {} }
  local i = 1
  while true do
    local tok
    tok, i = read_token(line, i)
    if not tok then break end
    local k, v = tok:match('^(%a):(.*)$')
    if not k then v = tok end
    if v ~= '' and v:find('%w') and not junk(v) then
      local role = k and DATA_KEYS[k:lower()]
      if role then
        if not d[role] then d[role] = v end
      elseif v:match('^%d+$') then
        local n = tonumber(v)
        if n >= 8000 and n <= 768000 and not d.sr then d.sr = n
        elseif n >= 1 and n <= 64 and #d.small < 2 then d.small[#d.small + 1] = n end
      elseif v:match('^%d+:%d+[:%d%.]*$') then
        local lk = is_len(v) -- else a time stamp: dropped
        if lk and (not d.len or (lk == 2 and d.len_k == 3)) then d.len, d.len_k = parse_len(v), lk end
      else
        d.desc[#d.desc + 1] = v
      end
    end
  end
  return d
end

--- Databases
local dbs = {}

local function load_db_list()
  local paths, titles = {}, {}
  local fh = io.open(reaper.get_ini_file(), 'r')
  if fh then
    local in_sec = false
    for line in fh:lines() do
      local sec = line:match('^%[(.-)%]')
      if sec then
        in_sec = (sec == 'reaper_explorer')
      elseif in_sec then
        local idx, val = line:match('^ShortcutT(%d+)=(.*)$')
        if idx then
          titles[idx] = val
        else
          idx, val = line:match('^Shortcut(%d+)=(.*)$')
          if idx then paths[idx] = val end
        end
      end
    end
    fh:close()
  end

  for idx, p in pairs(paths) do
    if p:lower():match('%.reaperfilelist$') then
      local full = p
      if not p:find('[\\/]') then full = RESOURCE .. SEP .. 'MediaDB' .. SEP .. p end
      local title = titles[idx]
      if not title or title == '' then title = (p:gsub('%.[Rr]eaper[Ff]ile[Ll]ist$', '')) end
      dbs[#dbs + 1] = { title = title, path = full, order = tonumber(idx) or 0 }
    end
  end

  if #dbs == 0 then
    local dir, i = RESOURCE .. SEP .. 'MediaDB', 0
    while true do
      local fn = reaper.EnumerateFiles(dir, i)
      if not fn then break end
      if fn:lower():match('%.reaperfilelist$') then
        dbs[#dbs + 1] = { title = (fn:gsub('%.[Rr]eaper[Ff]ile[Ll]ist$', '')), path = dir .. SEP .. fn, order = i }
      end
      i = i + 1
    end
  end

  table.sort(dbs, function(a, b) return a.order < b.order end)
  while #dbs > 63 do table.remove(dbs) end -- result keys pack the db index in 6 bits
end

-- A database is kept as ~1 MB chunks of lowercase text, each holding whole entries.
-- The original case is read back from disk when an entry is shown (chunk.off).
-- A result key packs (position, chunk, database) into one integer.
local function make_key(pos, ci, di) return (pos * 1048576 + ci) * 64 + di end
local function split_key(key)
  local di = key % 64
  local rest = key // 64
  return rest // 1048576, rest % 1048576, di
end

local function entry_end(low, s)
  return low:find(MARK, s + 1, true) or (#low + 1)
end

local function last_mark(str)
  local p, last = 1, nil
  while true do
    local q = str:find(MARK, p, true)
    if not q then return last end
    last, p = q, q + 1
  end
end

local function entry_start(low, h)
  local step = 2048
  while true do
    local a = math.max(1, h - step)
    local q = last_mark(low:sub(a, h + #MARK - 1))
    if q then return a + q - 1 end
    if a == 1 then return nil end
    step = step * 4
  end
end

local info_cache, info_count = {}, 0

-- low_only: no disk read, not cached (used while searching)
local function get_info(key, low_only)
  local inf = info_cache[key]
  if inf then return inf end
  local s, ci, di = split_key(key)
  local db = dbs[di]
  local ch = db.chunks[ci]
  local e = entry_end(ch.low, s)
  local low_ent = ch.low:sub(s, e - 1)
  -- the file changed since loading: fall back to lowercase
  local ent
  local fh = (not low_only) and io.open(db.path, 'rb')
  if fh then
    -- chunk text = "\n" .. file bytes, so text position k is file offset off + k - 2
    if s == 1 then
      fh:seek('set', ch.off)
      ent = fh:read(e - 2)
      if ent then ent = '\n' .. ent end
    else
      fh:seek('set', ch.off + s - 2)
      ent = fh:read(e - s)
    end
    fh:close()
  end
  if not ent or ent:lower() ~= low_ent then ent = low_ent end
  local path = read_token(ent, 7) or ''
  inf = { key = key, path = path, name = basename(path), db = db.title }
  local texts, seen = {}, {}
  local stem = inf.name:gsub('%.[%w]+$', '')
  seen[inf.name:lower()], seen[stem:lower()] = true, true
  local raw = {}
  local function add(t)
    if t then raw[#raw + 1] = t; t = strip_tech(t) end
    if t and t ~= '' and not seen[t:lower()] then
      seen[t:lower()] = true
      texts[#texts + 1] = t
    end
  end
  for line in ent:gmatch(low_only and '\ndata ([^\n]*)' or '\nDATA ([^\n]*)') do
    local d = parse_data(line)
    inf.sr = inf.sr or d.sr
    inf.ch = inf.ch or d.small[1]
    inf.bits = inf.bits or d.small[2]
    inf.len = inf.len or d.len
    for _, role in pairs(DATA_KEYS) do inf[role] = inf[role] or d[role] end
    for _, t in ipairs(d.desc) do add(t) end
  end
  if #texts == 0 then add(inf.comment) end
  if #texts == 0 then add(inf.title) end
  inf.meta = table.concat(texts, ' ')
  if not (inf.sr and inf.bits and inf.len) then
    if inf.comment then raw[#raw + 1] = inf.comment end
    for _, t in ipairs(raw) do
      local tsr, tbits, tlen = tech_from_text(t)
      inf.sr, inf.bits, inf.len = inf.sr or tsr, inf.bits or tbits, inf.len or tlen
    end
  end
  inf.ucs = inf.name:match(low_only and '^(%a%a+%a*)_' or '^(%u%u+%a*)_') or ''
  inf.cat = (inf.ucs ~= '' and inf.ucs) or inf.genre or ''
  inf.lib = inf.album or library_folder(db, path) or inf.artist or db.title
  inf.maker = (inf.artist and inf.artist ~= inf.lib) and inf.artist or nil
  if low_only then return inf end
  inf.cells = { inf.meta, inf.cat, fmt_len(inf.len), fmt_sr(inf.sr),
    (inf.ch and inf.ch > 0) and tostring(inf.ch) or '', (inf.bits and inf.bits > 0) and tostring(inf.bits) or '', inf.lib }
  if info_count >= 20000 then info_cache, info_count = {}, 0 end
  info_cache[key] = inf
  info_count = info_count + 1
  return inf
end

-- same rules as parse_data, without building tables
local function ent_specs(ent)
  local sr, a, b, len, lk
  for line in ent:gmatch('\ndata ([^\n]*)') do
    line = line:gsub('"[^"]*"', ' ')
    for tok in line:gmatch('%S+') do
      local k, v = tok:match('^(%a):(.*)$')
      if not k then v = tok end
      if k and DATA_KEYS[k] then
        -- labelled text, not a spec
      elseif v:match('^%d+$') then
        local n = tonumber(v)
        if n >= 8000 and n <= 768000 then
          if not sr then sr = n end
        elseif n >= 1 and n <= 64 then
          if not a then a = n elseif not b then b = n end
        end
      else
        local k2 = is_len(v)
        if k2 and (not len or (k2 == 2 and lk == 3)) then len, lk = parse_len(v), k2 end
      end
    end
  end
  if not (sr and b and len) then
    for line in ent:gmatch('\ndata ([^\n]*)') do
      local tsr, tbits, tlen = tech_from_text(line)
      sr, b, len = sr or tsr, b or tbits, len or tlen
    end
  end
  return sr, a, len, b -- sample rate, channels, length, bits
end

local loading = true
local load_status = 'Starting...'
local total_files, counting = 0, true

local loader = coroutine.create(function()
  for di, db in ipairs(dbs) do
    load_status = ('Loading database %d/%d: %s'):format(di, #dbs, db.title)
    coroutine.yield()
    db.chunks = {}
    local fh = io.open(db.path, 'rb')
    if fh then
      local size = math.max(1, fh:seek('end') or 1)
      fh:seek('set', 0)
      local done, carry = 0, ''
      local t0 = reaper.time_precise()
      db.roots, db.samples = {}, {}
      local function add(content)
        local text = '\n' .. content
        if #db.chunks == 0 then -- header: the folders this database scans
          local first = text:find('\nFILE ', 1, true) or #text
          for line in text:sub(1, first):gmatch('\nPATH ([^\n]*)') do
            local r = read_token(line, 1)
            if r and r ~= '' then db.roots[#db.roots + 1] = r end
          end
        end
        local sp = text:match('\nFILE%s+"([^"]+)"') or text:match('\nFILE%s+(%S+)')
        if sp then db.samples[#db.samples + 1] = sp end
        db.chunks[#db.chunks + 1] = { low = text:lower(), off = done }
        done = done + #content
      end
      while true do
        local block = fh:read(LOAD_CHUNK)
        if not block then
          if carry ~= '' then add(carry) end
          break
        end
        local buf = { carry, block }
        carry = ''
        local rest = fh:read('L') -- finish the current line
        if rest then buf[#buf + 1] = rest end
        while true do -- then keep lines until the next entry starts
          local line = fh:read('L')
          if not line then break end
          if line:sub(1, 5) == 'FILE ' then carry = line; break end
          buf[#buf + 1] = line
        end
        add(table.concat(buf))
        if reaper.time_precise() - t0 > 0.03 then
          load_status = ('Loading database %d/%d: %s  %d%%'):format(di, #dbs, db.title, math.min(100, done * 100 // size))
          coroutine.yield()
          t0 = reaper.time_precise()
        end
      end
      fh:close()
    end
  end
end)

local counter = coroutine.create(function()
  local t0 = reaper.time_precise()
  for _, db in ipairs(dbs) do
    local n = 0
    for _, ch in ipairs(db.chunks or {}) do
      local low, p = ch.low, 1
      while true do
        local q = low:find(MARK, p, true)
        if not q then break end
        n, p = n + 1, q + 1
      end
      if reaper.time_precise() - t0 > 0.01 then
        coroutine.yield()
        t0 = reaper.time_precise()
      end
    end
    db.count = n
    total_files = total_files + n
  end
end)

--- Query parsing
local FIELD_ALIASES = {
  name = 'name', file = 'name', path = 'path', folder = 'path',
  desc = 'desc', d = 'desc', description = 'desc', lib = 'lib', library = 'lib',
  maker = 'lib', artist = 'lib', album = 'lib',
  cat = 'cat', category = 'cat', db = 'db',
}

local function tokenize(q)
  local toks, i, n = {}, 1, #q
  while i <= n do
    local c = q:sub(i, i)
    if c:match('%s') then
      i = i + 1
    elseif c == ',' then
      toks[#toks + 1] = { op = 'OR' }
      i = i + 1
    else
      local neg = false
      if c == '-' and i < n and not q:sub(i + 1, i + 1):match('[%s%d,]') then
        neg = true
        i = i + 1
        c = q:sub(i, i)
      end
      local field
      local fname, p = q:match('^(%a+):()', i)
      if fname and FIELD_ALIASES[fname:lower()] then
        field = FIELD_ALIASES[fname:lower()]
        i = p
        c = q:sub(i, i)
      end
      if c == '"' then
        local j = q:find('"', i + 1, true) or (n + 1)
        local text = q:sub(i + 1, j - 1)
        if text ~= '' then toks[#toks + 1] = { text = text:lower(), neg = neg, field = field, phrase = true } end
        i = j + 1
      else
        local j = i
        while j <= n and not q:sub(j, j):match('[%s,]') do j = j + 1 end
        local text = q:sub(i, j - 1)
        i = j
        if text == 'OR' and not field then
          toks[#toks + 1] = { op = 'OR' }
        elseif text == 'NOT' and not field then
          toks[#toks + 1] = { op = 'NOT' }
        elseif text == 'AND' and not field then -- AND is the default between words
        elseif text ~= '' then
          toks[#toks + 1] = { text = text:lower(), neg = neg, field = field }
        end
      end
    end
  end
  return toks
end

local function parse_spec(t)
  if t.field or t.phrase then return nil end
  local num, mod = t.text:match('^(%d*%.?%d+)ch([%+%-=]?)$')
  if num then return { unit = 'ch', num = tonumber(num), mod = mod } end
  local num2, unit, mod2 = t.text:match('^(%d*%.?%d+)([bks])([%+%-=]?)$')
  if num2 then return { unit = unit, num = tonumber(num2), mod = mod2 } end
end

local function parse_query(q)
  local clauses, cur, pending_or, pending_not = {}, nil, false, false
  for _, t in ipairs(tokenize(q)) do
    if t.op == 'OR' then
      pending_or = true
    elseif t.op == 'NOT' then
      pending_not = true
    else
      if pending_not then t.neg = true; pending_not = false end
      t.spec = parse_spec(t)
      if pending_or and cur and not t.neg and not cur[1].neg then
        cur[#cur + 1] = t
      else
        cur = { t }
        clauses[#clauses + 1] = cur
      end
      pending_or = false
    end
  end
  return clauses
end

local function spec_cmp(v, s)
  if not v or v <= 0 or not s.num then return false end
  local n, m = s.num, s.mod
  if s.unit == 'k' then
    local kv = v / 1000
    if m == '+' then return kv >= n - 0.5
    elseif m == '-' then return kv <= n + 0.5
    elseif m == '=' then return math.abs(kv - n) < 0.05
    else return math.abs(kv - n) < 0.6 end
  elseif s.unit == 's' then
    if m == '+' then return v >= n
    elseif m == '-' then return v <= n
    elseif m == '=' then return math.abs(v - n) < 0.05
    else return math.abs(v - n) <= math.max(0.25, n * 0.2) end
  else
    if m == '+' then return v >= n
    elseif m == '-' then return v <= n
    else return v == n end
  end
end

local SPEC_FIELD = { k = 'sr', ch = 'ch', b = 'bits', s = 'len' }

local function field_text(inf, field)
  if field == 'name' then return inf.name:lower()
  elseif field == 'path' then return inf.path:lower()
  elseif field == 'desc' then return inf.meta:lower()
  elseif field == 'cat' then return ((inf.genre or '') .. ' ' .. inf.ucs):lower()
  elseif field == 'lib' then return ((inf.album or '') .. ' ' .. (inf.artist or '')):lower()
  elseif field == 'db' then return inf.db:lower()
  end
  return ''
end

-- st is one reusable table per search: { key, path, inf, specs_done, sr, ch, len, bits }
local function term_match(ent, t, st)
  if t.spec then
    if not st.specs_done then
      st.sr, st.ch, st.len, st.bits = ent_specs(ent)
      st.specs_done = true
    end
    return spec_cmp(st[SPEC_FIELD[t.spec.unit]], t.spec)
  end
  if t.field == 'path' then return st.path:find(t.text, 1, true) ~= nil end
  if t.field == 'name' then return basename(st.path):find(t.text, 1, true) ~= nil end
  if t.field then
    if not st.inf then st.inf = get_info(st.key, true) end
    return field_text(st.inf, t.field):find(t.text, 1, true) ~= nil
  end
  return ent:find(t.text, 1, true) ~= nil
end

local function entry_matches(ent, clauses, st)
  for _, cl in ipairs(clauses) do
    local any = false
    for _, t in ipairs(cl) do
      local m = term_match(ent, t, st)
      if t.neg then m = not m end
      if m then any = true; break end
    end
    if not any then return false end
  end
  return true
end

-- words inside "file " / "data " would match every entry
local function hits_keyword(text)
  return ('file '):find(text, 1, true) ~= nil or ('data '):find(text, 1, true) ~= nil
end

-- the hit at h is only the line keyword
local KEYWORDS = { '\nfile ', '\ndata ' }
local function is_keyword_hit(low, h, text)
  for _, kw in ipairs(KEYWORDS) do
    local o = kw:find(text, 1, true)
    while o do
      local a = h - o + 1
      if a >= 1 and low:sub(a, a + #kw - 1) == kw then return true end
      o = kw:find(text, o + 1, true)
    end
  end
  return false
end

local function strip_keywords(ent)
  ent = ent:gsub('\nfile ', '\n\1\1\1\1 ')
  ent = ent:gsub('\ndata ', '\n\2\2\2\2 ')
  return ent
end

-- the driver word is found with string.find, then each hit is checked against the whole query
local function choose_driver(clauses)
  local best, best_risky
  for _, cl in ipairs(clauses) do
    if #cl == 1 then
      local t = cl[1]
      if not t.neg and not t.spec and t.field ~= 'db' and #t.text >= 2 then
        local risky = hits_keyword(t.text)
        local better = not best
          or (best_risky and not risky)
          or (risky == best_risky and #t.text > #best.text)
        if better then best, best_risky = t, risky end
      end
    end
  end
  return best
end

--- Search
local query, typed_query, last_query = '', '', nil
local edit_time = 0
local need_search = false
-- databases unticked in the dropdown, by title
local db_sel = {}
for t in (reaper.GetExtState(SCRIPT, 'db_off') .. '|'):gmatch('([^|]*)|') do if t ~= '' then db_sel[t] = true end end
local results = {} -- packed result keys (see make_key)
local sel_idx = 0
-- multi-selection, by file key so it survives a shuffle
local MS = { keys = {}, n = 0, anchor = nil }
function MS.clear() MS.keys, MS.n, MS.anchor = {}, 0, nil end
function MS.single(k) MS.keys, MS.n, MS.anchor = { [k] = true }, 1, k end
function MS.toggle(k)
  if MS.keys[k] then MS.keys[k] = nil; MS.n = MS.n - 1 else MS.keys[k] = true; MS.n = MS.n + 1 end
  MS.anchor = k
end
function MS.range(i1, i2)
  if i1 > i2 then i1, i2 = i2, i1 end
  MS.keys, MS.n = {}, 0
  for i = i1, i2 do MS.keys[results[i]] = true; MS.n = MS.n + 1 end
end
function MS.anchor_index()
  if not MS.anchor then return nil end
  for i, k in ipairs(results) do if k == MS.anchor then return i end end
end
function MS.list() -- selected keys in list order (nil when only one is selected)
  if MS.n <= 1 then return nil end
  local out = {}
  for _, k in ipairs(results) do if MS.keys[k] then out[#out + 1] = k end end
  return out
end
local cur = nil -- info of the selected file
local searcher = nil

local SR_OPTS  = { { 44100, '44.1k' }, { 48000, '48k' }, { 96000, '96k' } }
local BIT_OPTS = { { 16, '16 bit' }, { 24, '24 bit' }, { 32, '32 bit' } }
local CH_OPTS  = { { 1, 'Mono' }, { 2, 'Stereo' }, { 4, '4 ch' }, { 6, '6 ch' } }

local F = { sr = {}, bits = {}, ch = {}, any = '', none = '', phrase = '', len_min = '', len_max = '' }

-- "90", "2.5", "1:30" -> seconds
local function len_secs(str)
  str = (str or ''):gsub('%s', ''):gsub('s$', '')
  if str == '' then return nil end
  local m, sec = str:match('^(%d+):([%d%.]+)$')
  local v = m and (tonumber(m) * 60 + (tonumber(sec) or 0)) or tonumber(str)
  if v and v > 0 then return v end
end
local filters_changed_at = nil
local search_active = false

local function words(str)
  local out = {}
  for w in str:gmatch('[^%s,]+') do out[#out + 1] = w:lower() end
  return out
end

local function filter_clauses()
  local cls = {}
  local function spec_clause(opts, set, unit, kdiv)
    local cl = {}
    for _, o in ipairs(opts) do
      if set[o[1]] then
        cl[#cl + 1] = { text = '', spec = { unit = unit, num = o[1] / kdiv, mod = unit == 'k' and '=' or '' } }
      end
    end
    if #cl > 0 then cls[#cls + 1] = cl end
  end
  spec_clause(SR_OPTS, F.sr, 'k', 1000)
  spec_clause(BIT_OPTS, F.bits, 'b', 1)
  spec_clause(CH_OPTS, F.ch, 'ch', 1)
  local lo, hi = len_secs(F.len_min), len_secs(F.len_max)
  if lo then cls[#cls + 1] = { { text = '', spec = { unit = 's', num = lo, mod = '+' } } } end
  if hi then cls[#cls + 1] = { { text = '', spec = { unit = 's', num = hi, mod = '-' } } } end
  local any = {}
  for _, w in ipairs(words(F.any)) do any[#any + 1] = { text = w } end
  if #any > 0 then cls[#cls + 1] = any end
  for _, w in ipairs(words(F.none)) do cls[#cls + 1] = { { text = w, neg = true } } end
  local ph = F.phrase:gsub('^%s+', ''):gsub('%s+$', ''):lower()
  if ph ~= '' then cls[#cls + 1] = { { text = ph, phrase = true } } end
  return cls
end

local function filter_count()
  local n = 0
  for _, t in ipairs({ F.sr, F.bits, F.ch }) do for _ in pairs(t) do n = n + 1 end end
  n = n + #words(F.any) + #words(F.none)
  if not F.phrase:match('^%s*$') then n = n + 1 end
  if len_secs(F.len_min) then n = n + 1 end
  if len_secs(F.len_max) then n = n + 1 end
  return n
end

local function clear_filters()
  F.sr, F.bits, F.ch, F.any, F.none, F.phrase = {}, {}, {}, '', '', ''
  F.len_min, F.len_max = '', ''
end

local shuffle_pending = false -- shuffle once the running search finishes
local scroll_top = false

local function start_search()
  shuffle_pending = false
  local clauses = parse_query(query)
  for _, cl in ipairs(filter_clauses()) do clauses[#clauses + 1] = cl end
  search_active = #clauses > 0
  local out = {}
  results, sel_idx = out, 0
  MS.clear()
  searcher = nil
  if #clauses == 0 then return end
  local use, n_on = {}, 0
  for i, d in ipairs(dbs) do
    if not db_sel[d.title] then use[i] = true; n_on = n_on + 1 end
  end
  local driver = choose_driver(clauses)
  local seen = (n_on > 1) and {} or nil -- the same file in two databases shows once
  local risky = false
  for _, cl in ipairs(clauses) do
    for _, t in ipairs(cl) do
      if not t.spec and not t.field and hits_keyword(t.text) then risky = true end
    end
  end

  searcher = coroutine.create(function()
    local t0, n = reaper.time_precise(), 0
    local st = {}
    local function evaluate(di, ci, low, s, e)
      local ent = low:sub(s, e - 1)
      local p = read_token(ent, 7)
      if not p or not is_audio(p) then return end
      if risky then ent = strip_keywords(ent) end
      local key = make_key(s, ci, di)
      st.key, st.path, st.inf, st.specs_done = key, p, nil, false
      if entry_matches(ent, clauses, st) then
        if seen then
          if seen[p] then return end
          seen[p] = true
        end
        out[#out + 1] = key
      end
    end
    local function slice()
      n = n + 1
      if n % 50 == 0 and reaper.time_precise() - t0 > 0.025 then
        coroutine.yield()
        t0 = reaper.time_precise()
      end
    end

    for di, db in ipairs(dbs) do
      if db.chunks and use[di] then
        for ci, ch in ipairs(db.chunks) do
          local low = ch.low
          if driver then
            local dtext = driver.text
            local drisky = hits_keyword(dtext)
            local pos = 1
            while true do
              local h = low:find(dtext, pos, true)
              if not h then break end
              local s = (not drisky or not is_keyword_hit(low, h, dtext)) and entry_start(low, h) or nil
              if s then
                local e = entry_end(low, s)
                evaluate(di, ci, low, s, e)
                pos = e
              else
                pos = h + 1
              end
              slice()
            end
          else
            local s = low:find(MARK, 1, true)
            while s do
              local e = entry_end(low, s)
              evaluate(di, ci, low, s, e)
              s = (e <= #low) and e or nil
              slice()
            end
          end
          slice()
        end
      end
    end
  end)
end

local function shuffle_results()
  if searcher then shuffle_pending = true; return end
  for i = #results, 2, -1 do
    local j = math.random(i)
    results[i], results[j] = results[j], results[i]
  end
  sel_idx = 0
  if cur then
    for i, k in ipairs(results) do
      if k == cur.key then sel_idx = i; break end
    end
  end
  scroll_top = true
end

local function process_search()
  if not searcher then return end
  local ok, err = coroutine.resume(searcher)
  if not ok then
    searcher = nil
    reaper.ShowConsoleMsg('yj_SoundPicker search error: ' .. tostring(err) .. '\n')
    return
  end
  if coroutine.status(searcher) == 'dead' then
    searcher = nil
    if shuffle_pending then
      shuffle_pending = false
      shuffle_results()
    elseif cur then
      for i, k in ipairs(results) do
        if k == cur.key then sel_idx = i; break end
      end
    end
  end
end

--- Preview
local frame, was_rolling = 0, false
local preview, preview_src, playing = nil, nil, false
local play_pos = 0
local sel_a, sel_b = nil, nil
local wf = nil
local wf_request = nil
local autoplay_pending = nil -- file waiting for its waveform before auto-play starts
local trash = {}
local flash, flash_until = nil, 0
local last_stop_frame = -1000

local function notify(msg)
  flash, flash_until = msg, reaper.time_precise() + 4
end

local function trash_src(src)
  if src then trash[#trash + 1] = { src = src, frame = frame } end
end

-- a source is freed only once its preview has certainly finished
local function process_trash()
  for i = #trash, 1, -1 do
    if frame - trash[i].frame > TRASH_FRAMES then
      reaper.PCM_Source_Destroy(trash[i].src)
      table.remove(trash, i)
    end
  end
end

--- EQ and compressor plugins
-- Previews run through a hidden temp track holding both JSFX,
-- which plays straight to the hardware outputs like a normal preview.
local FX_TRACK = 'yj_SoundPicker FX (temp)'
local JS_DIR   = RESOURCE .. SEP .. 'Effects' .. SEP .. 'yj_SoundPicker'
local GMEM     = 'yj_SoundPicker'

local EQ_KEYS = { 'e_hpf', 'e_lf', 'e_lg', 'e_mf', 'e_mg', 'e_mq', 'e_hf', 'e_hg', 'e_lpf', 'e_lq', 'e_hq' }
local EQ_DEF  = { e_hpf = 20, e_lf = 120, e_lg = 0, e_mf = 1000, e_mg = 0, e_mq = 0.8, e_hf = 8000, e_hg = 0, e_lpf = 20000, e_lq = 1, e_hq = 1 }
local CO_KEYS = { 'c_thr', 'c_ratio', 'c_att', 'c_rel', 'c_mk' }
local CO_DEF  = { c_thr = -20, c_ratio = 4, c_att = 10, c_rel = 150, c_mk = 0 }

local PLUGINS
do
  local JS_COEFS = [==[
// RBJ cookbook coefficients go into t0 t1 t2 / u0 u1 u2, then each filter loads them
function coef_lp(f, q) local(w, c, al) (
  w = 2 * $pi * f / srate; c = cos(w); al = sin(w) / (2 * q);
  t0 = (1 - c) / 2; t1 = 1 - c; t2 = (1 - c) / 2;
  u0 = 1 + al; u1 = -2 * c; u2 = 1 - al;
);
function coef_hp(f, q) local(w, c, al) (
  w = 2 * $pi * f / srate; c = cos(w); al = sin(w) / (2 * q);
  t0 = (1 + c) / 2; t1 = -(1 + c); t2 = (1 + c) / 2;
  u0 = 1 + al; u1 = -2 * c; u2 = 1 - al;
);
function coef_pk(f, g, q) local(w, c, al, A) (
  A = 10 ^ (g / 40); w = 2 * $pi * f / srate; c = cos(w); al = sin(w) / (2 * q);
  t0 = 1 + al * A; t1 = -2 * c; t2 = 1 - al * A;
  u0 = 1 + al / A; u1 = -2 * c; u2 = 1 - al / A;
);
function coef_ls(f, g) local(w, c, al, A, sq) (
  A = 10 ^ (g / 40); w = 2 * $pi * f / srate; c = cos(w); al = sin(w) / 2 * sqrt(2);
  sq = 2 * sqrt(A) * al;
  t0 = A * ((A + 1) - (A - 1) * c + sq); t1 = 2 * A * ((A - 1) - (A + 1) * c); t2 = A * ((A + 1) - (A - 1) * c - sq);
  u0 = (A + 1) + (A - 1) * c + sq; u1 = -2 * ((A - 1) + (A + 1) * c); u2 = (A + 1) + (A - 1) * c - sq;
);
function coef_hs(f, g) local(w, c, al, A, sq) (
  A = 10 ^ (g / 40); w = 2 * $pi * f / srate; c = cos(w); al = sin(w) / 2 * sqrt(2);
  sq = 2 * sqrt(A) * al;
  t0 = A * ((A + 1) + (A - 1) * c + sq); t1 = -2 * A * ((A - 1) + (A + 1) * c); t2 = A * ((A + 1) + (A - 1) * c - sq);
  u0 = (A + 1) - (A - 1) * c + sq; u1 = 2 * ((A - 1) - (A + 1) * c); u2 = (A + 1) - (A - 1) * c - sq;
);
function bq_load() instance(b0, b1, b2, a1, a2) (
  b0 = t0 / u0; b1 = t1 / u0; b2 = t2 / u0; a1 = u1 / u0; a2 = u2 / u0;
);
function bq_proc(x) instance(b0, b1, b2, a1, a2, z1, z2) local(y) (
  y = b0 * x + z1;
  z1 = b1 * x - a1 * y + z2;
  z2 = b2 * x - a2 * y;
  y;
);
]==]

  local JS_EQ_SRC = [==[
desc:SoundPicker EQ
//tags: equalizer
//author: yj_SoundPicker

slider1:hpf=20<20,2000,1>HPF Hz (20 is off)
slider2:lf=120<30,1000,1>Low bell Hz
slider3:lg=0<-15,15,0.1>Low bell dB
slider4:mf=1000<100,10000,1>Mid Hz
slider5:mg=0<-15,15,0.1>Mid dB
slider6:mq=0.8<0.3,6,0.01>Mid Q
slider7:hf=8000<1000,18000,1>High bell Hz
slider8:hg=0<-15,15,0.1>High bell dB
slider9:lpf=20000<1000,20000,1>LPF Hz (20000 is off)
slider10:lq=1<0.3,6,0.01>Low bell Q
slider11:hq=1<0.3,6,0.01>High bell Q

in_pin:left
in_pin:right
out_pin:left
out_pin:right

@init
]==] .. JS_COEFS .. [==[

@slider
nyq = srate * 0.45;
hp_on = hpf > 20.5;
hp_on ? ( coef_hp(min(hpf, nyq), 0.7071); hp0.bq_load(); hp1.bq_load(); );
lp_on = lpf < 19999 && lpf < nyq;
lp_on ? ( coef_lp(lpf, 0.7071); lp0.bq_load(); lp1.bq_load(); );
ls_on = abs(lg) > 0.05;
ls_on ? ( coef_pk(min(lf, nyq), lg, max(lq, 0.1)); ls0.bq_load(); ls1.bq_load(); );
pk_on = abs(mg) > 0.05 && mf < nyq;
pk_on ? ( coef_pk(mf, mg, max(mq, 0.1)); pk0.bq_load(); pk1.bq_load(); );
hs_on = abs(hg) > 0.05 && hf < nyq;
hs_on ? ( coef_pk(hf, hg, max(hq, 0.1)); hs0.bq_load(); hs1.bq_load(); );

@sample
hp_on ? ( spl0 = hp0.bq_proc(spl0); spl1 = hp1.bq_proc(spl1); );
lp_on ? ( spl0 = lp0.bq_proc(spl0); spl1 = lp1.bq_proc(spl1); );
ls_on ? ( spl0 = ls0.bq_proc(spl0); spl1 = ls1.bq_proc(spl1); );
pk_on ? ( spl0 = pk0.bq_proc(spl0); spl1 = pk1.bq_proc(spl1); );
hs_on ? ( spl0 = hs0.bq_proc(spl0); spl1 = hs1.bq_proc(spl1); );
]==]

  local JS_COMP_SRC = [==[
desc:SoundPicker Comp
//tags: compressor dynamics
//author: yj_SoundPicker
options:gmem=yj_SoundPicker

slider1:thr=-20<-60,0,0.1>Threshold (dB)
slider2:ratio=4<1,20,0.1>Ratio
slider3:att=10<0.1,200,0.1>Attack (ms)
slider4:rel=150<5,2000,1>Release (ms)
slider5:makeup=0<0,24,0.1>Makeup (dB)
slider6:meter=0<0,1,1>-Send meters to yj_SoundPicker

in_pin:left
in_pin:right
out_pin:left
out_pin:right

@init
grs = 0; peak = 0; grmax = 0; knee = 6;

@slider
ac = exp(-1 / (max(att, 0.05) * 0.001 * srate));
rc = exp(-1 / (max(rel, 1) * 0.001 * srate));
mk = 10 ^ (makeup / 20);

@block
meter > 0.5 ? (
  gmem[0] = 20 * log10(max(peak, 0.000001));
  gmem[1] = grmax;
  gmem[2] = gmem[2] + 1;
);
peak = 0; grmax = 0;

@sample
lvl = max(abs(spl0), abs(spl1));
peak = max(peak, lvl);
d = 20 * log10(max(lvl, 0.000001)) - thr;
2 * d < -knee ? ( grt = 0; ) : (
  2 * abs(d) <= knee ? ( grt = (1 - 1 / ratio) * (d + knee / 2) ^ 2 / (2 * knee); )
                     : ( grt = d * (1 - 1 / ratio); );
);
grt > grs ? ( grs = ac * grs + (1 - ac) * grt; ) : ( grs = rc * grs + (1 - rc) * grt; );
g = 10 ^ (-grs / 20) * mk;
spl0 *= g; spl1 *= g;
grmax = max(grmax, grs);
]==]

  PLUGINS = {
    eq   = { file = 'soundpicker_eq.jsfx',   src = JS_EQ_SRC,   desc = 'SoundPicker EQ' },
    comp = { file = 'soundpicker_comp.jsfx', src = JS_COMP_SRC, desc = 'SoundPicker Comp' },
  }
end

local function write_jsfx()
  reaper.RecursiveCreateDirectory(JS_DIR, 0)
  for _, pl in pairs(PLUGINS) do
    local path = JS_DIR .. SEP .. pl.file
    local fh = io.open(path, 'rb')
    local existing = fh and fh:read('a')
    if fh then fh:close() end
    if existing ~= pl.src then
      fh = io.open(path, 'wb')
      if fh then fh:write(pl.src); fh:close() end
    end
  end
end

local function fx_needed() return S.eq_on or S.comp_on end

local function add_plugin(tr, pl)
  for _, nm in ipairs({ 'JS:yj_SoundPicker/' .. pl.file, 'yj_SoundPicker/' .. pl.file, 'JS:' .. pl.desc }) do
    local idx = reaper.TrackFX_AddByName(tr, nm, false, -1)
    if idx >= 0 then return idx end
  end
  return -1
end

local fx_track = nil

local function fx_route(tr)
  tr = tr or fx_track
  if not tr or not reaper.ValidatePtr2(0, tr, 'MediaTrack*') then return end
  if reaper.GetTrackNumSends(tr, 1) == 0 then reaper.CreateTrackSend(tr, nil) end
  reaper.SetTrackSendInfo_Value(tr, 1, 0, 'I_DSTCHAN', math.floor(S.outpair) * 2)
end

local function find_fx_track()
  if fx_track and reaper.ValidatePtr2(0, fx_track, 'MediaTrack*') then return fx_track end
  fx_track = nil
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, nm = reaper.GetTrackName(tr)
    if nm == FX_TRACK then fx_track = tr; return tr end
  end
end

-- EQ is FX slot 0, comp is slot 1
local function apply_eq()
  local tr = find_fx_track()
  if not tr then return end
  for i, k in ipairs(EQ_KEYS) do reaper.TrackFX_SetParam(tr, 0, i - 1, S[k]) end
  reaper.TrackFX_SetEnabled(tr, 0, S.eq_on)
end
local function apply_comp()
  local tr = find_fx_track()
  if not tr then return end
  for i, k in ipairs(CO_KEYS) do reaper.TrackFX_SetParam(tr, 1, i - 1, S[k]) end
  reaper.TrackFX_SetParam(tr, 1, #CO_KEYS, 1) -- meters on for this instance only
  reaper.TrackFX_SetEnabled(tr, 1, S.comp_on)
end

local function ensure_fx_track()
  local tr = find_fx_track()
  if tr then return tr end
  reaper.PreventUIRefresh(1)
  local n = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(n, false)
  tr = reaper.GetTrack(0, n)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', FX_TRACK, true)
  reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0)
  reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 0)
  reaper.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', 0)
  reaper.SetMediaTrackInfo_Value(tr, 'B_SOLO_DEFEAT', 1)
  fx_route(tr)
  local e = add_plugin(tr, PLUGINS.eq)
  local c = add_plugin(tr, PLUGINS.comp)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  if e ~= 0 or c ~= 1 then
    reaper.DeleteTrack(tr)
    notify('Could not load the SoundPicker EQ / Comp plugins (Effects/yj_SoundPicker).')
    return nil
  end
  fx_track = tr
  apply_eq()
  apply_comp()
  return tr
end

local function delete_fx_tracks()
  reaper.PreventUIRefresh(1)
  local i = 0
  while true do
    local proj = reaper.EnumProjects(i)
    if not proj then break end
    for t = reaper.CountTracks(proj) - 1, 0, -1 do
      local tr = reaper.GetTrack(proj, t)
      local _, nm = reaper.GetTrackName(tr)
      if nm == FX_TRACK then reaper.DeleteTrack(tr) end
    end
    i = i + 1
  end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  fx_track = nil
end

-- input peak dB and gain reduction dB, from the comp JSFX
local meter_in, meter_gr, meter_beat, meter_time = -120, 0, -1, 0
reaper.gmem_attach(GMEM)
local function read_meters()
  local beat = reaper.gmem_read(2)
  local now = reaper.time_precise()
  if beat ~= meter_beat then
    meter_beat, meter_time = beat, now
    meter_in, meter_gr = reaper.gmem_read(0), reaper.gmem_read(1)
  elseif now - meter_time > 0.25 then
    meter_in, meter_gr = -120, 0
  end
end

-- reverse uses a section source (SWS 2.13.2+); the section owns the file source
local HAS_SECTION = reaper.CF_PCM_Source_SetSectionInfo ~= nil and reaper.PCM_Source_CreateFromType ~= nil

local function reversed_source(src, offs, len)
  if not HAS_SECTION then return nil end
  local sec = reaper.PCM_Source_CreateFromType('SECTION')
  if not sec then return nil end
  if not reaper.CF_PCM_Source_SetSectionInfo(sec, src, offs or 0, len or 0, true) then
    reaper.PCM_Source_Destroy(sec)
    return nil
  end
  return sec
end

local function source_len()
  if not cur then return 0 end
  return (wf and wf.len and wf.len > 0 and wf.len) or cur.len or 0
end

-- with Preserve pitch off, pitch changes the speed like tape
local function eff_rate()
  if S.fit > 0 and cur then
    local l = (sel_a and sel_b) and (sel_b - sel_a) or source_len()
    if l > 0 then return math.max(0.05, math.min(20, l / S.fit)) end
  end
  if S.ppitch then return 1 end
  return math.max(0.05, math.min(20, 2 ^ (S.pitch / 12)))
end

-- SWS counts the preview position in playback time when the rate is not 1
-- (poll_preview double-checks this, in case an SWS version differs)
UI.out_time, UI.prate = true, 1
function UI.to_raw(p) return UI.out_time and p / UI.prate or p end
function UI.from_raw(p) return UI.out_time and p * UI.prate or p end

local function apply_preview_params()
  if not preview then return end
  reaper.CF_Preview_SetValue(preview, 'D_VOLUME', 10 ^ ((S.vol_db + S.mon_db) / 20))
  -- SWS does not drop the pitch reliably with preserve pitch off, so it is set by hand
  local rate = eff_rate()
  local pitch = S.pitch
  if not S.ppitch then pitch = 12 * math.log(rate, 2) end
  reaper.CF_Preview_SetValue(preview, 'B_PPITCH', 1)
  local old = UI.prate
  reaper.CF_Preview_SetValue(preview, 'D_PLAYRATE', rate)
  reaper.CF_Preview_SetValue(preview, 'D_PITCH', pitch)
  UI.prate, UI.det = rate, nil
  if playing and math.abs(old - rate) > 1e-6 then -- keep the playhead where it is when the speed changes
    reaper.CF_Preview_SetValue(preview, 'D_POSITION', UI.to_raw(play_pos))
  end
  reaper.CF_Preview_SetValue(preview, 'B_LOOP', (S.loop and not sel_a) and 1 or 0)
end

local function stop()
  if preview then
    reaper.CF_Preview_Stop(preview)
    last_stop_frame = frame
  end
  preview, playing = nil, false
  trash_src(preview_src)
  preview_src = nil
end

local function play(pos)
  if not cur then return end
  autoplay_pending = nil
  stop()
  if not reaper.file_exists(cur.path) then
    notify('File not found (drive offline?)')
    return
  end
  preview_src = reaper.PCM_Source_CreateFromFile(cur.path)
  if not preview_src then return end
  if S.reverse then preview_src = reversed_source(preview_src) or preview_src end
  preview = reaper.CF_CreatePreview(preview_src)
  if not preview then return end
  local fx_tr = fx_needed() and ensure_fx_track() or nil
  if fx_tr then
    reaper.CF_Preview_SetOutputTrack(preview, 0, fx_tr)
  else
    reaper.CF_Preview_SetValue(preview, 'I_OUTCHAN', math.floor(S.outpair) * 2)
  end
  apply_preview_params()
  play_pos = pos or 0
  UI.det = nil
  reaper.CF_Preview_SetValue(preview, 'D_POSITION', UI.to_raw(play_pos))
  reaper.CF_Preview_Play(preview)
  playing = true
end

local function resume()
  if sel_a then return play(sel_a) end
  local len = source_len()
  local p = play_pos
  if len > 0 and p >= len - 0.05 then p = 0 end
  play(p)
end

local function toggle_play()
  if playing then stop() else resume() end
end

-- reverse mirrors the selection and the playhead
local function set_reverse(v)
  if v == S.reverse then return end
  local len = source_len()
  if len > 0 then
    if sel_a and sel_b then sel_a, sel_b = len - sel_b, len - sel_a end
    play_pos = math.max(0, len - play_pos)
  end
  S.reverse = v
  if playing then play(play_pos) end
end

local function poll_preview()
  if not preview then return end
  local ok, pos = reaper.CF_Preview_GetValue(preview, 'D_POSITION')
  if not ok then
    -- finished on its own
    preview, playing = nil, false
    last_stop_frame = frame
    trash_src(preview_src)
    preview_src = nil
    return
  end
  -- does SWS count in file time or playback time?
  local now = reaper.time_precise()
  if math.abs(UI.prate - 1) >= 0.3 then
    local d = UI.det
    if not d or pos < d.raw then
      UI.det = { t = now, raw = pos }
    elseif now - d.t >= 0.3 then
      local speed = (pos - d.raw) / (now - d.t)
      UI.out_time = math.abs(speed - 1) < math.abs(speed - UI.prate)
      UI.det = { t = now, raw = pos }
    end
  end
  pos = UI.from_raw(pos)
  play_pos = pos
  if sel_a and sel_b and pos >= sel_b then
    if S.loop then
      UI.det = nil
      reaper.CF_Preview_SetValue(preview, 'D_POSITION', UI.to_raw(sel_a))
    else
      stop()
      play_pos = sel_a
    end
  end
end

--- Waveform
local wf_job = nil

-- spectral peaks are the third block: low 15 bits = frequency in Hz
local function read_peaks(src, len, nch)
  local N = WAVE_POINTS
  local want = S.spectral and 115 or 0 -- 's'
  local buf = reaper.new_array(N * nch * (want ~= 0 and 3 or 2))
  local rv = math.floor(reaper.PCM_Source_GetPeaks(src, N / len, 0, nch, N, want, buf))
  local got = rv % 1048576
  if got <= 0 then return nil end
  local has_spec = want ~= 0 and (rv & 0x1000000) ~= 0
  local t = buf.table()
  local base = N * nch * 2
  local chans = {}
  for c = 1, nch do
    local mx, mn, col = {}, {}, has_spec and {} or nil
    for i = 0, got - 1 do
      mx[i + 1] = t[i * nch + c] or 0
      mn[i + 1] = t[N * nch + i * nch + c] or 0
      if col then
        local v = math.floor(t[base + i * nch + c] or -1)
        local freq = v >= 0 and (v & 0x7FFF) or 0
        -- quarter-octave steps, coloured when drawn
        if freq > 0 then col[i + 1] = math.floor(math.log(freq, 2) * 4 + 0.5) end
      end
    end
    chans[c] = { max = mx, min = mn, col = col }
  end
  return { ch = chans, n = got, len = len, nospec = (want ~= 0 and not has_spec) }
end

local function cancel_wf_job()
  if not wf_job then return end
  reaper.PCM_Source_BuildPeaks(wf_job.src, 2)
  reaper.PCM_Source_Destroy(wf_job.src)
  wf_job = nil
end

local function load_waveform(f)
  cancel_wf_job()
  wf = nil
  if not reaper.file_exists(f.path) then
    wf = { ch = {}, n = 0, len = 0, offline = true }
    return
  end
  local src = reaper.PCM_Source_CreateFromFile(f.path)
  if not src then return end
  local len = (reaper.GetMediaSourceLength(src))
  local nch = math.max(1, math.min(reaper.GetMediaSourceNumChannels(src), 8))
  if len <= 0 or len > MAX_WAVE_LEN then
    reaper.PCM_Source_Destroy(src)
    wf = { ch = {}, n = 0, len = len }
    return
  end
  local w = read_peaks(src, len, nch)
  if w then
    reaper.PCM_Source_Destroy(src)
    wf = w
    return
  end
  if reaper.PCM_Source_BuildPeaks(src, 0) ~= 0 then
    wf = { ch = {}, n = 0, len = len, building = true }
    wf_job = { src = src, f = f, len = len, nch = nch }
  else
    wf = read_peaks(src, len, nch) or { ch = {}, n = 0, len = len }
    reaper.PCM_Source_Destroy(src)
  end
end

local function process_wf_job()
  if not wf_job then return end
  local t0 = reaper.time_precise()
  while reaper.time_precise() - t0 < 0.012 do
    if reaper.PCM_Source_BuildPeaks(wf_job.src, 1) == 0 then
      reaper.PCM_Source_BuildPeaks(wf_job.src, 2)
      local w = read_peaks(wf_job.src, wf_job.len, wf_job.nch)
      reaper.PCM_Source_Destroy(wf_job.src)
      if wf_job.f == cur then wf = w or { ch = {}, n = 0, len = wf_job.len } end
      wf_job = nil
      return
    end
  end
end

-- the waveform loads on the next frame
local function select_index(i)
  if i < 1 or i > #results then return end
  sel_idx = i
  local f = get_info(results[i])
  if f ~= cur then
    stop()
    cancel_wf_job()
    cur = f
    wf = nil
    sel_a, sel_b = nil, nil
    play_pos = 0
    wf_request = f
    -- EQ and comp start fresh for every sound
    for k, v in pairs(EQ_DEF) do S[k] = v end
    for k, v in pairs(CO_DEF) do S[k] = v end
    S.eq_on, S.comp_on = false, false
    apply_eq()
    apply_comp()
  end
  autoplay_pending = S.autoplay and f or nil
end

--- Spot to project
local function target_track()
  local tr = reaper.GetSelectedTrack2(0, 0, false)
  if tr then return tr end
  tr = reaper.GetLastTouchedTrack()
  if tr and tr ~= reaper.GetMasterTrack(0) then return tr end
end

-- reuses an earlier copy of the same file, never overwrites
local function copy_to_project(path)
  local dir = reaper.GetProjectPath()
  if dir == '' then return path end
  reaper.RecursiveCreateDirectory(dir, 0)
  local function norm(p) return (p:gsub('[/\\]+', '/'):gsub('/$', ''):lower()) end
  if norm(path:match('^(.*)[/\\]') or '') == norm(dir) then return path end -- already there
  local function fsize(p)
    local fh = io.open(p, 'rb')
    if not fh then return nil end
    local n = fh:seek('end'); fh:close(); return n
  end
  local want = fsize(path)
  if not want then return path end
  local name = basename(path)
  local stem, ext = name:match('^(.*)(%.[^.]+)$')
  if not stem then stem, ext = name, '' end
  local dest, n = dir .. SEP .. name, 1
  while reaper.file_exists(dest) do
    if fsize(dest) == want then return dest end
    n = n + 1
    dest = dir .. SEP .. stem .. ' (' .. n .. ')' .. ext
  end
  local fin = io.open(path, 'rb')
  local fout = fin and io.open(dest, 'wb')
  if not (fin and fout) then
    if fin then fin:close() end
    notify('Could not copy into the project media folder, so the original file was used.')
    return path
  end
  while true do
    local chunk = fin:read(4194304)
    if not chunk then break end
    fout:write(chunk)
  end
  fin:close(); fout:close()
  return dest
end

-- whole: ignore the waveform selection (dragging a row from the list)
local function spot(track_in, pos_in, whole)
  if not cur then return end
  local track = track_in or target_track()
  if not track then
    notify('Select a track first: yj_SoundPicker spots onto the selected track at the edit cursor.')
    return
  end
  if not reaper.file_exists(cur.path) then
    notify('File not found (drive offline?)')
    return
  end
  reaper.Undo_BeginBlock()
  local path = cur.path
  if S.copy and not S.glue then path = copy_to_project(path) end -- glue makes its own new file
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then reaper.Undo_EndBlock('yj_SoundPicker: spot', -1) return end

  reaper.PreventUIRefresh(1)

  local srclen = (reaper.GetMediaSourceLength(src))
  local s, e = 0, srclen
  if not whole and sel_a and sel_b and sel_b - sel_a > 0.001 then s, e = sel_a, sel_b end
  local startoffs = s
  if S.reverse then
    -- s..e are on the reversed timeline: that is the file's (len-e)..(len-s), played backwards
    local sec = reversed_source(src, srclen - e, e - s)
    if sec then src, startoffs = sec, 0 end
  end
  local rate = eff_rate()
  local pos = pos_in or reaper.GetCursorPosition()

  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src) -- take now owns src
  reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', startoffs)
  reaper.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE', rate)
  reaper.SetMediaItemTakeInfo_Value(take, 'D_PITCH', S.ppitch and S.pitch or 0) -- tape mode: pitch is in the rate
  reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', S.ppitch and 1 or 0)
  reaper.SetMediaItemTakeInfo_Value(take, 'D_VOL', 10 ^ (S.vol_db / 20))
  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', S.reverse and (cur.name .. ' (reversed)') or cur.name, true)
  local ilen = (e - s) / rate
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', pos)
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', ilen)

  local fx_tr = fx_needed() and find_fx_track()
  if fx_tr then
    if S.eq_on then reaper.TrackFX_CopyToTake(fx_tr, 0, take, reaper.TakeFX_GetCount(take), false) end
    if S.comp_on then reaper.TrackFX_CopyToTake(fx_tr, 1, take, reaper.TakeFX_GetCount(take), false) end
  end

  reaper.UpdateItemInProject(item)

  if S.glue then
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(item, true)
    reaper.Main_OnCommand(GLUE_CMD, 0)
  end

  reaper.Main_OnCommand(PEAKS_CMD, 0)
  if S.advance and not pos_in then reaper.SetEditCurPos(pos + ilen, true, false) end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('yj_SoundPicker: spot ' .. cur.name, -1)
  return pos + ilen
end

function MS.spot_many(list, track_in, pos_in)
  if #list > 40 and reaper.MB(('Spot %d files one after another?'):format(#list), 'yj_SoundPicker', 4) ~= 6 then return end
  local track = track_in or target_track()
  if not track then return end
  local keep = cur
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local p = pos_in or reaper.GetCursorPosition()
  for _, k in ipairs(list) do
    cur = get_info(k)
    local e = spot(track, p, true)
    if e then p = e end
  end
  cur = keep
  if S.advance and not pos_in then reaper.SetEditCurPos(p, true, false) end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(('yj_SoundPicker: spot %d files'):format(#list), -1)
end

local function spot_selected()
  local list = MS.list()
  if list then MS.spot_many(list) else spot() end
end

-- while dragging over the arrange view, a locked ghost item shows where the file will land
local drag_out = nil

local function ghost_remove(d)
  if not d or not d.ghosts then return end
  for _, g in ipairs(d.ghosts) do
    if reaper.ValidatePtr2(0, g.item, 'MediaItem*') then
      reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(g.item), g.item)
    end
  end
  d.ghosts = nil
  reaper.UpdateArrange()
end

local function drop_target()
  local win = reaper.BR_GetMouseCursorContext()
  local tr = reaper.BR_GetMouseCursorContext_Track()
  if not tr or (win ~= 'arrange' and win ~= 'tcp') then return end
  local pos = reaper.GetCursorPosition()
  if win == 'arrange' then
    pos = reaper.BR_GetMouseCursorContext_Position()
    if reaper.GetToggleCommandState(1157) == 1 then pos = reaper.SnapToGrid(0, pos) end -- snap
  end
  return tr, math.max(0, pos)
end

local ghost_update
do
  local MAX_GHOSTS = 24
  local function make_ghost(f, tr, s_off, e_off)
    if not f or not reaper.file_exists(f.path) then return end
    local src = reaper.PCM_Source_CreateFromFile(f.path)
    if not src then return end
    local srclen = (reaper.GetMediaSourceLength(src))
    local s, e = s_off or 0, e_off or srclen
    local rate = eff_rate()
    local item = reaper.AddMediaItemToTrack(tr)
    local take = reaper.AddTakeToMediaItem(item)
    reaper.SetMediaItemTake_Source(take, src)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', s)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_PLAYRATE', rate)
    reaper.SetMediaItemTakeInfo_Value(take, 'D_VOL', 10 ^ (S.vol_db / 20)) -- REAPER draws the waveform at this level
    if reaper.GetPlayState() & 1 == 1 then reaper.SetMediaItemInfo_Value(item, 'B_MUTE', 1) end -- silent during playback
    reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', (e - s) / rate)
    reaper.SetMediaItemInfo_Value(item, 'C_LOCK', 1)
    reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', reaper.ColorToNative(232, 168, 184) | 0x1000000)
    reaper.SetMediaItemSelected(item, false)
    reaper.UpdateItemInProject(item)
    return { item = item, len = (e - s) / rate }
  end

  ghost_update = function(d, tr, pos)
    if not d.ghosts then
      d.ghosts = {}
      if d.keys then -- several files: one ghost each, end to end
        for n, k in ipairs(d.keys) do
          if n > MAX_GHOSTS then break end
          local g = make_ghost(get_info(k), tr)
          if g then d.ghosts[#d.ghosts + 1] = g end
        end
      else
        local s_off, e_off
        if not d.whole and sel_a and sel_b and sel_b - sel_a > 0.001 and cur then
          local srclen = cur.len or sel_b
          s_off, e_off = sel_a, sel_b
          if S.reverse then s_off, e_off = srclen - sel_b, srclen - sel_a end
        end
        local g = make_ghost(cur, tr, s_off, e_off)
        if g then d.ghosts[1] = g end
      end
      d.gtr = tr
      reaper.Main_OnCommand(PEAKS_CMD, 0) -- so the ghosts show their waveforms
    elseif d.gtr ~= tr then
      for _, g in ipairs(d.ghosts) do reaper.MoveMediaItemToTrack(g.item, tr) end
      d.gtr = tr
    end
    local p = pos
    for _, g in ipairs(d.ghosts) do
      reaper.SetMediaItemInfo_Value(g.item, 'D_POSITION', p)
      reaper.UpdateItemInProject(g.item)
      p = p + g.len
    end
    reaper.UpdateArrange()
  end
end

local function handle_drop(ctx)
  if not drag_out then return end
  local d = drag_out
  local down = ImGui.IsMouseDown(ctx, ImGui.MouseButton_Left)
  if reaper.JS_Mouse_GetState then down = (reaper.JS_Mouse_GetState(1) & 1) == 1 end
  if down then
    local tr, pos = drop_target()
    if tr then
      d.tr, d.pos = tr, pos
      ghost_update(d, tr, pos)
    else
      d.tr, d.pos = nil, nil
      ghost_remove(d)
    end
    return
  end
  drag_out = nil
  local tr, pos = d.tr, d.pos
  ghost_remove(d)
  if not cur or not tr or not reaper.ValidatePtr2(0, tr, 'MediaTrack*') then return end
  if d.keys then MS.spot_many(d.keys, tr, pos) else spot(tr, pos, d.whole) end
end

--- UI
local HELP = [[
yj_SoundPicker  help

SEARCH
  door wood            both words
  whoosh OR swish      either (comma works too: whoosh,swish)
  impact NOT metal     exclude (or: impact -metal)
  "glass break"        exact phrase
  name:  desc:  lib:  cat:  path:  db:   search one field only
  (lib: = library or maker, cat: = genre / UCS category)
  The Filters dropdown does the same with checkboxes.

TOKENS (specs stored in your databases)
  48k  48k+  44k-      sample rate (close / at least / at most)
  1ch  2ch+            channels
  24b  16b-            bit depth
  2s  0.5s-  10s+  3s= length (close / max / min / exact)
  Searches with a word are fastest: "impact 48k+" beats "48k+" alone.
  The dice button shuffles the results into a random order.

KEYS (when this window has focus)
  Up / Down   browse
  Space       play / stop (resumes from the playhead)
  S or Enter  spot to the selected track at the edit cursor
  Double-click a result to spot it

WAVEFORM
  Click to play from that point, drag to select a range (0.5 s or longer).
  Spot inserts only the selected range when there is one.
  Drag the selection, or a result from the list, onto a track to drop it there.
  Ctrl+click picks several results, Shift+click (or Shift+arrows) picks a run of them.
  Spot, S and dragging then place them one after another.
  Ctrl+click (or right-click) a slider to reset it.]]

local ctx = ImGui.CreateContext('yj_SoundPicker')
local clipper = ImGui.CreateListClipper(ctx)
ImGui.Attach(ctx, clipper)

--- Themes
local T, push_theme, pop_theme
do
  local THEMES = {
    rose_light = {
      cols = {
        Text = 0x2B171DFF, TextDisabled = 0x5E3D46FF,
        WindowBg = 0xD6A7A7FF, ChildBg = 0x00000000, PopupBg = 0xE1B7B7FF,
        Border = 0xB38285FF, BorderShadow = 0x00000000,
        FrameBg = 0xDFB3B3FF, FrameBgHovered = 0xE4BEBEFF, FrameBgActive = 0xE8C9C9FF,
        TitleBg = 0xC39194FF, TitleBgActive = 0xB17D81FF, TitleBgCollapsed = 0xC39194FF,
        MenuBarBg = 0xCD9B9CFF,
        ScrollbarBg = 0xCD9B9CFF, ScrollbarGrab = 0xB8898CFF,
        ScrollbarGrabHovered = 0xAA7C80FF, ScrollbarGrabActive = 0x9C6F73FF,
        CheckMark = 0x6E3A4AFF, SliderGrab = 0xB17D81FF, SliderGrabActive = 0x98646EFF,
        Button = 0xE2BBBBFF, ButtonHovered = 0xE7C5C5FF, ButtonActive = 0xEBD0D0FF,
        Header = 0xF7E6E8FF, HeaderHovered = 0xE1B7B7FF, HeaderActive = 0xFAEEEFFF,
        Separator = 0xB38285FF, SeparatorHovered = 0x9C6F73FF, SeparatorActive = 0x6E3A4AFF,
        ResizeGrip = 0xC39194FF, ResizeGripHovered = 0xAA7C80FF, ResizeGripActive = 0x98646EFF,
        Tab = 0xC39194FF, TabHovered = 0xE4C0C0FF, TabActive = 0xB17D81FF,
        TabUnfocused = 0xC39194FF, TabUnfocusedActive = 0xB8898CFF,
        TableHeaderBg = 0xCD9B9CFF, TableBorderStrong = 0xB38285FF, TableBorderLight = 0xC69899FF,
        TableRowBg = 0x00000000, TableRowBgAlt = 0xD2A2A3FF,
        TextSelectedBg = 0xE8C9C9FF, NavHighlight = 0x6E3A4AFF,
        DockingPreview = 0x88546466, DockingEmptyBg = 0xD6A7A7FF,
      },
      wave_bg = 0x945763FF, wave = 0xF3CDD4FF, sel = 0xFFFFFF33,
      playhead = 0xFFE9C9FF, wave_msg = 0xE3BFC5FF,
      grid = 0xA86B77FF, grid_text = 0xE9C4CAFF, curve = 0xFBDAE0FF, glow = 0xFFDDB0FF,
      ok = 0x24503FFF, warn = 0x5E1A2AFF,
      on = 0x6E3A4AFF, icon = 0x2B171DFF, icon_on = 0xFAEEEFFF,
      heart = 0x965266FF, sparkle = 0xBB744DFF, taskbar = 0xCD9B9CFF,
    },
    sage_light = {
      cols = {
        Text = 0x262B23FF, TextDisabled = 0x4F5749FF,
        WindowBg = 0xB0B8AAFF, ChildBg = 0x00000000, PopupBg = 0xBDC4B7FF,
        Border = 0x8F9689FF, BorderShadow = 0x00000000,
        FrameBg = 0xBAC2B4FF, FrameBgHovered = 0xC1C8BCFF, FrameBgActive = 0xC8CFC4FF,
        TitleBg = 0x9DA597FF, TitleBgActive = 0x8B9386FF, TitleBgCollapsed = 0x9DA597FF,
        MenuBarBg = 0xA6AEA0FF,
        ScrollbarBg = 0xA6AEA0FF, ScrollbarGrab = 0x949C8FFF,
        ScrollbarGrabHovered = 0x888F83FF, ScrollbarGrabActive = 0x7B8277FF,
        CheckMark = 0x50584BFF, SliderGrab = 0x8B9386FF, SliderGrabActive = 0x798074FF,
        Button = 0xBFC6BAFF, ButtonHovered = 0xC6CDC1FF, ButtonActive = 0xCDD3C9FF,
        Header = 0xDDE2DAFF, HeaderHovered = 0xBDC4B7FF, HeaderActive = 0xE2E7DFFF,
        Separator = 0x8F9689FF, SeparatorHovered = 0x7B8277FF, SeparatorActive = 0x50584BFF,
        ResizeGrip = 0x9DA597FF, ResizeGripHovered = 0x888F83FF, ResizeGripActive = 0x798074FF,
        Tab = 0x9DA597FF, TabHovered = 0xC2C9BEFF, TabActive = 0x8B9386FF,
        TabUnfocused = 0x9DA597FF, TabUnfocusedActive = 0x949C8FFF,
        TableHeaderBg = 0xA6AEA0FF, TableBorderStrong = 0x8F9689FF, TableBorderLight = 0xA2A99CFF,
        TableRowBg = 0x00000000, TableRowBgAlt = 0xACB4A6FF,
        TextSelectedBg = 0xC8CFC4FF, NavHighlight = 0x50584BFF,
        DockingPreview = 0x6A716566, DockingEmptyBg = 0xB0B8AAFF,
      },
      wave_bg = 0x71796BFF, wave = 0xCFD7C9FF, sel = 0xFFFFFF33,
      playhead = 0xFFE9C9FF, wave_msg = 0xC1C8BDFF,
      grid = 0x7F8878FF, grid_text = 0xC6CEC1FF, curve = 0xD9E1D3FF, glow = 0xFFDDB0FF,
      ok = 0x24503FFF, warn = 0x5E1A2AFF,
      on = 0x50584BFF, icon = 0x262B23FF, icon_on = 0xEEF1ECFF,
      heart = 0x965266FF, sparkle = 0xBB744DFF, taskbar = 0xA6AEA0FF,
    },
  }

  local STYLE_VARS = {
    { 'WindowRounding', 8 }, { 'ChildRounding', 6 }, { 'FrameRounding', 6 },
    { 'PopupRounding', 6 }, { 'ScrollbarRounding', 6 }, { 'GrabRounding', 4 },
    { 'TabRounding', 6 }, { 'WindowPadding', 12, 10 }, { 'FramePadding', 9, 5 },
    { 'ItemSpacing', 8, 7 }, { 'CellPadding', 7, 4 }, { 'FrameBorderSize', 1 },
    { 'WindowBorderSize', 1 }, { 'PopupBorderSize', 1 }, { 'ScrollbarSize', 12 },
    { 'GrabMinSize', 10 },
  }

  local resolved = {}
  local function resolve(th)
    local list = {}
    for name, col in pairs(th.cols) do list[#list + 1] = { ImGui['Col_' .. name], col } end
    return list
  end
  local style_list = {}
  for _, v in ipairs(STYLE_VARS) do style_list[#style_list + 1] = { ImGui['StyleVar_' .. v[1]], v[2], v[3] } end

  -- spectral colour stops: Hz, R, G, B
  local SPEC = {
    pastel  = { { 60, 0xFF, 0xCF, 0xDC }, { 200, 0xFF, 0xD0, 0xAE }, { 700, 0xFF, 0xEE, 0xAE },
                { 2000, 0xC9, 0xF2, 0xCF }, { 5000, 0xBE, 0xE0, 0xFF }, { 12000, 0xDD, 0xCC, 0xFF } },
    sage    = { { 60, 0xD9, 0xE7, 0xB0 }, { 200, 0xF1, 0xE3, 0xA6 }, { 700, 0xBF, 0xE6, 0xC8 },
                { 2000, 0xB4, 0xDD, 0xE0 }, { 5000, 0xC9, 0xD3, 0xF2 }, { 12000, 0xE6, 0xD3, 0xEE } },
    rainbow = { { 60, 0xFF, 0x6B, 0x6B }, { 200, 0xFF, 0xA9, 0x4D }, { 700, 0xFF, 0xE0, 0x66 },
                { 2000, 0x69, 0xDB, 0x7C }, { 5000, 0x4D, 0xAB, 0xF7 }, { 12000, 0xB1, 0x97, 0xFC } },
    mono_light = { { 60, 0x35, 0x44, 0x60 }, { 300, 0x47, 0x51, 0x62 }, { 1500, 0x55, 0x55, 0x55 },
                   { 5000, 0x6B, 0x5C, 0x3E }, { 12000, 0x7E, 0x66, 0x3C } },
    mono_dark  = { { 60, 0x6B, 0x80, 0x9E }, { 300, 0x92, 0x9F, 0xB0 }, { 1500, 0xC2, 0xC2, 0xBE },
                   { 5000, 0xE2, 0xD2, 0xA8 }, { 12000, 0xF7, 0xE4, 0xB4 } },
  }
  THEMES.rose_light.spec, THEMES.sage_light.spec = SPEC.pastel, SPEC.sage

  local function mx(a, b, t) -- blend two 0xRRGGBB colours
    local r1, g1, b1 = (a >> 16) & 255, (a >> 8) & 255, a & 255
    local r2, g2, b2 = (b >> 16) & 255, (b >> 8) & 255, b & 255
    return (math.floor(r1 + (r2 - r1) * t + 0.5) << 16) | (math.floor(g1 + (g2 - g1) * t + 0.5) << 8)
      | math.floor(b1 + (b2 - b1) * t + 0.5)
  end
  local function A(c, a) return (c << 8) | (a or 0xFF) end

  -- a full theme from a handful of colours
  local function build(p)
    local L = p.light
    local function up(t) return mx(p.bg, 0xFFFFFF, t) end
    local function dn(t) return mx(p.bg, 0x000000, t) end
    local edge = p.edge or (L and dn(0.2) or up(0.16))
    local frame = p.frame or (L and up(0.35) or up(0.07))
    local button = p.button or (L and up(0.3) or up(0.1))
    local thead = p.thead or (L and dn(0.07) or up(0.05))
    return {
      cols = {
        Text = A(p.text), TextDisabled = A(p.dim),
        WindowBg = A(p.bg), ChildBg = 0, PopupBg = A(L and up(0.4) or up(0.06)),
        Border = A(edge), BorderShadow = 0,
        FrameBg = A(frame), FrameBgHovered = A(mx(frame, L and 0xFFFFFF or p.text, 0.12)),
        FrameBgActive = A(mx(frame, L and 0xFFFFFF or p.text, 0.2)),
        TitleBg = A(L and dn(0.1) or dn(0.3)), TitleBgActive = A(L and dn(0.18) or dn(0.45)),
        TitleBgCollapsed = A(L and dn(0.1) or dn(0.3)), MenuBarBg = A(thead),
        ScrollbarBg = A(L and dn(0.05) or dn(0.2)), ScrollbarGrab = A(edge),
        ScrollbarGrabHovered = A(mx(edge, p.accent, 0.4)), ScrollbarGrabActive = A(p.accent),
        CheckMark = A(p.accent), SliderGrab = A(p.grab or mx(p.accent, p.bg, 0.25)), SliderGrabActive = A(p.accent),
        Button = A(button), ButtonHovered = A(mx(button, L and 0xFFFFFF or p.text, 0.15)),
        ButtonActive = A(mx(button, L and 0xFFFFFF or p.text, 0.25)),
        Header = A(p.sel), HeaderHovered = A(mx(p.bg, p.sel, 0.45)), HeaderActive = A(mx(p.sel, 0xFFFFFF, 0.15)),
        Separator = A(edge), SeparatorHovered = A(mx(edge, p.accent, 0.5)), SeparatorActive = A(p.accent),
        ResizeGrip = A(edge), ResizeGripHovered = A(mx(edge, p.accent, 0.5)), ResizeGripActive = A(p.accent),
        Tab = A(L and dn(0.1) or up(0.04)), TabHovered = A(button), TabActive = A(L and dn(0.18) or up(0.12)),
        TabUnfocused = A(L and dn(0.1) or up(0.04)), TabUnfocusedActive = A(L and dn(0.14) or up(0.08)),
        TableHeaderBg = A(thead), TableBorderStrong = A(edge), TableBorderLight = A(mx(edge, p.bg, 0.5)),
        TableRowBg = 0, TableRowBgAlt = A(p.alt or (L and dn(0.025) or up(0.025))),
        TextSelectedBg = A(mx(p.bg, p.accent, 0.4)), NavHighlight = A(p.accent),
        DockingPreview = A(p.accent, 0x66), DockingEmptyBg = A(p.bg),
      },
      wave_bg = A(p.screen), wave = A(p.wave), sel = p.screen_light and 0x0000001F or 0xFFFFFF33,
      playhead = A(p.playhead or 0xFFE9C9), wave_msg = A(mx(p.wave, p.screen, 0.3)),
      grid = A(mx(p.screen, p.wave, 0.15)), grid_text = A(mx(p.screen, p.wave, 0.65)),
      curve = A(p.wave), glow = A(p.glow or 0xFFDDB0),
      ok = A(L and 0x24503F or 0x8FD3B0), warn = A(L and 0x7A2235 or 0xF29AAE),
      on = A(p.accent), icon = A(p.text), icon_on = A(L and 0xFFFFFF or p.bg),
      heart = A(p.heart), sparkle = A(p.sparkle), taskbar = A(L and dn(0.05) or up(0.03)),
      spec = p.spec,
    }
  end

  THEMES.rose_dark = build { bg = 0x2C2125, text = 0xF1DDE1, dim = 0xB59BA2, accent = 0xE09AAD,
    sel = 0x5A3A44, screen = 0x1E1619, wave = 0xF0C3CE, heart = 0xE58FA6, sparkle = 0xF2B48C, spec = SPEC.pastel }
  THEMES.sage_dark = build { bg = 0x232822, text = 0xE0E8DC, dim = 0xA3AE9E, accent = 0xA9C79E,
    sel = 0x3D4A39, screen = 0x171B16, wave = 0xCFE0C6, heart = 0xE58FA6, sparkle = 0xE8C98A, spec = SPEC.sage }
  THEMES.rainbow_light = build { light = true, bg = 0xF6F1F8, text = 0x2A2433, dim = 0x6E6578, accent = 0x9B6FD6,
    sel = 0xFFE7A3, frame = 0xFFFFFF, button = 0xD7ECFF, thead = 0xFFD9C2, alt = 0xF0EAF4, grab = 0xFF9AAE,
    edge = 0xC9BED3, screen = 0x2F2A45, wave = 0xF4E9FF, heart = 0xE0607E, sparkle = 0xF0A04B,
    spec = SPEC.rainbow }
  THEMES.rainbow_dark = build { bg = 0x1F1F21, text = 0xF0F0F2, dim = 0xA2A2A8, accent = 0xC3A6FF,
    sel = 0x3C3746, frame = 0x2B2B2E, button = 0x2F2F33, thead = 0x272729, grab = 0xFF8FA3,
    screen = 0x0D0D0E, wave = 0xEDE6FF, heart = 0xFF7F9A, sparkle = 0xFFB86B, spec = SPEC.rainbow }
  THEMES.simple_light = build { light = true, bg = 0xEDEDED, text = 0x111111, dim = 0x6B6B6B, accent = 0x222222,
    sel = 0xFFFFFF, screen = 0xDADADA, screen_light = true, wave = 0x222222, playhead = 0x000000, glow = 0x555555,
    heart = 0x333333, sparkle = 0x555555, spec = SPEC.mono_light }
  THEMES.simple_dark = build { bg = 0x1B1B1B, text = 0xEEEEEE, dim = 0x9A9A9A, accent = 0xE6E6E6,
    sel = 0x3A3A3A, screen = 0x0D0D0D, wave = 0xE0E0E0, playhead = 0xFFFFFF, glow = 0xBBBBBB,
    heart = 0xDDDDDD, sparkle = 0xBBBBBB, spec = SPEC.mono_dark }
  for key, th in pairs(THEMES) do th.name = key end

  UI.spec_col = function(q)
    local cache = T.spec_cache
    if not cache then cache = {}; T.spec_cache = cache end
    local c = cache[q]
    if c then return c end
    local stops = T.spec
    local l = math.log(2 ^ (q / 4))
    local function lg(st) return math.log(st[1]) end
    local a, b = stops[1], stops[#stops]
    if l <= lg(a) then c = A((a[2] << 16) | (a[3] << 8) | a[4])
    elseif l >= lg(b) then c = A((b[2] << 16) | (b[3] << 8) | b[4])
    else
      for k = 1, #stops - 1 do
        local p, n = stops[k], stops[k + 1]
        if l <= lg(n) then
          local t = (l - lg(p)) / (lg(n) - lg(p))
          c = A((math.floor(p[2] + (n[2] - p[2]) * t + 0.5) << 16) | (math.floor(p[3] + (n[3] - p[3]) * t + 0.5) << 8)
            | math.floor(p[4] + (n[4] - p[4]) * t + 0.5))
          break
        end
      end
    end
    cache[q] = c
    return c
  end

  UI.SIZES = { 11, 12, 13, 14, 15, 16, 18, 20 }
  UI.fonts = {}
  for _, sz in ipairs(UI.SIZES) do
    UI.fonts[sz] = ImGui.CreateFont('sans-serif', sz)
    ImGui.Attach(ctx, UI.fonts[sz])
  end
  if not UI.fonts[S.font_size] then S.font_size = 13 end

  push_theme = function()
    local key = S.theme .. '_' .. S.mode
    T = THEMES[key]
    UI.k = S.font_size / 13
    ImGui.PushFont(ctx, UI.fonts[S.font_size])
    if not resolved[key] then resolved[key] = resolve(T) end
    for _, c in ipairs(resolved[key]) do
      ImGui.PushStyleColor(ctx, c[1], c[2])
    end
    for _, v in ipairs(style_list) do
      if v[3] then ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) else ImGui.PushStyleVar(ctx, v[1], v[2]) end
    end
    return #resolved[key], #style_list
  end

  pop_theme = function(nc, nv)
    ImGui.PopStyleColor(ctx, nc)
    ImGui.PopStyleVar(ctx, nv)
    ImGui.PopFont(ctx)
  end
end

--- Icons
local draw_icon, inline_icon, icon_button
do
  local ICONS = {
    play = { '#......', '###....', '#####..', '#######', '#####..', '###....', '#......' },
    stop = { '.#####.', '#######', '#######', '#######', '#######', '#######', '.#####.' },
    rev  = { '......#', '....###', '..#####', '#######', '..#####', '....###', '......#' },
    loop = { '......#..', '.#######.', '#.....#..', '#........', '........#', '..#.....#', '.#######.', '..#......' },
    spot = { '..###..', '..###..', '..###..', '#######', '.#####.', '..###..', '...#...', '#######' },
    speaker = { '....#....', '...##..#.', '####.#..#', '####.#..#', '####.#..#', '...##..#.', '....#....' },
    sparkle = { '...#...', '...#...', '..###..', '#######', '..###..', '...#...', '...#...' },
    search = { '.####....', '#....#...', '#....#...', '#....#...', '.####....', '.....##..', '......##.', '.......##' },
    dock = { '#########', '#########', '#.......#', '#.......#', '#.......#', '#.......#', '#########' },
    dot  = { '.##.', '####', '####', '.##.' },
    gear = { '..#.#.#..', '.#######.', '###...###', '.#.....#.', '##.....##', '.#.....#.', '###...###', '.#######.', '..#.#.#..' },
    help = { '.#####.', '##...##', '##...##', '....##.', '...##..', '...##..', '.......', '...##..', '...##..' },
    eq   = { '.#..#..#.', '.#..#..#.', '###.#..#.', '.#..#.###', '.#.###.#.', '.#..#..#.', '.#..#..#.' },
    comp = { '#........', '#.....###', '#....#...', '#...#....', '#..#.....', '#.#......', '##.......', '#########' },
    dice = { '.#######.', '#.......#', '#.#...#.#', '#.......#', '#...#...#', '#.......#', '#.#...#.#', '#.......#', '.#######.' },
  }

  local ICON = {}
  for name, rows in pairs(ICONS) do
    local runs = {}
    for r, row in ipairs(rows) do
      local c = 1
      while c <= #row do
        if row:sub(c, c) == '#' then
          local c2 = c
          while c2 < #row and row:sub(c2 + 1, c2 + 1) == '#' do c2 = c2 + 1 end
          local above
          for _, q in ipairs(runs) do
            if q[4] == r - 1 and q[2] == c - 1 and q[3] == c2 then above = q end
          end
          if above then above[4] = r else runs[#runs + 1] = { r - 1, c - 1, c2, r } end
          c = c2 + 1
        else
          c = c + 1
        end
      end
    end
    ICON[name] = { runs = runs, w = #rows[1], h = #rows }
  end

  -- smooth versions, drawn in the same box as the pixel ones
  local D = ImGui
  local VEC = {}
  local CLOSED = ImGui.DrawFlags_Closed
  local function sw(h) return math.max(1.4, math.floor(h / 9 * 10 + 0.5) / 10) end -- stroke width
  local function poly(dl, c, t, closed, ...)
    local p = { ... }
    D.DrawList_PathClear(dl)
    for i = 1, #p, 2 do D.DrawList_PathLineTo(dl, p[i], p[i + 1]) end
    D.DrawList_PathStroke(dl, c, closed and CLOSED or 0, t)
  end
  local function box(x, y, w, h)
    local z = math.min(w, h)
    return x + (w - z) / 2, y + (h - z) / 2, z
  end

  VEC.play = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    D.DrawList_AddTriangleFilled(dl, bx + z * 0.22, by + z * 0.12, bx + z * 0.22, by + z * 0.88, bx + z * 0.88, by + z * 0.5, c)
  end
  VEC.rev = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    D.DrawList_AddTriangleFilled(dl, bx + z * 0.78, by + z * 0.12, bx + z * 0.78, by + z * 0.88, bx + z * 0.12, by + z * 0.5, c)
  end
  VEC.stop = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    D.DrawList_AddRectFilled(dl, bx + z * 0.18, by + z * 0.18, bx + z * 0.82, by + z * 0.82, c, z * 0.12)
  end
  VEC.dot = function(dl, x, y, w, h, c)
    D.DrawList_AddCircleFilled(dl, x + w / 2, y + h / 2, math.min(w, h) * 0.3, c, 16)
  end
  VEC.loop = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    local a, b = z * 0.12, z * 0.88
    poly(dl, c, t, false, bx + a, by + z * 0.55, bx + a, by + z * 0.32, bx + b, by + z * 0.32)
    poly(dl, c, t, false, bx + z * 0.72, by + z * 0.16, bx + b, by + z * 0.32, bx + z * 0.72, by + z * 0.48)
    poly(dl, c, t, false, bx + b, by + z * 0.45, bx + b, by + z * 0.68, bx + a, by + z * 0.68)
    poly(dl, c, t, false, bx + z * 0.28, by + z * 0.52, bx + a, by + z * 0.68, bx + z * 0.28, by + z * 0.84)
  end
  VEC.spot = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    poly(dl, c, t, false, bx + z * 0.5, by + z * 0.08, bx + z * 0.5, by + z * 0.62)
    poly(dl, c, t, false, bx + z * 0.26, by + z * 0.4, bx + z * 0.5, by + z * 0.64, bx + z * 0.74, by + z * 0.4)
    poly(dl, c, t, false, bx + z * 0.1, by + z * 0.66, bx + z * 0.1, by + z * 0.9, bx + z * 0.9, by + z * 0.9, bx + z * 0.9, by + z * 0.66)
  end
  VEC.speaker = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    poly(dl, c, t, true, bx + z * 0.08, by + z * 0.38, bx + z * 0.28, by + z * 0.38, bx + z * 0.52, by + z * 0.14,
      bx + z * 0.52, by + z * 0.86, bx + z * 0.28, by + z * 0.62, bx + z * 0.08, by + z * 0.62)
    D.DrawList_PathClear(dl)
    D.DrawList_PathArcTo(dl, bx + z * 0.52, by + z * 0.5, z * 0.22, -0.9, 0.9, 10)
    D.DrawList_PathStroke(dl, c, 0, t)
    D.DrawList_PathClear(dl)
    D.DrawList_PathArcTo(dl, bx + z * 0.52, by + z * 0.5, z * 0.4, -0.85, 0.85, 14)
    D.DrawList_PathStroke(dl, c, 0, t)
  end
  VEC.sparkle = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local cx, cy = bx + z / 2, by + z / 2
    local R, r = z * 0.48, z * 0.13
    for k = 0, 3 do
      local a = k * math.pi / 2 - math.pi / 2
      local tx, ty = cx + math.cos(a) * R, cy + math.sin(a) * R
      local l = a - math.pi / 4
      local rr = a + math.pi / 4
      D.DrawList_AddTriangleFilled(dl, cx, cy, tx, ty, cx + math.cos(l) * r, cy + math.sin(l) * r, c)
      D.DrawList_AddTriangleFilled(dl, cx, cy, cx + math.cos(rr) * r, cy + math.sin(rr) * r, tx, ty, c)
    end
  end
  VEC.search = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    D.DrawList_AddCircle(dl, bx + z * 0.43, by + z * 0.43, z * 0.3, c, 24, t)
    poly(dl, c, t, false, bx + z * 0.65, by + z * 0.65, bx + z * 0.9, by + z * 0.9)
  end
  VEC.dock = function(dl, x, y, w, h, c)
    local t = sw(h)
    D.DrawList_AddRect(dl, x + 0.5, y + 1, x + w - 0.5, y + h - 1, c, 2, 0, t)
    poly(dl, c, t, false, x + 0.5, y + h * 0.36, x + w - 0.5, y + h * 0.36)
  end
  VEC.gear = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    for i, k in ipairs({ 0.3, 0.7, 0.45 }) do
      local yy = by + z * (0.2 + (i - 1) * 0.3)
      poly(dl, c, t, false, bx + z * 0.06, yy, bx + z * 0.94, yy)
      D.DrawList_AddCircleFilled(dl, bx + z * k, yy, z * 0.12, c, 12)
    end
  end
  VEC.help = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local cx, cy, t = bx + z / 2, by + z / 2, sw(z)
    D.DrawList_AddCircle(dl, cx, cy, z * 0.46, c, 24, t)
    D.DrawList_PathClear(dl)
    D.DrawList_PathArcTo(dl, cx, by + z * 0.38, z * 0.14, math.pi * 1.1, math.pi * 2.35, 12)
    D.DrawList_PathLineTo(dl, cx, by + z * 0.6)
    D.DrawList_PathStroke(dl, c, 0, t)
    D.DrawList_AddCircleFilled(dl, cx, by + z * 0.74, t * 0.75, c, 8)
  end
  VEC.eq = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    for i, k in ipairs({ 0.62, 0.3, 0.52 }) do
      local xx = bx + z * (0.2 + (i - 1) * 0.3)
      poly(dl, c, t, false, xx, by + z * 0.08, xx, by + z * 0.92)
      D.DrawList_AddRectFilled(dl, xx - z * 0.11, by + z * k - z * 0.07, xx + z * 0.11, by + z * k + z * 0.07, c, 1)
    end
  end
  VEC.comp = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    local t = sw(z)
    poly(dl, c, t, false, bx + z * 0.08, by + z * 0.06, bx + z * 0.08, by + z * 0.92, bx + z * 0.94, by + z * 0.92)
    poly(dl, c, t, false, bx + z * 0.14, by + z * 0.86, bx + z * 0.55, by + z * 0.42, bx + z * 0.94, by + z * 0.28)
  end
  VEC.dice = function(dl, x, y, w, h, c)
    local bx, by, z = box(x, y, w, h)
    D.DrawList_AddRect(dl, bx + z * 0.06, by + z * 0.06, bx + z * 0.94, by + z * 0.94, c, z * 0.18, 0, sw(z))
    for _, p in ipairs({ { 0.32, 0.32 }, { 0.68, 0.32 }, { 0.5, 0.5 }, { 0.32, 0.68 }, { 0.68, 0.68 } }) do
      D.DrawList_AddCircleFilled(dl, bx + z * p[1], by + z * p[2], z * 0.075, c, 10)
    end
  end

  draw_icon = function(dl, name, x, y, px, col)
    local ic = ICON[name]
    if S.icons == 'smooth' then return VEC[name](dl, x, y, ic.w * px, ic.h * px, col) end
    x, y = math.floor(x), math.floor(y)
    for _, r in ipairs(ic.runs) do
      ImGui.DrawList_AddRectFilled(dl, x + r[2] * px, y + r[1] * px, x + r[3] * px, y + r[4] * px, col)
    end
  end

  inline_icon = function(name, col, px)
    local ic = ICON[name]
    local fh = ImGui.GetFrameHeight(ctx)
    ImGui.Dummy(ctx, ic.w * px, fh)
    local x1, y1 = ImGui.GetItemRectMin(ctx)
    draw_icon(ImGui.GetWindowDrawList(ctx), name, x1, y1 + (fh - ic.h * px) / 2, px, col)
  end

  icon_button = function(id, icon, label, on, tip, disabled)
    local px = 2
    local ic = ICON[icon]
    local iw, ih = ic.w * px, ic.h * px
    local tw = label and ImGui.CalcTextSize(ctx, label) or 0
    local fh = ImGui.GetFrameHeight(ctx)
    local padx = 9
    local bw = padx * 2 + iw + (label and (7 + tw) or 0)
    local clicked = ImGui.InvisibleButton(ctx, id, bw, fh)
    local hovered, active = ImGui.IsItemHovered(ctx), ImGui.IsItemActive(ctx)
    local x1, y1 = ImGui.GetItemRectMin(ctx)
    local x2, y2 = ImGui.GetItemRectMax(ctx)
    local dl = ImGui.GetWindowDrawList(ctx)
    local bg = T.cols.Button
    if disabled then bg = T.cols.FrameBg
    elseif on then bg = T.on
    elseif active then bg = T.cols.ButtonActive
    elseif hovered then bg = T.cols.ButtonHovered end
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, bg, 6)
    ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, on and T.cols.CheckMark or T.cols.Border, 6)
    local col = disabled and T.cols.TextDisabled or (on and T.icon_on or T.icon)
    local ix = label and (x1 + padx) or (x1 + (bw - iw) / 2)
    draw_icon(dl, icon, ix, y1 + (fh - ih) / 2, px, col)
    if label then
      ImGui.DrawList_AddText(dl, ix + iw + 7, y1 + (fh - ImGui.GetTextLineHeight(ctx)) / 2, col, label)
    end
    if tip and hovered then ImGui.SetTooltip(ctx, tip) end
    return clicked and not disabled
  end
end

--- Sliders
local function ctrl_down() return (ImGui.GetKeyMods(ctx) & ImGui.Mod_Ctrl) ~= 0 end
local function shift_down() return (ImGui.GetKeyMods(ctx) & ImGui.Mod_Shift) ~= 0 end

local reset_pending = {}
local function slider(label, value, minv, maxv, fmt, default, width, tip, log)
  ImGui.SetNextItemWidth(ctx, UI.sz(width))
  local c, v = ImGui.SliderDouble(ctx, label, value, minv, maxv, fmt, ImGui.SliderFlags_NoInput | (log and ImGui.SliderFlags_Logarithmic or 0))
  if ImGui.IsItemActivated(ctx) and ctrl_down() then reset_pending[label] = true end
  if reset_pending[label] then
    v, c = default, true
    if not ImGui.IsItemActive(ctx) then reset_pending[label] = nil end
  end
  if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then v, c = default, true end
  if tip and ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, tip) end
  return c, v
end

--- Window
local first_frame = true
local set_dock = (S.dock ~= 0) and S.dock or nil
local was_typing = false
local scroll_to = nil
local drag_start, dragging, sel_grab = nil, false, false

-- One bar per pixel column of the waveform, straight from REAPER's peaks, the way
-- the Media Explorer draws it. Bars overlap by half a pixel so the fill never seams,
-- and neighbours of the same colour and height merge into one.
local function wave_runs(x1, y1, x2, y2)
  local rects = {} -- flat: x1, y1, x2, y2, colour, x1, y1, ...
  local n, W = wf.n, x2 - x1
  local nl = #wf.ch
  local lane_h = (y2 - y1) / nl
  local cols = math.max(1, math.min(n, math.floor(W)))
  local cw, m = W / cols, 0
  for c = 1, nl do
    local ch = wf.ch[c]
    local mx, mn, cc = ch.max, ch.min, ch.col
    local mid = y1 + (c - 0.5) * lane_h
    local amp = lane_h / 2 - (nl > 1 and 2 or 4)
    local run = false -- no bar to extend yet, and never across a channel
    for j = 1, cols do
      local rj = S.reverse and (cols - j) or (j - 1)
      local i0 = math.floor(rj * n / cols) + 1
      local i1 = math.max(i0, math.floor((rj + 1) * n / cols))
      local hi, lo, pk = -2, 2, i0
      for i = i0, i1 do
        local a, b = mx[i] or 0, mn[i] or 0
        if a > hi then hi, pk = a, i end
        if b < lo then lo = b end
      end
      local t, b = mid - hi * amp, mid - lo * amp
      if b - t < 1 then b = t + 1 end -- silence still draws the centre line, as REAPER does
      local k = (cc and cc[pk] and UI.spec_col(cc[pk])) or T.wave
      local xb = x1 + j * cw + 0.5
      if run and rects[m] == k and math.abs(rects[m - 3] - t) < 0.5 and math.abs(rects[m - 1] - b) < 0.5 then
        rects[m - 2] = xb
      else
        rects[m + 1], rects[m + 2] = x1 + (j - 1) * cw, t
        rects[m + 3], rects[m + 4], rects[m + 5] = xb, b, k
        m, run = m + 5, true
      end
    end
  end
  return rects
end

local function draw_waveform(w, h)
  ImGui.InvisibleButton(ctx, '##wave', math.max(w, 10), h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local x2, y2 = ImGui.GetItemRectMax(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, T.wave_bg, 6)
  ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, T.cols.Border, 6)

  local len = source_len()
  local W = x2 - x1
  local function t_at(x)
    if len <= 0 then return 0 end
    return math.max(0, math.min(1, (x - x1) / W)) * len
  end
  local function x_at(t)
    if len <= 0 then return x1 end
    return x1 + math.min(1, t / len) * W
  end

  if sel_a and sel_b then
    ImGui.DrawList_AddRectFilled(dl, x_at(sel_a), y1, x_at(sel_b), y2, T.sel)
  end

  if wf and wf.n > 0 and #wf.ch > 0 then
    local nl = #wf.ch
    local lane_h = (y2 - y1) / nl
    for c = 2, nl do
      local ly = y1 + (c - 1) * lane_h
      ImGui.DrawList_AddLine(dl, x1 + 2, ly, x2 - 2, ly, T.grid)
    end
    local key = ('%.1f:%.1f:%.1f:%.1f:%s:%s'):format(x1, y1, x2, y2, S.reverse and 1 or 0, T.name)
    if wf.draw_key ~= key then wf.draw_key, wf.runs = key, wave_runs(x1, y1, x2, y2) end
    local r = wf.runs
    for q = 1, #r, 5 do ImGui.DrawList_AddRectFilled(dl, r[q], r[q + 1], r[q + 2], r[q + 3], r[q + 4]) end
    if wf.nospec then
      local msg = 'no spectral data in this peak file'
      local mw = ImGui.CalcTextSize(ctx, msg)
      ImGui.DrawList_AddText(dl, x2 - mw - 10, y2 - 20, T.wave_msg, msg)
    end
  elseif cur then
    local msg = 'loading waveform...'
    if wf and wf.offline then msg = 'file not found (drive offline?)'
    elseif wf and wf.building then msg = 'building waveform...'
    elseif wf and wf.len and wf.len > MAX_WAVE_LEN then msg = 'long file: no waveform'
    elseif wf then msg = 'no waveform' end
    ImGui.DrawList_AddText(dl, x1 + 10, y1 + 8, T.wave_msg, msg)
  else
    draw_icon(dl, 'sparkle', x1 + W / 2 - 7, y1 + (y2 - y1) / 2 - 7, 2, T.wave_msg)
  end

  if cur and (playing or play_pos > 0) then
    local px = x_at(play_pos)
    ImGui.DrawList_AddLine(dl, px, y1, px, y2, T.playhead, 2)
  end

  if not cur then return end
  local mx = ImGui.GetMousePos(ctx)
  if ImGui.IsItemActivated(ctx) then
    drag_start, dragging = t_at(mx), false
    sel_grab = (sel_a and sel_b and drag_start >= sel_a and drag_start <= sel_b) and true or false
  end
  -- shortest selection: 0.5 s (or a quarter of very short files)
  local min_sel = math.min(0.5, len * 0.25)
  if sel_grab and ImGui.IsItemActive(ctx) and ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left, 6) then
    if not drag_out then drag_out = { whole = false } end -- dragging the selection out
  elseif ImGui.IsItemActive(ctx) and drag_start and not sel_grab and ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left, 3) then
    dragging = true
    local t = t_at(mx)
    local a, b = math.min(drag_start, t), math.max(drag_start, t)
    if b - a >= min_sel then sel_a, sel_b = a, b else sel_a, sel_b = nil, nil end
  end
  if ImGui.IsItemDeactivated(ctx) and drag_start then
    if sel_grab and drag_out then
      -- handle_drop takes it from here
    elseif dragging and sel_a and sel_b and sel_b - sel_a >= min_sel then
      play(sel_a)
    else
      sel_a, sel_b = nil, nil
      play(drag_start)
    end
    drag_start, dragging, sel_grab = nil, false, false
  end
end

local function filters_combo()
  local nf = filter_count()
  if ImGui.BeginCombo(ctx, '##filters', nf > 0 and ('Filters (%d)'):format(nf) or 'Filters', ImGui.ComboFlags_HeightLargest) then
    local changed = false
    local function checks(title, opts, set, id)
      ImGui.TextDisabled(ctx, title)
      local x0 = ImGui.GetCursorPosX(ctx)
      for i, o in ipairs(opts) do
        if i > 1 then ImGui.SameLine(ctx, x0 + (i - 1) * 92) end
        local c, v = ImGui.Checkbox(ctx, o[2] .. '##' .. id .. i, set[o[1]] == true)
        if c then set[o[1]] = v or nil; changed = true end
      end
    end
    checks('Sample rate', SR_OPTS, F.sr, 'sr')
    ImGui.Spacing(ctx)
    checks('Bit depth', BIT_OPTS, F.bits, 'b')
    ImGui.Spacing(ctx)
    checks('Channels', CH_OPTS, F.ch, 'ch')
    ImGui.Spacing(ctx)
    ImGui.TextDisabled(ctx, 'Length')
    local c1, c2
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Longer than')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, UI.sz(64))
    c1, F.len_min = ImGui.InputTextWithHint(ctx, '##len_min', 'sec', F.len_min)
    ImGui.SameLine(ctx, 0, 16)
    ImGui.Text(ctx, 'Shorter than')
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, UI.sz(64))
    c2, F.len_max = ImGui.InputTextWithHint(ctx, '##len_max', 'sec', F.len_max)
    if c1 or c2 then changed = true end
    if (F.len_min ~= '' and not len_secs(F.len_min)) or (F.len_max ~= '' and not len_secs(F.len_max)) then
      ImGui.TextDisabled(ctx, 'Use seconds (2.5) or minutes:seconds (1:30)')
    end
    ImGui.Separator(ctx)
    local c
    ImGui.TextDisabled(ctx, 'Any of these words (OR)')
    ImGui.SetNextItemWidth(ctx, UI.sz(280))
    c, F.any = ImGui.InputTextWithHint(ctx, '##f_any', 'whoosh swish swoosh', F.any); changed = changed or c
    ImGui.TextDisabled(ctx, 'Exclude these words (NOT)')
    ImGui.SetNextItemWidth(ctx, UI.sz(280))
    c, F.none = ImGui.InputTextWithHint(ctx, '##f_none', 'wind loop', F.none); changed = changed or c
    ImGui.TextDisabled(ctx, 'Exact phrase')
    ImGui.SetNextItemWidth(ctx, UI.sz(280))
    c, F.phrase = ImGui.InputTextWithHint(ctx, '##f_phrase', 'glass break', F.phrase); changed = changed or c
    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, 'Clear filters') then clear_filters(); changed = true end
    ImGui.SameLine(ctx)
    ImGui.TextDisabled(ctx, 'Empty = everything')
    if changed then filters_changed_at = reaper.time_precise() end
    ImGui.EndCombo(ctx)
  end
  if nf > 0 and ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, 'Filters are combined with the search box.\nFilters with no search words check every file, so they take a few seconds on big libraries.')
  end
end

local function top_bar(dock_id)
  local dl = ImGui.GetWindowDrawList(ctx)
  local fh = ImGui.GetFrameHeight(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local aw = ImGui.GetContentRegionAvail(ctx)
  local bh = fh + 8
  ImGui.DrawList_AddRectFilled(dl, x0 - 4, y0, x0 + aw + 4, y0 + bh, T.taskbar, 6)
  ImGui.DrawList_AddRect(dl, x0 - 4, y0, x0 + aw + 4, y0 + bh, T.cols.Border, 6)
  ImGui.SetCursorScreenPos(ctx, x0 + 2, y0 + 4)

  inline_icon('search', T.heart, 2)
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, HELP) end
  ImGui.SameLine(ctx, 0, 6)
  if first_frame then ImGui.SetKeyboardFocusHere(ctx); first_frame = false end
  -- leave room for the buttons on the right
  ImGui.SetNextItemWidth(ctx, -(36 + 8 + UI.sz(160) + 8 + UI.sz(170) + 8 + 36 + 8 + 36 + 8 + 36 + 6))
  local _
  _, query = ImGui.InputTextWithHint(ctx, '##q', 'search...  (OR  NOT  "phrase"  name:  desc:  48k+  1ch  2s-)', query)
  ImGui.SameLine(ctx)
  if icon_button('##shuffle', 'dice', nil, shuffle_pending, 'Shuffle: put the results in a random order\n(click again for a new order; a new search restores the normal order)') then
    shuffle_results()
  end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, UI.sz(160))
  filters_combo()
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, UI.sz(170))
  local on, last = 0, nil
  for _, d in ipairs(dbs) do if not db_sel[d.title] then on = on + 1; last = d.title end end
  local db_label = (on == #dbs) and 'All databases' or (on == 0 and 'No databases')
    or (on == 1 and last) or (on .. ' databases')
  if ImGui.BeginCombo(ctx, '##db', db_label) then
    local changed_db = false
    local all, v = on == #dbs, nil
    _, v = ImGui.Checkbox(ctx, 'All databases', all)
    if v ~= all then
      for _, d in ipairs(dbs) do db_sel[d.title] = (not v) or nil end
      changed_db = true
    end
    ImGui.Separator(ctx)
    for i, d in ipairs(dbs) do
      local cur_on = not db_sel[d.title]
      _, v = ImGui.Checkbox(ctx, d.title .. '##db' .. i, cur_on)
      if v ~= cur_on then db_sel[d.title] = (not v) or nil; changed_db = true end
    end
    if changed_db then
      local off = {}
      for t in pairs(db_sel) do off[#off + 1] = t end
      reaper.SetExtState(SCRIPT, 'db_off', table.concat(off, '|'), true)
      need_search = true
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx)
  if icon_button('##tips', 'help', nil, S.tips, 'Hover guides: on (click to turn them off)') then
    S.tips = not S.tips
  end
  ImGui.SameLine(ctx)
  if icon_button('##settings', 'gear', nil, S.settings_win, 'Settings') then
    S.settings_win = not S.settings_win
  end
  ImGui.SameLine(ctx)
  if icon_button('##dock', 'dock', nil, dock_id < 0,
      dock_id < 0 and 'Undock' or 'Dock into a REAPER docker') then
    set_dock = dock_id < 0 and 0 or -1
  end
  ImGui.SetCursorScreenPos(ctx, x0, y0 + bh + 6)
  ImGui.Dummy(ctx, 0, 0)
end

local function status_line()
  local status
  if loading then
    status = load_status
  else
    local files_txt = counting and 'counting files...' or ('%d files'):format(total_files)
    local res_txt
    if not search_active then
      res_txt = 'type or set filters to search'
    else
      res_txt = ('%d results%s'):format(#results, searcher and ' (searching...)' or '')
    end
    local n_on, f_on = 0, 0
    for _, d in ipairs(dbs) do
      if not db_sel[d.title] then n_on = n_on + 1; f_on = f_on + (d.count or 0) end
    end
    if n_on == #dbs then
      status = ('%s   |   %s in %d databases'):format(res_txt, files_txt, #dbs)
    else
      if not counting then files_txt = ('%d files'):format(f_on) end
      status = ('%s   |   %s in %d of %d databases'):format(res_txt, files_txt, n_on, #dbs)
    end
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local lh = ImGui.GetTextLineHeight(ctx)
  draw_icon(dl, 'dot', x + 2, y + (lh - 8) / 2, 2, T.ok)
  ImGui.SetCursorScreenPos(ctx, x + 16, y)
  ImGui.TextColored(ctx, T.cols.TextDisabled, status)
  if flash and reaper.time_precise() < flash_until then
    ImGui.SameLine(ctx)
    ImGui.TextColored(ctx, T.warn, '   ' .. flash)
  end
  if #dbs == 0 then
    ImGui.TextColored(ctx, T.warn, 'No Media Explorer databases found. Create one in the Media Explorer first.')
  end
end

--- EQ and compressor panels
-- (built inside a function because of the 200-local limit)
local fx_area = (function()

  -- same filter maths as the JSFX, for drawing the curve
  local DISP_SR = 48000
  local function mag(f, t0, t1, t2, u0, u1, u2)
    local b0, b1, b2, a1, a2 = t0 / u0, t1 / u0, t2 / u0, u1 / u0, u2 / u0
    local w = 2 * math.pi * f / DISP_SR
    local cw, c2w = math.cos(w), math.cos(2 * w)
    local num = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * cw + 2 * b0 * b2 * c2w
    local den = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * cw + 2 * a2 * c2w
    return 10 * math.log(math.max(num, 1e-12) / math.max(den, 1e-12), 10)
  end
  local function c_hp(f, q) local w = 2 * math.pi * f / DISP_SR; local c, al = math.cos(w), math.sin(w) / (2 * q)
    return (1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al end
  local function c_lp(f, q) local w = 2 * math.pi * f / DISP_SR; local c, al = math.cos(w), math.sin(w) / (2 * q)
    return (1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al end
  local function c_pk(f, g, q) local A = 10 ^ (g / 40); local w = 2 * math.pi * f / DISP_SR
    local c, al = math.cos(w), math.sin(w) / (2 * q)
    return 1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A end

  local function eq_response(f)
    local db = 0
    if S.e_hpf > 20.5 then db = db + (mag(f, c_hp(S.e_hpf, 0.7071))) end
    if S.e_lpf < 19999 then db = db + (mag(f, c_lp(S.e_lpf, 0.7071))) end
    if math.abs(S.e_lg) > 0.05 then db = db + (mag(f, c_pk(S.e_lf, S.e_lg, S.e_lq))) end
    if math.abs(S.e_mg) > 0.05 then db = db + (mag(f, c_pk(S.e_mf, S.e_mg, S.e_mq))) end
    if math.abs(S.e_hg) > 0.05 then db = db + (mag(f, c_pk(S.e_hf, S.e_hg, S.e_hq))) end
    return db
  end

  local EQ_NODES = {
    { id = 'hpf',  label = 'HPF',  col = 0xC7B3EEFF, f = 'e_hpf', fmin = 20,   fmax = 2000 },
    { id = 'low',  label = 'Low',  col = 0xE8A0B4FF, f = 'e_lf',  fmin = 30,   fmax = 1000,  g = 'e_lg', q = 'e_lq' },
    { id = 'mid',  label = 'Mid',  col = 0xF2C08EFF, f = 'e_mf',  fmin = 100,  fmax = 10000, g = 'e_mg', q = 'e_mq' },
    { id = 'high', label = 'High', col = 0x9FD1BDFF, f = 'e_hf',  fmin = 1000, fmax = 18000, g = 'e_hg', q = 'e_hq' },
    { id = 'lpf',  label = 'LPF',  col = 0x8DBCE3FF, f = 'e_lpf', fmin = 1000, fmax = 20000 },
  }
  local EQ_DB = 15
  local eq_drag = nil
  local eq_cache = { key = {} }

  local function node_desc(n)
    local f = S[n.f]
    if n.id == 'hpf' and f <= 20.5 then return 'HPF off  (drag right to turn on)' end
    if n.id == 'lpf' and f >= 19999 then return 'LPF off  (drag left to turn on)' end
    local txt = ('%s  %s'):format(n.label, f >= 1000 and ('%.2f kHz'):format(f / 1000) or ('%.0f Hz'):format(f))
    if n.g then txt = txt .. ('  %+.1f dB'):format(S[n.g]) end
    if n.q then txt = txt .. ('  Q %.2f'):format(S[n.q]) end
    return txt
  end

  local function reset_node(n)
    S[n.f] = EQ_DEF[n.f]
    if n.g then S[n.g] = EQ_DEF[n.g] end
    if n.q then S[n.q] = EQ_DEF[n.q] end
  end

  local function eq_panel(x, y, w, h)
    local dl = ImGui.GetWindowDrawList(ctx)
    local fh = ImGui.GetFrameHeight(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.taskbar, 6)
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, S.eq_on and T.cols.CheckMark or T.cols.Border, 6)

    ImGui.SetCursorScreenPos(ctx, x + 6, y + 6)
    if icon_button('##eq_on', 'eq', 'EQ', S.eq_on,
        'Turn the EQ on or off. While on, you hear it while auditioning,\nand spotted items get it as a take FX (baked in with Glue on spot).\n\nDrag nodes: left/right = frequency, up/down = gain.\nMouse wheel over a bell node = Q. Ctrl+click or right-click a node resets it.') then
      local was = fx_needed()
      S.eq_on = not S.eq_on
      apply_eq()
      if playing and fx_needed() ~= was then play(play_pos) end
    end
    local tbx = ImGui.GetItemRectMax(ctx)
    local th = ImGui.GetTextLineHeight(ctx)
    ImGui.DrawList_AddText(dl, x + 8, y + fh + 6, T.cols.TextDisabled, 'drag')
    ImGui.DrawList_AddText(dl, x + 8, y + fh + 6 + th, T.cols.TextDisabled, 'wheel=Q')

    local side = math.max(tbx - x, ImGui.CalcTextSize(ctx, 'wheel=Q') + 16, UI.sz(70))
    local gx, gy = x + side + 8, y + 6
    local gw, gh = x + w - 6 - gx, h - 12
    if gw < 60 or gh < 30 then return end
    ImGui.DrawList_AddRectFilled(dl, gx, gy, gx + gw, gy + gh, T.wave_bg, 4)
    local LOGR = math.log(1000)
    local function fx(f) return gx + math.log(f / 20) / LOGR * gw end
    local function fy(db) return gy + gh / 2 - db / EQ_DB * (gh / 2 - 4) end
    local function f_at(px) return 20 * 1000 ^ math.max(0, math.min(1, (px - gx) / gw)) end
    local function db_at(py) return math.max(-EQ_DB, math.min(EQ_DB, -(py - gy - gh / 2) / (gh / 2 - 4) * EQ_DB)) end

    local grid = T.grid
    for _, f in ipairs({ 50, 100, 200, 500, 1000, 2000, 5000, 10000 }) do
      ImGui.DrawList_AddLine(dl, fx(f), gy, fx(f), gy + gh, grid)
    end
    for _, db in ipairs({ -12, -6, 6, 12 }) do
      ImGui.DrawList_AddLine(dl, gx, fy(db), gx + gw, fy(db), grid)
    end
    ImGui.DrawList_AddLine(dl, gx, fy(0), gx + gw, fy(0), T.grid_text)
    for _, lab in ipairs({ { 100, '100' }, { 1000, '1k' }, { 10000, '10k' } }) do
      ImGui.DrawList_AddText(dl, fx(lab[1]) + 3, gy + gh - ImGui.GetTextLineHeight(ctx) - 1, T.grid_text, lab[2])
    end

    ImGui.SetCursorScreenPos(ctx, gx, gy)
    ImGui.InvisibleButton(ctx, '##eq_graph', gw, gh)
    local mx, my = ImGui.GetMousePos(ctx)
    local function nearest()
      local best, bd = nil, 14 * 14
      for _, n in ipairs(EQ_NODES) do
        local nx, ny = fx(S[n.f]), fy(n.g and S[n.g] or 0)
        local d = (nx - mx) ^ 2 + (ny - my) ^ 2
        if d < bd then best, bd = n, d end
      end
      return best
    end
    local changed = false
    if ImGui.IsItemActivated(ctx) then
      eq_drag = nearest()
      if eq_drag and ctrl_down() then reset_node(eq_drag); eq_drag = nil; changed = true end
    end
    if ImGui.IsItemActive(ctx) and eq_drag then
      local n = eq_drag
      S[n.f] = math.max(n.fmin, math.min(n.fmax, f_at(mx)))
      if n.g then S[n.g] = math.floor(db_at(my) * 10 + 0.5) / 10 end
      changed = true
    end
    if ImGui.IsItemDeactivated(ctx) then eq_drag = nil end
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
      local n = nearest()
      if n then reset_node(n); changed = true end
    end
    local hover = eq_drag or (ImGui.IsItemHovered(ctx) and nearest()) or nil
    if hover and hover.q and ImGui.IsItemHovered(ctx) then
      local wheel = ImGui.GetMouseWheel(ctx)
      if wheel ~= 0 then
        S[hover.q] = math.max(0.3, math.min(6, S[hover.q] * 1.12 ^ wheel))
        changed = true
      end
    end
    if hover then ImGui.SetTooltip(ctx, node_desc(hover)) end
    if changed then apply_eq() end

    local stale = false
    for i, v in ipairs({ gx, gy, gw, gh, S.e_hpf, S.e_lf, S.e_lg, S.e_lq, S.e_mf, S.e_mg, S.e_mq, S.e_hf, S.e_hg, S.e_hq, S.e_lpf }) do
      if eq_cache.key[i] ~= v then eq_cache.key[i], stale = v, true end
    end
    if stale then
      local pts, fill, y0 = {}, {}, fy(0)
      for px = 0, math.floor(gw), 2 do
        local py = fy(math.max(-EQ_DB, math.min(EQ_DB, eq_response(f_at(gx + px)))))
        pts[#pts + 1], pts[#pts + 2] = gx + px, py
        if px % 4 == 0 and math.abs(py - y0) >= 1 then fill[#fill + 1], fill[#fill + 2] = gx + px, py end
      end
      eq_cache.pts, eq_cache.fill = reaper.new_array(pts), fill
    end
    local curve = S.eq_on and T.curve or T.grid_text
    local fill_col, y0 = (curve & 0xFFFFFF00) | 0x30, fy(0)
    local fill = eq_cache.fill
    for i = 1, #fill, 2 do ImGui.DrawList_AddLine(dl, fill[i], y0, fill[i], fill[i + 1], fill_col, 4) end
    ImGui.DrawList_AddPolyline(dl, eq_cache.pts, curve, 0, 2)

    for _, n in ipairs(EQ_NODES) do
      local nx, ny = fx(S[n.f]), fy(n.g and S[n.g] or 0)
      local off = (n.id == 'hpf' and S.e_hpf <= 20.5) or (n.id == 'lpf' and S.e_lpf >= 19999)
      local col = S.eq_on and n.col or T.cols.TextDisabled
      if off then
        ImGui.DrawList_AddCircle(dl, nx, ny, 5, col, 0, 1.5)
      else
        ImGui.DrawList_AddCircleFilled(dl, nx, ny, (hover == n) and 7 or 5.5, col)
        ImGui.DrawList_AddCircle(dl, nx, ny, (hover == n) and 7 or 5.5, T.wave_bg, 0, 1.5)
      end
    end
  end

  -- drag up/down, Shift = fine, Ctrl+click or right-click resets
  local knob_reset = {}
  local function knob(id, label, v, minv, maxv, default, fmt, log, size, accent, tip)
    local dl = ImGui.GetWindowDrawList(ctx)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    ImGui.InvisibleButton(ctx, id, size, size)
    local active, hovered = ImGui.IsItemActive(ctx), ImGui.IsItemHovered(ctx)
    local function to_t(val)
      if log then return math.log(val / minv) / math.log(maxv / minv) end
      return (val - minv) / (maxv - minv)
    end
    local function from_t(t)
      t = math.max(0, math.min(1, t))
      if log then return minv * (maxv / minv) ^ t end
      return minv + (maxv - minv) * t
    end
    local changed = false
    if ImGui.IsItemActivated(ctx) and ctrl_down() then v, changed, knob_reset[id] = default, true, true end
    if active and not knob_reset[id] then
      local _, dy = ImGui.GetMouseDelta(ctx)
      if dy ~= 0 then
        v = from_t(to_t(v) - dy * (shift_down() and 0.0015 or 0.008))
        changed = true
      end
    end
    if not active then knob_reset[id] = nil end
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then v, changed = default, true end

    local cx, cy, r = x + size / 2, y + size / 2, size / 2 - 1
    local a0, a1 = math.pi * 0.75, math.pi * 2.25
    local t = math.max(0, math.min(1, to_t(v)))
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, r, T.cols.FrameBg)
    ImGui.DrawList_AddCircle(dl, cx, cy, r, hovered and T.cols.CheckMark or T.cols.Border, 0, 1)
    ImGui.DrawList_PathArcTo(dl, cx, cy, r - 4, a0, a1)
    ImGui.DrawList_PathStroke(dl, T.cols.FrameBgActive, 0, 3)
    if t > 0.001 then
      ImGui.DrawList_PathArcTo(dl, cx, cy, r - 4, a0, a0 + (a1 - a0) * t)
      ImGui.DrawList_PathStroke(dl, accent, 0, 3)
    end
    local a = a0 + (a1 - a0) * t
    ImGui.DrawList_AddLine(dl, cx, cy, cx + math.cos(a) * (r - 6), cy + math.sin(a) * (r - 6), T.cols.Text, 2)
    local lw = ImGui.CalcTextSize(ctx, label)
    ImGui.DrawList_AddText(dl, cx - lw / 2, y - ImGui.GetTextLineHeight(ctx) - 3, T.cols.TextDisabled, label)
    local vt = fmt:format(v)
    local vw = ImGui.CalcTextSize(ctx, vt)
    ImGui.DrawList_AddText(dl, cx - vw / 2, y + size + 2, T.cols.Text, vt)
    if tip and hovered then ImGui.SetTooltip(ctx, tip) end
    return changed, v
  end

  local comp_drag = false
  local comp_cache = { key = {} }

  -- soft knee 6 dB, before makeup
  local function comp_curve(inp)
    local knee, d = 6, inp - S.c_thr
    if 2 * d < -knee then return inp end
    if 2 * math.abs(d) <= knee then
      return inp + (1 / S.c_ratio - 1) * (d + knee / 2) ^ 2 / (2 * knee)
    end
    return S.c_thr + d / S.c_ratio
  end

  local function comp_panel(x, y, w, h)
    local dl = ImGui.GetWindowDrawList(ctx)
    local fh = ImGui.GetFrameHeight(ctx)
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, T.taskbar, 6)
    ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, S.comp_on and T.cols.CheckMark or T.cols.Border, 6)

    ImGui.SetCursorScreenPos(ctx, x + 6, y + 6)
    if icon_button('##comp_on', 'comp', 'Comp', S.comp_on,
        'Turn the compressor on or off. While on, you hear it while auditioning,\nand spotted items get it as a take FX (baked in with Glue on spot).') then
      local was = fx_needed()
      S.comp_on = not S.comp_on
      apply_comp()
      if playing and fx_needed() ~= was then play(play_pos) end
    end
    local active_meters = S.comp_on and playing
    local gr = active_meters and meter_gr or 0
    local tbx = ImGui.GetItemRectMax(ctx)
    local th = ImGui.GetTextLineHeight(ctx)
    ImGui.DrawList_AddText(dl, x + 8, y + fh + 6, gr > 0.05 and T.sparkle or T.cols.TextDisabled, ('GR %.1f'):format(gr))
    ImGui.DrawList_AddText(dl, x + 8, y + fh + 6 + th, T.cols.TextDisabled, 'dB')

    local gs = h - 12
    local side = math.max(tbx - x, ImGui.CalcTextSize(ctx, 'GR 24.0') + 16, UI.sz(70))
    local gx, gy = x + side + 8, y + 6
    if gs < 30 then return end
    ImGui.DrawList_AddRectFilled(dl, gx, gy, gx + gs, gy + gs, T.wave_bg, 4)
    local function px(db) return gx + (db + 60) / 60 * gs end
    local function py(db) return gy + gs - (math.max(-60, math.min(0, db)) + 60) / 60 * gs end
    for _, db in ipairs({ -48, -36, -24, -12 }) do
      ImGui.DrawList_AddLine(dl, px(db), gy, px(db), gy + gs, T.grid)
      ImGui.DrawList_AddLine(dl, gx, py(db), gx + gs, py(db), T.grid)
    end
    ImGui.DrawList_AddLine(dl, gx, gy + gs, gx + gs, gy, T.grid_text)
    local stale = false
    for i, v in ipairs({ gx, gy, gs, S.c_thr, S.c_ratio, S.c_mk }) do
      if comp_cache.key[i] ~= v then comp_cache.key[i], stale = v, true end
    end
    if stale then
      local pts = {}
      for inp = -60, 0 do pts[#pts + 1], pts[#pts + 2] = px(inp), py(comp_curve(inp) + S.c_mk) end
      comp_cache.pts = reaper.new_array(pts)
    end
    ImGui.DrawList_AddPolyline(dl, comp_cache.pts, S.comp_on and T.curve or T.grid_text, 0, 2)

    ImGui.SetCursorScreenPos(ctx, gx, gy)
    ImGui.InvisibleButton(ctx, '##comp_graph', gs, gs)
    local mx = ImGui.GetMousePos(ctx)
    local tx, ty = px(S.c_thr), py(comp_curve(S.c_thr) + S.c_mk)
    local changed = false
    if ImGui.IsItemActivated(ctx) then
      if ctrl_down() then S.c_thr = CO_DEF.c_thr; changed = true else comp_drag = true end
    end
    if ImGui.IsItemActive(ctx) and comp_drag then
      S.c_thr = math.floor(math.max(-60, math.min(0, (mx - gx) / gs * 60 - 60)) * 10 + 0.5) / 10
      changed = true
    end
    if ImGui.IsItemDeactivated(ctx) then comp_drag = false end
    if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then S.c_thr = CO_DEF.c_thr; changed = true end
    if ImGui.IsItemHovered(ctx) or comp_drag then
      ImGui.SetTooltip(ctx, ('Threshold %.1f dB  (drag left / right, Ctrl+click resets)'):format(S.c_thr))
    end
    local hot = comp_drag or ImGui.IsItemHovered(ctx)
    ImGui.DrawList_AddCircle(dl, tx, ty, hot and 7 or 6, T.glow, 0, 2)
    ImGui.DrawList_AddText(dl, gx + 4, gy + 2, T.grid_text, ('%.0f dB'):format(S.c_thr))
    if active_meters and meter_in > -60 then
      ImGui.DrawList_AddCircleFilled(dl, px(meter_in), py(comp_curve(meter_in) + S.c_mk), 4, T.glow)
    end

    local ks = math.max(20, math.min(28, h - 2 * th - 14))
    local kw = math.max(UI.sz(58), ImGui.CalcTextSize(ctx, 'Release') + 10, ImGui.CalcTextSize(ctx, '200.0 ms') + 8)
    local kx = gx + gs + 12 + (kw - ks) / 2
    local ky = y + (h - ks) / 2 - 1
    local c
    ImGui.SetCursorScreenPos(ctx, kx, ky)
    c, S.c_ratio = knob('##ratio', 'Ratio', S.c_ratio, 1, 20, CO_DEF.c_ratio, '%.1f:1', true, ks, T.heart,
      'Ratio. Drag up/down (Shift = fine), Ctrl+click resets.')
    changed = changed or c
    ImGui.SetCursorScreenPos(ctx, kx + kw, ky)
    c, S.c_att = knob('##att', 'Attack', S.c_att, 0.1, 200, CO_DEF.c_att, '%.1f ms', true, ks, T.sparkle,
      'Attack. Drag up/down (Shift = fine), Ctrl+click resets.')
    changed = changed or c
    ImGui.SetCursorScreenPos(ctx, kx + kw * 2, ky)
    c, S.c_rel = knob('##rel', 'Release', S.c_rel, 5, 2000, CO_DEF.c_rel, '%.0f ms', true, ks, T.ok,
      'Release. Drag up/down (Shift = fine), Ctrl+click resets.')
    changed = changed or c
    ImGui.SetCursorScreenPos(ctx, kx + kw * 3, ky)
    c, S.c_mk = knob('##mk', 'Makeup', S.c_mk, 0, 24, CO_DEF.c_mk, '%.1f dB', false, ks, 0xC7B3EEFF,
      'Makeup gain. Drag up/down (Shift = fine), Ctrl+click resets.')
    changed = changed or c
    if changed then apply_comp() end

    -- gain reduction, 0 to 24 dB
    local mxp = x + w - 20
    local mh = gs
    ImGui.DrawList_AddRectFilled(dl, mxp, gy, mxp + 12, gy + mh, T.wave_bg, 3)
    if gr > 0.05 then
      ImGui.DrawList_AddRectFilled(dl, mxp, gy, mxp + 12, gy + mh * math.min(1, gr / 24), T.glow, 3)
    end
    ImGui.DrawList_AddRect(dl, mxp, gy, mxp + 12, gy + mh, T.cols.Border, 3)
  end

  local function fx_area_impl()
    local w = ImGui.GetContentRegionAvail(ctx)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    if w < UI.sz(560) then
      ImGui.TextDisabled(ctx, 'widen the window to show EQ and comp')
      return
    end
    local h = UI.fx_h
    local need = math.max(UI.sz(70), ImGui.CalcTextSize(ctx, 'GR 24.0') + 16) + 8 + (h - 12) + 12
      + 4 * math.max(UI.sz(58), ImGui.CalcTextSize(ctx, 'Release') + 10, ImGui.CalcTextSize(ctx, '200.0 ms') + 8) + 30
    local cw = math.min(math.max(UI.sz(440), need, w * 0.4), math.max(UI.sz(500), need))
    local ew = w - cw - 10
    eq_panel(x, y, ew, h)
    comp_panel(x + ew + 10, y, cw, h)
    ImGui.SetCursorScreenPos(ctx, x, y)
    ImGui.Dummy(ctx, w, h)
  end
  return fx_area_impl
end)()

local function loop()
  local _
  frame = frame + 1
  process_trash()
  -- the project starts playing: stop the preview
  local rolling = (reaper.GetPlayState() & 5) ~= 0
  if rolling and not was_rolling then
    autoplay_pending = nil
    if playing then stop() end
  end
  was_rolling = rolling
  if wf_request then
    local f = wf_request
    wf_request = nil
    if f == cur then load_waveform(f) end
  end
  process_wf_job()
  if autoplay_pending then
    if autoplay_pending ~= cur or playing then
      autoplay_pending = nil
    elseif wf and not wf.building then
      autoplay_pending = nil
      play(0)
    end
  end
  poll_preview()
  if S.comp_on and playing then read_meters() end

  if loading then
    local ok, err = coroutine.resume(loader)
    if not ok then
      loading = false
      reaper.ShowConsoleMsg('yj_SoundPicker load error: ' .. tostring(err) .. '\n')
    elseif coroutine.status(loader) == 'dead' then
      loading = false
      need_search = true
    end
  else
    if counting then
      local ok = coroutine.resume(counter)
      if not ok or coroutine.status(counter) == 'dead' then counting = false end
    end
    local now = reaper.time_precise()
    if query ~= typed_query then
      typed_query = query; edit_time = now
      -- typing a new search clears the word filters, not the checkboxes
      if F.any ~= '' or F.none ~= '' or F.phrase ~= '' then F.any, F.none, F.phrase = '', '', '' end
    end
    if filters_changed_at and now - filters_changed_at >= 0.15 then
      filters_changed_at = nil
      need_search = true
    end
    if need_search or (typed_query ~= last_query and now - edit_time >= 0.1) then
      last_query = typed_query
      need_search = false
      start_search()
    end
    process_search()
  end

  local nc, nv = push_theme()
  ImGui.SetNextWindowSize(ctx, 1100, 740, ImGui.Cond_FirstUseEver)
  if set_dock then
    ImGui.SetNextWindowDockID(ctx, set_dock)
    set_dock = nil
  end
  local visible, open = ImGui.Begin(ctx, 'yj_SoundPicker###yj_SoundPicker', true)
  if visible then
    local dock_id = ImGui.GetWindowDockID(ctx)
    S.dock = dock_id
    local th = ImGui.GetTextLineHeightWithSpacing(ctx)

    top_bar(dock_id)
    status_line()

    -- extra height is shared by the list, the waveform and the EQ / comp
    local aw_full, avail_h = ImGui.GetContentRegionAvail(ctx)
    local rows2 = ImGui.GetFrameHeightWithSpacing(ctx) * 2
    local fx_base = ImGui.GetFrameHeightWithSpacing(ctx) * 3 - 7
    UI.wide = aw_full >= UI.sz(830) + UI.sz(620)
    local function bottom(wave_h, fx_h)
      local controls = UI.wide and math.max(rows2, fx_h) or (rows2 + 10 + fx_h)
      return th + 10 + wave_h + 10 + controls + 14
    end
    local extra = math.max(0, avail_h - 160 - bottom(100, fx_base))
    local wave_h = math.min(360, 100 + extra * 0.25)
    UI.fx_h = math.min(UI.sz(320), fx_base + extra * 0.2)
    local table_h = math.max(120, avail_h - bottom(wave_h, UI.fx_h))

    local tx, ty = ImGui.GetCursorScreenPos(ctx)
    local tw = ImGui.GetContentRegionAvail(ctx)
    local tflags = ImGui.TableFlags_ScrollY | ImGui.TableFlags_RowBg
                 | ImGui.TableFlags_Resizable | ImGui.TableFlags_BordersInnerV
    if ImGui.BeginTable(ctx, 'results', 8, tflags, 0, table_h) then
      ImGui.TableSetupScrollFreeze(ctx, 0, 1)
      ImGui.TableSetupColumn(ctx, 'Name', ImGui.TableColumnFlags_WidthStretch, 3)
      ImGui.TableSetupColumn(ctx, 'Description', ImGui.TableColumnFlags_WidthStretch, 4)
      ImGui.TableSetupColumn(ctx, 'Category', ImGui.TableColumnFlags_WidthStretch, 1.2)
      ImGui.TableSetupColumn(ctx, 'Length', ImGui.TableColumnFlags_WidthFixed, UI.sz(62))
      ImGui.TableSetupColumn(ctx, 'SR', ImGui.TableColumnFlags_WidthFixed, UI.sz(44))
      ImGui.TableSetupColumn(ctx, 'Ch', ImGui.TableColumnFlags_WidthFixed, UI.sz(26))
      ImGui.TableSetupColumn(ctx, 'Bit', ImGui.TableColumnFlags_WidthFixed, UI.sz(28))
      ImGui.TableSetupColumn(ctx, 'Library', ImGui.TableColumnFlags_WidthStretch, 1.4)
      ImGui.TableHeadersRow(ctx)

      local row_h = ImGui.GetTextLineHeightWithSpacing(ctx)
      if scroll_top then ImGui.SetScrollY(ctx, 0); scroll_top = false end
      if scroll_to then
        local target = scroll_to * row_h
        local sy = ImGui.GetScrollY(ctx)
        local wh = ImGui.GetWindowHeight(ctx)
        if target - row_h < sy + row_h then
          ImGui.SetScrollY(ctx, math.max(0, target - 2 * row_h))
        elseif target + row_h > sy + wh then
          ImGui.SetScrollY(ctx, target + row_h - wh)
        end
        scroll_to = nil
      end

      local sflags = ImGui.SelectableFlags_SpanAllColumns | ImGui.SelectableFlags_AllowDoubleClick
      local row_drag = ImGui.IsMouseDragging(ctx, ImGui.MouseButton_Left, 6)
      ImGui.ListClipper_Begin(clipper, #results)
      while ImGui.ListClipper_Step(clipper) do
        local ds, de = ImGui.ListClipper_GetDisplayRange(clipper)
        for i = ds + 1, de do
          local f = get_info(results[i])
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          if i == sel_idx then
            local rx, ry = ImGui.GetCursorScreenPos(ctx)
            ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), rx - 7, ry - 2, rx - 3,
              ry + ImGui.GetTextLineHeight(ctx) + 2, T.heart, 2)
          end
          local is_sel = (MS.n > 1) and (MS.keys[results[i]] == true) or (MS.n <= 1 and i == sel_idx)
          if is_sel then -- hovering the chosen row keeps its highlight
            ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, T.cols.Header)
            ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, T.cols.Header)
          end
          local clicked = ImGui.Selectable(ctx, f.name .. '##r' .. i, is_sel, sflags)
          if is_sel then ImGui.PopStyleColor(ctx, 2) end
          if clicked then
            local mods = ImGui.GetKeyMods(ctx)
            local k = results[i]
            if (mods & ImGui.Mod_Shift) ~= 0 then
              local a = MS.anchor_index() or sel_idx
              if a < 1 then a = i end
              MS.range(a, i)
              select_index(i)
            elseif (mods & ImGui.Mod_Ctrl) ~= 0 then
              if MS.n == 0 and sel_idx > 0 and sel_idx ~= i then MS.single(results[sel_idx]) end
              MS.toggle(k)
              if MS.keys[k] then select_index(i) end
            else
              MS.single(k)
              select_index(i)
              if ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then spot() end
            end
          end
          if row_drag and not drag_out and ImGui.IsItemActive(ctx) then
            if MS.n > 1 and MS.keys[results[i]] then
              drag_out = { whole = true, keys = MS.list() }
            else
              if i ~= sel_idx then MS.single(results[i]); select_index(i) end
              drag_out = { whole = true }
            end
          end
          for c, txt in ipairs(f.cells) do
            if txt ~= '' then
              ImGui.TableSetColumnIndex(ctx, c)
              ImGui.Text(ctx, txt)
            end
          end
          if (f.maker or f.lib ~= f.db) and ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, (f.maker and (f.maker .. '  /  ') or '') .. f.lib .. '\ndatabase: ' .. f.db)
          end
        end
      end
      ImGui.EndTable(ctx)
    end
    if not search_active and not loading and #dbs > 0 then
      local dl = ImGui.GetWindowDrawList(ctx)
      local msg = 'type something to start searching'
      local mw, lh = ImGui.CalcTextSize(ctx, msg)
      local head = ImGui.GetFrameHeight(ctx)
      local cx = tx + tw / 2
      local cy = ty + head + (table_h - head) / 2
      local ty1 = cy - lh / 2
      ImGui.DrawList_AddText(dl, cx - mw / 2, ty1, T.cols.TextDisabled, msg)
      draw_icon(dl, 'sparkle', cx - mw / 2 - 22, cy - 7, 2, T.sparkle)
      draw_icon(dl, 'sparkle', cx + mw / 2 + 8, cy - 7, 2, T.sparkle)
    end

    ImGui.Separator(ctx)
    if cur then
      ImGui.Text(ctx, cur.name)
      ImGui.SameLine(ctx)
      ImGui.TextColored(ctx, T.heart, (cur.maker and (cur.maker .. '  /  ') or '') .. cur.lib)
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, ('%s  %s  %sch  %sbit   %s%s'):format(
        fmt_len(source_len()), fmt_sr(cur.sr), tostring(cur.ch or '?'), tostring(cur.bits or '?'),
        (sel_a and sel_b) and ('selection ' .. fmt_len(sel_b - sel_a) .. '   ') or '',
        S.reverse and 'reversed' or ''))
    else
      ImGui.TextDisabled(ctx, 'select a result to preview')
    end
    local ww = ImGui.GetContentRegionAvail(ctx)
    draw_waveform(ww, wave_h)

    local two_col = UI.wide and ImGui.BeginTable(ctx, 'controls', 2, 0)
    if two_col then
      ImGui.TableSetupColumn(ctx, 'left', ImGui.TableColumnFlags_WidthFixed, UI.sz(830))
      ImGui.TableSetupColumn(ctx, 'right', ImGui.TableColumnFlags_WidthStretch, 1)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
    end

    -- transport
    if icon_button('##play', playing and 'stop' or 'play', playing and 'Stop' or 'Play', playing, 'Play / stop (Space)') then
      toggle_play()
    end
    ImGui.SameLine(ctx)
    if icon_button('##loop', 'loop', nil, S.loop, 'Loop') then
      S.loop = not S.loop
      apply_preview_params()
    end
    ImGui.SameLine(ctx)
    if icon_button('##rev', 'rev', nil, S.reverse,
        HAS_SECTION and 'Reverse (preview and spot)' or 'Reverse needs SWS 2.13.2 or newer', not HAS_SECTION) then
      set_reverse(not S.reverse)
    end
    ImGui.SameLine(ctx)
    ImGui.AlignTextToFramePadding(ctx)
    _, S.autoplay = ImGui.Checkbox(ctx, 'Auto-play', S.autoplay)
    ImGui.SameLine(ctx)
    if icon_button('##spot', 'spot', 'Spot (S)', false,
        'Inserts the file (or waveform selection) at the edit cursor\non the selected track, with pitch, volume and reverse applied.\nWith several files selected, they go in one after another.') then
      spot_selected()
    end
    ImGui.SameLine(ctx, 0, 16)
    ImGui.SetNextItemWidth(ctx, UI.sz(100))
    local nout = math.max(2, reaper.GetNumAudioOutputs())
    local function pair_label(i) return ('Out %d/%d'):format(i * 2 + 1, i * 2 + 2) end
    if ImGui.BeginCombo(ctx, '##out', pair_label(math.floor(S.outpair))) then
      for i = 0, nout // 2 - 1 do
        if ImGui.Selectable(ctx, pair_label(i), i == S.outpair) then
          S.outpair = i
          fx_route()
          if playing then play(play_pos) end
        end
      end
      ImGui.EndCombo(ctx)
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Audio interface outputs used for previews (with or without EQ / comp).\nPreviews go straight to these outputs, so master FX and the master fader are not applied.')
    end
    ImGui.SameLine(ctx, 0, 16)
    inline_icon('speaker', T.icon, 2)
    ImGui.SameLine(ctx, 0, 6)
    local cm
    cm, S.mon_db = slider('##mon', S.mon_db, -48, 12, 'mon %.0f dB', 0, 130,
      'Monitor level: changes what you hear while auditioning only,\nnever the volume of spotted items. Ctrl+click to reset.')
    if cm then apply_preview_params() end

    -- volume, pitch, fit
    local changed, c = false, nil
    c, S.vol_db = slider('Vol dB', S.vol_db, -36, 12, '%.1f', 0, 140,
      'Item volume: used for previews and for spotted items. Ctrl+click to reset.')
    changed = changed or c
    ImGui.SameLine(ctx)
    local ptip = 'With Preserve pitch off it also changes the speed, like tape (+12 st = 2.00x = twice as fast).\nCtrl+click to reset'
    if S.pitch_unit == 'rate' then
      local r = 2 ^ (S.pitch / 12)
      c, r = slider('##pitch_x', r, 0.25, 4, '%.2fx', 1, 140, ptip, true)
      if c then S.pitch = 12 * math.log(math.max(r, 1e-6), 2) end
    else
      c, S.pitch = slider('##pitch_st', S.pitch, -24, 24, '%.1f', 0, 140, ptip)
    end
    changed = changed or c
    ImGui.SameLine(ctx, 0, 4)
    ImGui.SetNextItemWidth(ctx, UI.sz(84))
    if ImGui.BeginCombo(ctx, '##pitch_unit', S.pitch_unit == 'rate' and 'Pitch x' or 'Pitch st') then
      if ImGui.Selectable(ctx, 'Semitones (st)', S.pitch_unit ~= 'rate') then S.pitch_unit = 'st' end
      if ImGui.Selectable(ctx, 'Ratio (x)', S.pitch_unit == 'rate') then S.pitch_unit = 'rate' end
      ImGui.EndCombo(ctx)
    end
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, 'Show pitch in semitones or as a ratio') end
    ImGui.SameLine(ctx)
    c, S.ppitch = ImGui.Checkbox(ctx, 'Preserve pitch', S.ppitch)
    changed = changed or c
    ImGui.SameLine(ctx)
    ImGui.SetNextItemWidth(ctx, UI.sz(80))
    c, S.fit = ImGui.InputDouble(ctx, 'Fit to s', S.fit, 0, 0, '%.2f')
    if S.fit < 0 then S.fit = 0 end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, 'Stretch the file (or selection) to this length in seconds.\n0 = off: the speed then follows Pitch (with Preserve pitch off).')
    end
    changed = changed or c
    if S.fit > 0 and cur then
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, ('= %.3fx'):format(eff_rate()))
    end
    if changed then apply_preview_params() end

    if two_col then
      ImGui.TableNextColumn(ctx)
      fx_area()
      ImGui.EndTable(ctx)
    else
      ImGui.Dummy(ctx, 0, 2)
      fx_area()
    end

    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) then
      local step = ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) and 1
        or (ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) and -1) or nil
      if step and #results > 0 then
        local ni = math.max(1, math.min(#results, sel_idx + step))
        if shift_down() then
          if not MS.anchor and sel_idx > 0 then MS.anchor = results[sel_idx] end
          MS.range(MS.anchor_index() or ni, ni)
        else
          MS.single(results[ni])
        end
        select_index(ni)
        scroll_to = sel_idx
      end
      local typing = ImGui.IsAnyItemActive(ctx)
      if not typing and not was_typing then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then toggle_play() end
        if ImGui.IsKeyPressed(ctx, ImGui.Key_S, false)
          or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter, false)
          or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter, false) then
          spot_selected()
        end
      end
      was_typing = typing
    end

    handle_drop(ctx)
    ImGui.End(ctx)
  end

  -- settings window
  if S.settings_win then
    ImGui.SetNextWindowSize(ctx, UI.sz(320), 0, ImGui.Cond_FirstUseEver)
    local sv, sopen = ImGui.Begin(ctx, 'yj_SoundPicker settings###yj_SoundPickerSettings', true,
      ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoCollapse)
    if sv then
      ImGui.TextDisabled(ctx, 'Look')
      local function pick(label, id, cur_label, items, set)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, label)
        ImGui.SameLine(ctx, UI.sz(90))
        ImGui.SetNextItemWidth(ctx, UI.sz(160))
        if ImGui.BeginCombo(ctx, id, cur_label) then
          for _, it in ipairs(items) do
            if ImGui.Selectable(ctx, it[2], it[2] == cur_label) then set(it[1]) end
          end
          ImGui.EndCombo(ctx)
        end
      end
      local THEME_NAMES = { { 'rose', 'Rose' }, { 'sage', 'Sage' }, { 'rainbow', 'Rainbow' }, { 'simple', 'Simple' } }
      pick('Theme', '##theme', S.theme:sub(1, 1):upper() .. S.theme:sub(2), THEME_NAMES, function(v) S.theme = v end)
      pick('Mode', '##mode', S.mode == 'dark' and 'Dark' or 'Light',
        { { 'light', 'Light' }, { 'dark', 'Dark' } }, function(v) S.mode = v end)
      pick('Icons', '##icons', S.icons == 'smooth' and 'Smooth' or 'Pixel',
        { { 'pixel', 'Pixel' }, { 'smooth', 'Smooth' } }, function(v) S.icons = v end)
      local sizes = {}
      for _, z in ipairs(UI.SIZES) do sizes[#sizes + 1] = { z, z == 13 and '13 (default)' or tostring(z) } end
      pick('Font size', '##font', S.font_size == 13 and '13 (default)' or tostring(math.floor(S.font_size)),
        sizes, function(v) S.font_size = v end)
      ImGui.Spacing(ctx); ImGui.Separator(ctx); ImGui.Spacing(ctx)

      ImGui.TextDisabled(ctx, 'Spotting')
      _, S.glue = ImGui.Checkbox(ctx, 'Glue on spot (bake)', S.glue)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Renders pitch, volume, reverse, EQ and comp into a new file on spot.')
      end
      _, S.advance = ImGui.Checkbox(ctx, 'Move cursor after spot', S.advance)
      _, S.copy = ImGui.Checkbox(ctx, 'Copy to project', S.copy)
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Copies the file into this project's media folder before spotting,\nso the project keeps working when the library drive is offline.\nThe same file is only copied once.")
      end
      ImGui.Spacing(ctx); ImGui.Separator(ctx); ImGui.Spacing(ctx)

      ImGui.TextDisabled(ctx, 'Waveform')
      local cs
      cs, S.spectral = ImGui.Checkbox(ctx, 'Spectral colours', S.spectral)
      if cs and cur then wf_request = cur end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, 'Colours the waveform by frequency, in the colours of the current theme.\nUses the spectral data REAPER stores in its peak files. If a file shows\n"no spectral data", turn on Spectral peaks in View > Peaks display settings\nand rebuild its peaks.')
      end
      ImGui.Spacing(ctx); ImGui.Separator(ctx); ImGui.Spacing(ctx)

      ImGui.TextDisabled(ctx, 'Help')
      _, S.tips = ImGui.Checkbox(ctx, 'Show hover guides', S.tips)
      ImGui.End(ctx)
    end
    if not sopen then S.settings_win = false end
  end
  pop_theme(nc, nv)

  if open then
    reaper.defer(loop)
  end
end

local function on_exit()
  if drag_out then ghost_remove(drag_out) end
  local recent = preview ~= nil or frame - last_stop_frame <= TRASH_FRAMES
  stop() -- its source is not freed here, see process_trash
  -- leave the temp track if audio was just playing through it (removed on the next launch)
  if not recent then delete_fx_tracks() end
  process_trash()
  cancel_wf_job()
  save_settings()
end

--- Start
load_db_list()
write_jsfx()
delete_fx_tracks() -- leftovers from last time: EQ / comp start fresh
reaper.atexit(on_exit)
reaper.defer(loop)
