lookahead = 0.5         --if the next subtitle appears after this threshold then speedup
speedup = 3.5           --the value that "speed" is set to during speedup
leadin = 0.5            --seconds to stop short of the next subtitle
skipmode = false      --instead of speeding up playback seek to the next known subtitle
maxSkip = 5            --max seek distance (seconds) when skipmode is enabled
minSkip = leadin       --this is also configurable but setting it too low can actually make your watch time longer
skipdelay = 1          --in skip mode, this setting delays each skip by x seconds (must be >=0)
directskip = false      --seek to next known subtitle (must be in cache) no matter how far away
dropOnAVdesync = true
--Because mpv syncs subtitles to audio it is possible that if audio processing lags behind--
--video processing then normal playback may not resume in sync with the video. If "avsync" > leadin--
--then this disables the audio so that we can ensure normal playback resumes on time.
ignorePattern = false  --if true, subtitles are matched against "subPattern". A successful match will be treated as if there was no subtitle
subPattern = "^[#♯♩♪♬♫🎵🎶%[%(]+.*[#♯♩♪♬♫🎵🎶%]%)]+$"
---------------User options above this line--

readahead_secs = mp.get_property_native("demuxer-readahead-secs")
normalspeed=mp.get_property_native("speed")
-- variable for interval in seconds to sync audio and video
-- sync_audio_and_video_interval = 60
sync_audio_and_video_interval = 15

function sync_audio_and_video()
    -- sync audio and video by going back by 0.1 seconds
      mp.commandv("seek", -0.1, "relative", "exact")
end

function shouldIgnore(subtext)
   if ignorePattern and subtext and subtext~="" then
      local st = subtext:match("^%s*(.-)%s*$") -- trim whitespace
      if st:find(subPattern) then
         return true
      end
   else
      return false
   end
end

function set_timeout()
   local time_out
   if mp.get_property_native("cache-size") ~= nil then
      time_out = mp.get_property_native("cache-secs")
   else
      time_out = mp.get_property_native("demuxer-readahead-secs")
   end
   return time_out
end

local aid
function restore_normalspeed()
   mp.set_property("speed", normalspeed)
   if mp.get_property_native("video-sync") == "desync" then
      mp.set_property("video-sync", "audio")
   end
   if (aid~=nil and aid~=mp.get_property("aid")) then mp.set_property("aid", aid) end
end

function check_should_speedup()
   local subdelay = mp.get_property_native("sub-delay")
   mp.command("no-osd set sub-visibility no")
   mp.command("no-osd sub-step 1")
   local mark = mp.get_property_native("time-pos")
   local nextsubdelay = mp.get_property_native("sub-delay")
   local nextsub = subdelay - nextsubdelay
   if ignorePattern and nextsub > 0 then
      local lookNext = true
      local ignore = shouldIgnore(mp.get_property("sub-text"))
      while ignore and lookNext do
         local delay1 = mp.get_property_native("sub-delay")
         mp.command("no-osd sub-step 1")
         local delay2 = mp.get_property_native("sub-delay")
         ignore = shouldIgnore(mp.get_property("sub-text"))
         if delay1 == delay2 then
            lookNext = false
            nextsub = 0
         else
            nextsub = subdelay - delay2
         end
      end
   end
   mp.set_property("sub-delay", subdelay)
   mp.command("no-osd set sub-visibility yes")
   return nextsub, nextsub >= lookahead or nextsub == 0, mark
end

function check_audio(_,ds)
   if state==0 then
      return
   elseif ds and tonumber(ds)>leadin and mp.get_property("aid")~="no" then
      aid = mp.get_property("aid")
      mp.set_property("aid", "no")
      print("avsync greater than leadin, dropping audio")
   end
end

function check_position(_, position)
   if position then
      if nextsub ~= 0 and position >= (mark+nextsub-leadin) then
         restore_normalspeed()
         mp.unobserve_property(check_position)
         mp.unobserve_property(check_audio)
      elseif nextsub == 0 and position >= (mark+set_timeout()-leadin) then
         nextsub, _ , mark = check_should_speedup()
      end
   end
end

function skipval()
   local skipval = mp.get_property_native("demuxer-cache-duration", 0)
   if nextsub > 0 then
      if directskip then
         skipval =  nextsub - leadin
      elseif nextsub - skipval - leadin <= 0 then
         skipval =  clamp(nextsub - leadin, 0, maxSkip)
      else
         skipval =  clamp(skipval, 0, maxSkip)
      end
   elseif directskip then
      skipval = clamp(skipval - leadin, 1, nil)
   else
      skipval = clamp(skipval - leadin, 1, maxSkip)
   end
   return skipval
end

