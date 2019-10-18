-- reload.lua: automatic reloading of network stream when cache doesn't fill.
--
--
-- Generally we react to situations when the player pauses itself because the
-- cache runs empty (event paused-for-cache is fired). When this happens, we
-- start a timer and wait s.max seconds for the player to unpause itself, and
-- when that doesn't happen we do a reload of the stream. So when the player
-- gets stuck, s.max is the maximum time, in seconds, we're willing to wait
-- before performing a reload.
--
-- Additionally, we also monitor the demuxer cache, and how long it didn't
-- receive any updates. And if this time surpasses d.max, we don't even start a
-- timer in the above scenario but reload immediately when the player gets
-- paused. So we choose d.max so that it's a good indicator that the stream
-- indeed is somehow stuck. For HLS streams this value should probably be chosen
-- according to chunk size, but 20 seconds is probably a reasonable number.
--
-- Finally, if we do a reload and it fails there's nothing to play, and mpv
-- would normally shut down. We set the "idle" and "force-window" parameters
-- though, so that the player does stay open. On the other hand, with nothing to
-- play there won't be any pause/unpause events anymore, so that's why we allow
-- for another reload in the demuxer cache timer function, which is performed
-- when the demuxer cache has been stale for d.max seconds and the player is
-- otherwise idle. With this approach, we keep performing reloads each d.max
-- seconds even when one or more reloads fail, so that hopefully sometime the
-- stream comes back.
--
-- And that's already pretty much all this script does. So s.max and d.max are
-- the two values you might want to tune according to your needs.
--
--


local msg    = require 'mp.msg'
local s      = {}   -- stream cache table
local d      = {}   -- demuxer cache table
local path   = ""   -- stream url, gets initialized on load
local notify = true -- use notify-send for desktop notification

-- stream cache handling, times in seconds
s.interval = 2  -- timer interval; set to 0 to disable reloading altogether
s.max      = 10 -- how long to wait for paused stream to unpause before reload
s.total    = 0  -- total of seconds the player has been in cache paused state
s.timer    = nil
-- demuxer cache handling, times in seconds
d.interval = 4  -- timer interval; set to 0 to disable demuxer cache monitoring
d.max      = 20 -- stuck time of demuxer cache considered reload worthy
d.last     = 0  -- last demuxer-cache-time we have seen
d.total    = 0  -- count of how many seconds d.last has been the same
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

   -- when the stream, like an m3u8, goes empty then the paused-for-cache event
   -- isn't being fired anymore, so we need a fallback reload for that case
   if
      d.total >= d.max
      and not (s.timer and s.timer:is_enabled())
      and mp.get_property_native('idle-active')
   then
         msg.debug('d.tick reload', d.total, s.total)
         reload()
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

      -- playback is paused and demuxer cache has been stale for a while ->
      -- immediate reload
      if d.total >= d.max then
         msg.debug("s.handler demuxer reload", d.total, s.total)
         reload()
      -- else create/resume timer, to give player a chance to unpause before
      -- reload
      elseif not s.timer then
         msg.debug("s.handler create s.timer")
         s.timer = mp.add_periodic_timer(
            s.interval,
            function()
               s.total = s.total + s.interval
               msg.debug("s.timer", s.total)
               if s.total >= s.max then
                  msg.info('s.handler timer reload', d.total, s.total)
                  reload()
               end
            end
         )
      elseif not s.timer:is_enabled() then
         msg.debug("s.handler resume s.timer")
         s.timer:resume()
      else
         -- can consecutive pause events happen?
         msg.info('s.handler timer enabled')
      end

   -- player unpaused, stop timer and reset counters
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
   if notify then
      -- continue script execution if notify-send call fails
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
         msg.info("path", path)
      end
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
