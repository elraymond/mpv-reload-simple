--[[

   reload.lua: automatic reloading of media stream when demuxer cache doesn't
   fill.

--]]


local msg    = require 'mp.msg'
local http   = require('socket.http')
local https  = require('ssl.https')
local ltn12  = require('ltn12')

local d      = {}   -- demuxer cache table
local path   = ''   -- stream url, gets initialized on load
local notify = true -- use notify-send for desktop notification

-- demuxer cache handling, times in seconds
d.interval = 4  -- timer interval; set to 0 to disable demuxer cache monitoring
d.max      = 15 -- stuck time of demuxer cache considered reload worthy
d.min      = 6  --
d.last     = 0  -- last demuxer-cache-time we have seen
d.total    = 0  -- count of how many seconds d.last has been the same
d.timer    = nil

-- url redirects depending on mpv window title
local redirects = {
   ['MSNBCLNO'] = {
      url     = 'https://www.livenewsnow.com/american/msnbc.html',
      pattern = 'file: *"(http.*m3u8)'
   }
}

-- module initialization
http.USERAGENT  = 'Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.90 Safari/537.36'
http.TIMEOUT    = 3
https.USERAGENT = http.USERAGENT
https.TIMEOUT   = http.TIMEOUT


--
-- demuxer cache related functions
--
function d.reset()
   msg.debug('d.reset')
   d.last  = 0
   d.total = 0
end

function d.disable()
   if d.timer and d.timer:is_enabled() then
      msg.info('d.disable')
      d.timer:kill()
   end
end

function d.enable()
   if d.interval > 0 then
      msg.info('d.enable')
      d.timer =
         mp.add_periodic_timer(
            d.interval,
            function()
               d.tick()
            end
         )
   end
end

-- to be called by timer
function d.tick()

   local seekable       = mp.get_property_native('seekable')
   local cache_time     = mp.get_property_native('demuxer-cache-time') or -1
   local cache_duration = mp.get_property_native('demuxer-cache-duration') or -1
   local ct_rounded     = string.format('%8.2f/%4.1f', cache_time, cache_duration)

   -- don't monitor media files and the likes
   if seekable then
      d.disable()
      return
   end

   -- check progress on cache, adjust counters accordingly
   if cache_time == d.last then
      msg.debug('d.tick stuck', ct_rounded)
      d.total = d.total + d.interval
   else
      msg.debug('d.tick live ', ct_rounded)
      d.total = 0
      d.last = cache_time
   end

   -- reload when the demuxer cache didn't get data for more than d.max seconds
   -- and the remaining buffered seconds are less than d.min
   if
      d.total >= d.max and cache_duration < d.min
   then
         msg.debug('d.tick reload', d.total)
         reload(path)
   end
end


--
-- general functions
--

-- desktop notification
local function desktop_notify(msg)
   if notify then
      -- continue script execution if notify-send call fails
      pcall(
         function()
            os.execute('notify-send -t 0 -u low "' .. msg .. '"')
         end
      )
   end
end

-- download url and search for pattern in its html source
local function http_get_media_url(url, pattern)

      local html = {}

      if pattern == '' then
         return url
      end

      if string.match(url, '^https') then
         https.request{
            url=url,
            sink = ltn12.sink.table(html),
         }
      else
         http.request{
            url=url,
            sink = ltn12.sink.table(html),
         }
      end

      return string.match(table.concat(html), pattern)
end

local function reload(loadpath)

   local title    = mp.get_property('title') or ''
   local time_pos = mp.get_property('time-pos') or nil
   local seekable = mp.get_property_native('seekable') or nil

   d.reset()
   desktop_notify('reload ' .. title)

   if time_pos and seekable then
      msg.info('reload', loadpath, time_pos)
      mp.osd_message('Reload: ' .. loadpath .. ' ' .. time_pos)
      mp.commandv('loadfile', loadpath, 'replace', 'pause=no,start=+' .. time_pos)
   else
      msg.info('reload', loadpath)
      mp.osd_message('Reload: ' .. loadpath)
      mp.commandv('loadfile', loadpath, 'replace', 'pause=no')
   end
end

local function on_load_hook()

   local title    = mp.get_property('title')
   local redirect = redirects[title]
   local tmp      = ''

   if redirect then
      tmp = http_get_media_url(redirect['url'], redirect['pattern'])
      if tmp and tmp ~= '' then
         path = tmp
         msg.info('redirecting', path)
         mp.set_property('stream-open-filename', path)
      end
   end
   if path == '' then
      path = mp.get_property('stream-open-filename')
      msg.info('path', path)
   end
end


--
-- main
--

-- keep window alive in case the stream returns empty on reload,
-- in which case we just keep reloading according to timer settings
mp.set_property('idle',         'yes')
mp.set_property('force-window', 'yes')

-- on player startup, store stream url in path variable
mp.add_hook(
   'on_load',
   10,
   function ()
      on_load_hook()
   end
)

-- demuxer cache monitoring
d.enable()