firstskip = true   --make the first skip in skip mode not have to wait for skipdelay
delayEnd = true
function speed_transition(_, sub)
   if sub~=nil and shouldIgnore(sub) then
      sub = ""
   end;
   if state == 0 then
      if sub == "" then
         last_speedup_zone_begin = speedup_zone_begin
         nextsub, shouldspeedup, speedup_zone_begin = check_should_speedup()
         mark = speedup_zone_begin
         speedup_zone_end = mark + nextsub
         if shouldspeedup or (skipmode and not firstskip) then
            local temp_disable_skipmode = false
            if last_speedup_zone_begin and mark < last_speedup_zone_begin then
               temp_disable_skipmode = true
            end
            if skipmode and not temp_disable_skipmode and mp.get_property("pause") == "no" then
               if firstskip or skipdelay == 0 then
                  mp.commandv("no-osd", "seek", skipval(), "relative", "exact")
                  firstskip = false
               elseif delayEnd then
                  delayEnd = false
                  mp.add_timeout(skipdelay, function()
                     delayEnd = true
                     if mp.get_property("pause") == "no" then
                        nextsub, shouldskip = check_should_speedup()
                        if shouldskip or nextsub > leadin then
                           local tSkip = skipval()
                           currentSub = mp.get_property("sub-text")
                           if tSkip > minSkip and (currentSub == "" or shouldIgnore(currentSub)) then
                              mp.commandv("no-osd", "seek", tSkip, "relative", "exact")
                           else 
                              firstskip = true
                           end
                        end
                     end
                  end)
               end
            else
               normalspeed = mp.get_property("speed")
               if mp.get_property_native("video-sync") == "audio" then
                  mp.set_property("video-sync", "desync")
               end
               mp.set_property("speed", speedup)
               mp.observe_property("time-pos", "native", check_position)
               state = 1
               if dropOnAVdesync then
                  aid = mp.get_property("aid")
                  mp.observe_property("avsync", "native", check_audio)
               end
            end
         else
            firstskip = true
         end
      end
   elseif state == 1 then
      if (sub ~= "" and sub ~= nil) or not mp.get_property_native("sid") then
         mp.unobserve_property(check_position)
         mp.unobserve_property(check_audio)
         restore_normalspeed()
         state = 0
      else
         local pos = mp.get_property_native("time-pos", 0)
         if pos < speedup_zone_begin or pos > speedup_zone_end then
            nextsub, _ , mark = check_should_speedup()
         end
      end
   end
end

toggle2 = false

function toggle_sub_visibility()
   if not toggle2 then
      sub_color = mp.get_property("sub-color", "1/1/1/1")
      sub_color2 = mp.get_property("sub-border-color", "0/0/0/1")
      sub_color3 = mp.get_property("sub-shadow-color", "0/0/0/1")
      mp.set_property("sub-color", "0/0/0/0")
      mp.set_property("sub-border-color", "0/0/0/0")
      mp.set_property("sub-shadow-color", "0/0/0/0")
   else
      mp.set_property("sub-color", sub_color)
      mp.set_property("sub-border-color", sub_color2)
      mp.set_property("sub-shadow-color", sub_color3)
   end
   mp.osd_message("subtitle visibility: "..tostring(toggle2))
   toggle2 = not toggle2
end

function toggle_skipmode()
   skipmode = not skipmode
   if enable then
      mp.unobserve_property(speed_transition)
      mp.unobserve_property(check_position)
      mp.observe_property("sub-text", "native", speed_transition)
      state = 0
   end
   if skipmode then
      mp.osd_message("skip mode")
   else
      mp.osd_message("speed mode")
   end
end

function clamp(v,l,u)
   if l and v < l then
      v = l
   elseif u and v > u then
      v = u
   end
   return v
end

function change_speedup(v)
   speedup = speedup + v
   mp.osd_message("speedup: "..speedup)
end

function change_leadin(v)
   --leadin = clamp(leadin + v, 0, 2)
   leadin = clamp(leadin + v, 0, nil)
   mp.osd_message("leadin: "..leadin)
end

function change_lookAhead(v)
   lookahead = clamp(lookahead + v , 0, nil)
   mp.osd_message("lookahead: "..lookahead)
end

enable = false
state = 0

function toggle()
   if not enable then
      normalspeed = mp.get_property("speed")
      mp.set_property("demuxer-readahead-secs",lookahead+leadin)
      mp.observe_property("sub-text", "native", speed_transition)
      mp.osd_message("speed-transition enabled")
      -- call sync_audio_and_video() every sync_audio_and_video_interval
      if sync_audio_and_video_interval > 0 then
         sync_audio_and_video_timer = mp.add_periodic_timer(sync_audio_and_video_interval, sync_audio_and_video)
      end
   else
      restore_normalspeed()
      mp.set_property("demuxer-readahead-secs",readahead_secs)
      mp.unobserve_property(speed_transition)
      mp.unobserve_property(check_position)
      mp.osd_message("speed-transition disabled")
      -- clear the timer
      if sync_audio_and_video_timer then
         sync_audio_and_video_timer:kill()
         sync_audio_and_video_timer = nil
      end
   end
   state = 0
   enable = not enable
end

function reset_on_file_load()
   if state == 1 then
      mp.unobserve_property(check_position)
      restore_normalspeed()
      state = 0
   end
end

mp.add_key_binding("ctrl+j", "toggle_speedtrans", toggle)
mp.add_key_binding("command+j", "toggle_sub_visibility", toggle_sub_visibility)
mp.add_key_binding("ctrl+command+j", "toggle_skipmode", toggle_skipmode)
mp.add_key_binding("ctrl++", "increase_speedup", function() change_speedup(0.1) end, {repeatable=true})
mp.add_key_binding("ctrl+=", "increase_speedup", function() change_speedup(0.1) end, {repeatable=true})
mp.add_key_binding("ctrl+-", "decrease_speedup", function() change_speedup(-0.1) end, {repeatable=true})
mp.add_key_binding("ctrl+0", "increase_leadin", function() change_leadin(0.25) end)
mp.add_key_binding("ctrl+9", "decrease_leadin", function() change_leadin(-0.25) end)
mp.add_key_binding("ctrl+8", "increase_lookahead", function() change_lookAhead(0.25) end)
mp.add_key_binding("ctrl+7", "decrease_lookahead", function() change_lookAhead(-0.25) end)
mp.register_event("file-loaded", reset_on_file_load)
