local msg  = require 'mp.msg'
local p    = {}
local d    = {}
local path = "" -- stream url
-- cache pause event handling
p.interval = 2  -- set to 0 to disable
p.max      = 16 -- reload after this many seconds
p.total    = 0
p.timer    = nil
-- demuxer cache handling
d.interval = 4  -- set to 0 to disable
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

   if d.total > d.max and not (p.timer and p.timer:is_enabled()) then
      msg.info('d.tick reload')
      reload()
   end
end


--
-- cache pause event related functions
--
function p.reset()
   msg.debug("p.reset")
   p.total = 0
   if p.timer then p.timer:kill() end
end

-- to be called by observe_property function
function p.handler(property, is_paused)

   if is_paused then
      if not p.timer then
         msg.debug("p.handler create p.timer")
         p.timer = mp.add_periodic_timer(
            p.interval,
            function()
               p.total = p.total + p.interval
               msg.debug("p.timer", p.total)
               if p.total > p.max then
                  msg.info('p.handler reload')
                  reload()
               end
            end
         )
      elseif not p.timer:is_enabled() then
         msg.debug("p.handler resume p.timer")
         p.timer:resume()
      end
   else
      msg.debug("p.handler reset")
      p.reset()
   end
end


--
-- general functions
--
function reload()

   local time_pos = mp.get_property("time-pos")
   local fformat  = mp.get_property("file-format")

   p.reset()
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

-- store stream url in path variable
mp.add_hook(
   "on_load",
   10,
   function ()
      path = mp.get_property("stream-open-filename")
      msg.info("path", path)
   end
)

-- cache pause event handling
if p.interval then
   mp.observe_property("paused-for-cache", "bool", p.handler)
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
