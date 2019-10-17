-- reload.lua: automatic reloading of network stream when cache doesn't load.
--
--
-- We monitor two caches, the stream cache and the demuxer cache, and when
-- either doesn't see progress for some time we do a reload of the stream url.
--
-- Those times are s.max for the stream cache, and d.max for the demuxer cache,
-- where we choose those values to be a couple of seconds apart, with the latter
-- being the higher one.
--
-- The monitoring of either is connected to a timer, governed by s.interval for
-- the stream and d.interval for the demuxer cache. Setting either (or both) of
-- those interval values to 0 disables the associated monitoring entirely.
--
--

local msg  = require 'mp.msg'
local s    = {} -- stream cache table
local d    = {} -- demuxer cache table
local path = "" -- stream url

-- stream cache handling
s.interval = 2  -- set to 0 to disable stream cache monitoring
s.max      = 16 -- reload after this many seconds
s.total    = 0
s.timer    = nil
-- demuxer cache handling
d.interval = 4  -- set to 0 to disable demuxer cache monitoring
d.max      = 19 -- reload after this many seconds
d.last     = 0
d.total    = 0
d.timer    = nil


--
-- demuxer cache related functions
--
function d.reset()
   msg.debug("d.reset")
   d.last  = 0
   d.total = 0
end

-- to be called by timer
function d.tick()

   local cache_time = mp.get_property_native('demuxer-cache-time') or -1
   local ct_rounded = string.format("%8.2f", cache_time)

   if cache_time == d.last then
      msg.debug('d.tick stuck', ct_rounded)
      d.total = d.total + d.interval
   else
      msg.debug('d.tick live ', ct_rounded)
      d.total = 0
      d.last = cache_time
   end

   if d.total > d.max and not (s.timer and s.timer:is_enabled()) then
      msg.info('d.tick reload')
      reload()
      if mp.get_property_native('core-idle') then
         msg.debug('d.tick core idle')
      end
   end
end


--
-- stream cache related functions
--
function s.reset()
   msg.debug("s.reset")
   s.total = 0
   if s.timer then s.timer:kill() end
end

-- to be called by observe_property function
function s.handler(property, is_paused)

   if is_paused then
      if not s.timer then
         msg.debug("s.handler create s.timer")
         s.timer = mp.add_periodic_timer(
            s.interval,
            function()
               s.total = s.total + s.interval
               msg.debug("s.timer", s.total)
               if s.total > s.max then
                  msg.info('s.handler reload')
                  reload()
               end
            end
         )
      elseif not s.timer:is_enabled() then
         msg.debug("s.handler resume s.timer")
         s.timer:resume()
      end
   else
      msg.debug("s.handler reset")
      s.reset()
   end
end


--
-- general functions
--
function reload()

   local time_pos = mp.get_property("time-pos")
   local fformat  = mp.get_property("file-format")

   s.reset()
   d.reset()

   os.execute('notify-send -t 0 -u low "mpv reload"')

   if fformat and time_pos and fformat ~= "hls" then
      msg.info("reload", path, time_pos)
      mp.osd_message("Reload: " .. path .. " " .. time_pos)
      mp.commandv("loadfile", path, "replace", "start=+" .. time_pos)
   else
      msg.info("reload", path)
      mp.osd_message("Reload: " .. path)
      mp.commandv("loadfile", path, "replace")
   end
end


--
-- main
--

-- keep window alive in case the stream returns empty on reload,
-- in which case we just keep reloading according to timer settings
mp.set_property("idle",         "yes")
mp.set_property("force-window", "yes")

-- on player startup, store stream url in path variable
mp.add_hook(
   "on_load",
   10,
   function ()
      path = mp.get_property("stream-open-filename")
      msg.info("path", path)
   end
)

-- cache pause event handling
if s.interval then
   mp.observe_property("paused-for-cache", "bool", s.handler)
end

-- demuxer cache handling
if d.interval then
   d.timer = mp.add_periodic_timer(
      d.interval,
      function()
         d.tick()
      end
   )
end
