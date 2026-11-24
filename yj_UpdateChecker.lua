-- @description yj_UpdateChecker
-- @author Yeji Jung
-- @version 1.0
-- @about
--   Asks the repository whether a newer yj_SoundPicker or yj_SoundSampler has been published, and tells you either way.
--   Press Check for Updates in yj_SoundPicker's settings, or run this from the action list.

local R = reaper
local INDEX = 'https://github.com/yejijung-sound/yj_SoundPicker/raw/main/index.xml'
local WATCH = { 'yj_SoundPicker.lua', 'yj_SoundSampler.lua' }
local EXT = 'yj_UpdateChecker'
local GIVE_UP = 15

local me = select(2, R.get_action_context())
local dir = me:match('^(.*[\\/])') or ''
local suffix = (me:match('^.*[\\/]yj_UpdateChecker(.-)%.lua$')) or ''
local function local_name(pkg)
  return suffix == '' and pkg or (pkg:gsub('%.lua$', suffix .. '.lua'))
end

--- Versions -----------------------------------------------------------------

local function newer(a, b)
  local ai, bi = a:gmatch('%d+'), b:gmatch('%d+')
  while true do
    local x, y = tonumber(ai() or ''), tonumber(bi() or '')
    if not x and not y then return false end
    if (x or 0) ~= (y or 0) then return (x or 0) > (y or 0) end
  end
end

-- The @version line of a script sitting next to this one.
local function installed(file)
  local f = io.open(dir .. file, 'r')
  if not f then return nil end
  local v
  for _ = 1, 40 do
    local line = f:read('l')
    if not line then break end
    v = line:match('^%-%-%s*@version%s+([%w%.%-]+)')
    if v then break end
  end
  f:close()
  return v
end

-- The newest version each package offers
local function published(xml)
  local out = {}
  for block in xml:gmatch('<reapack.-</reapack>') do
    local name = block:match('name="([^"]+%.lua)"')
    if name then
      local best
      for v in block:gmatch('<version%s+name="([^"]+)"') do
        if not best or newer(v, best) then best = v end
      end
      out[name] = best
    end
  end
  return out
end

--- Fetching -----------------------------------------------------------------

local TMP = R.GetResourcePath() .. '/yj_UpdateChecker.tmp'

local function start_fetch()
  if not R.ExecProcess then return false end
  os.remove(TMP)
  local win = R.GetOS():find('Win') ~= nil
  local cmd = win
    and ('curl.exe -s -L --max-time 12 -o "' .. TMP .. '" "' .. INDEX .. '"')
    or ('/bin/sh -c "curl -s -L --max-time 12 -o \'' .. TMP .. '\' \'' .. INDEX .. '\'"')
  R.ExecProcess(cmd, -2)
  return true
end

local function take_body()
  local f = io.open(TMP, 'r')
  if not f then return nil end
  local body = f:read('a') or ''
  f:close()
  if not body:find('</index>', 1, true) then return nil end
  os.remove(TMP)
  return body
end

--- Reporting ----------------------------------------------------------------

local function report(behind)
  local lines = { 'A newer version is out:', '' }
  for _, b in ipairs(behind) do
    lines[#lines + 1] = ('  %s   %s  ->  %s'):format(b.file, b.have, b.want)
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Update it in ReaPack: Extensions > ReaPack > Synchronize packages.'
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Open ReaPack now?'
  if R.MB(table.concat(lines, '\n'), 'yj scripts: update available', 4) == 6 then
    local cmd = R.NamedCommandLookup('_REAPACK_SYNC')
    if cmd ~= 0 then R.Main_OnCommand(cmd, 0) else R.MB(
      'ReaPack\'s synchronize action was not found.\n\nOpen Extensions > ReaPack > Synchronize packages.',
      'yj scripts', 0) end
  end
end

local function unreachable()
  R.MB('Could not reach the repository.\n\nCheck your connection, or look in ReaPack: ' ..
    'Extensions > ReaPack > Synchronize packages.', 'yj scripts', 0)
end

local function verdict(xml)
  local latest = published(xml)
  local behind, lines = {}, {}
  for _, pkg in ipairs(WATCH) do
    local file = local_name(pkg)
    local have, want = installed(file), latest[pkg]
    if have and want and newer(want, have) then
      behind[#behind + 1] = { file = file, have = have, want = want }
    end
    lines[#lines + 1] = ('  %s   %s'):format(file, have or 'not installed here')
  end
  if #behind > 0 then
    report(behind)
  else
    R.MB('Everything is up to date.\n\n' .. table.concat(lines, '\n'), 'yj scripts', 0)
  end
end

--- Start --------------------------------------------------------------------

local function done(f, ...)
  R.DeleteExtState(EXT, 'busy', false)
  return f(...)
end

-- One check at a time
local beat = tonumber(R.GetExtState(EXT, 'busy'))
if beat and R.time_precise() - beat < 2 then return end

if not start_fetch() then return done(unreachable) end

local due = R.time_precise() + GIVE_UP
local function poll()
  R.SetExtState(EXT, 'busy', tostring(R.time_precise()), false)
  local xml = take_body()
  if xml then return done(verdict, xml) end
  if R.time_precise() > due then
    os.remove(TMP)
    return done(unreachable)
  end
  R.defer(poll)
end
R.defer(poll)
