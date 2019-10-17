-- reload.lua: automatic reloading of network stream when cache doesn't fill.
--
--
-- We monitor two caches, the stream cache and the demuxer cache, and when
-- either doesn't see progress for some time we do a reload of the stream url.
--
-- More precisely, through a timer we monitor the demuxer cache and count in
-- d.total how many seconds it might have seen no progress, consecutively.
--
-- Then we observe the pause state of the stream cache. If it gets paused we
-- start a timer and count the seconds s.total during which it stays in paused
-- state. And as soon as d.total + s.total > max we do a reload. So max is the
-- upper bound in seconds of how long both caches combined can be in a stale
-- state before a reload occurs.
--
--

local msg    = require 'mp.msg'
local max    = 16   -- reload after this many seconds
local s      = {}   -- stream cache table
local d      = {}   -- demuxer cache table
local path   = ""   -- stream url
local notify = true -- use notify-send for desktop notification

-- stream cache handling
s.interval = 2  -- timer interval. set to 0 to disable reloading altogether
s.total    = 0
s.timer    = nil
-- demuxer cache handling
d.interval = 3  -- timer interval. set to 0 to disable demuxer cache monitoring
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

end


--
-- stream cache related functions
--
function s.reset()
   msg.debug("s.reset")
   s.total = 0
   if s.timer and s.timer:is_enabled() then
      s.timer:kill()
   end
end

-- to be called by observe_property function
function s.handler(property, is_paused)

   msg.debug("s.handler is_paused", is_paused)

   if is_paused == true then

      -- take account of how long the demuxer cache might have been stale
      -- already
      msg.debug("s.handler d.total", d.total)
      s.total = d.total

      if not s.timer then
         msg.debug("s.handler create s.timer")
         s.timer = mp.add_periodic_timer(
            s.interval,
            function()
               s.total = s.total + s.interval
               msg.debug("s.timer", s.total)
               if s.total > max then
                  msg.info('s.handler reload')
                  reload()
               end
            end
         )
      elseif not s.timer:is_enabled() then
         msg.debug("s.handler resume s.timer")
         s.timer:resume()
      else
         msg.info('s.handler timer enabled')
      end

   elseif is_paused == false then
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

   -- desktop notification
   if notfify then
      -- continue script if notify-send call fails
      pcall(
         function()
            os.execute('notify-send -t 0 -u low "mpv reload"')
         end
      )
   end

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
      if path == "" then
         path = mp.get_property("stream-open-filename")
      end
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
