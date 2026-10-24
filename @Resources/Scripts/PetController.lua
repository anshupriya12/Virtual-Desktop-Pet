--[[
  Virtual Desktop Pet (Version 1) - PetController.lua
  - Lively breathing (the sprite is scaled from its feet)
  - Natural blinking, sometimes a double blink
  - Active idle: random hops and wiggles, rocking while rolling, swaying while waving
  - The pet changes pose every 20 seconds (sit, wave, peek, roll, heart)
  - No interaction for 60 seconds -> the pet naps; it wakes itself up to give reminders
  - Speech bubbles disappear after 5 seconds and never change the pose
  - Sleeping Zzz loop, wake-up animation, click reactions, live settings
]]

-- ===== Timing =====
local TICK = 0.066                 -- seconds since the last update (measured in Update())
local BREATH_PERIOD = 3.2          -- seconds per breath
local POSE_SECONDS = 20            -- change pose this often
local SLEEP_AFTER_SECONDS = 60     -- no interaction for this long -> nap
local BOUNCE_SECONDS = 0.4         -- little pop when the pose changes
local CLICK_SECONDS = 5
local SLEEP_FRAME_SECONDS = 0.18
local WAKE_FRAME_SECONDS = 0.18

-- ===== Frames =====
local sleepLoopFrames = {
  "sleep_1.png", "sleep_2.png", "sleep_3.png",
  "sleep_4.png", "sleep_5.png", "sleep_6.png"
}

local wakeupSequence = {
  "wakeup_1.png", "wakeup_2.png", "wakeup_3.png", "wakeup_3.png",
  "wakeup_4.png", "wakeup_4.png", "wakeup_5.png", "wakeup_5.png"
}

-- Poses the pet juggles between. "blink" = prefix of the blink_<blink>_half/closed frames.
local poses = {
  sit   = { frame = "idle_1.png",    blink = "sit"  },
  wave  = { frame = "water_1.png",   blink = "wave" },
  peek  = { frame = "posture_1.png", blink = "peek" },
  roll  = { frame = "stretch_1.png" },
  heart = { frame = "quote_1.png" }
}
local poseOrder = { "sit", "wave", "peek", "roll", "heart" }

-- Which poses have open eyes (and therefore a blink) for each pet
local blinkable = {
  Penguin = { sit = true, peek = true },
  Doggo   = { sit = true, wave = true, peek = true },
  Catu    = { sit = true, wave = true, peek = true }
}

-- ===== Reminder Content Pools =====
local reminders = {
  water = {
    tag = "HYDRATION CHECK",
    tips = {
      "Hey [Name], hydration time! Drink a nice glass of water.",
      "Water break! Hydrate your body and refresh your brain.",
      "Time for a water break! Take a few refreshing sips.",
      "[Name], have you had water recently? Drink up!",
      "Grab your water bottle and take a big drink, [Name]!"
    }
  },
  posture = {
    tag = "POSTURE & EYES",
    tips = {
      "20-20-20 Rule! Look 20 feet away for 20 seconds, [Name].",
      "Posture check! Un-hunch your shoulders and sit up straight.",
      "Blink your eyes slowly a few times to keep them moist.",
      "Adjust your screen distance and relax your gaze, [Name].",
      "Sit back comfortably and check your spine alignment!",
      "Look out the window for a moment and rest your eyes."
    }
  },
  stretch = {
    tag = "STRETCH BREAK",
    tips = {
      "Time to stretch! Roll your shoulders back 5 times.",
      "Gentle neck stretch: slowly tilt head left, hold, then right.",
      "Shake out your hands and wrists! Release typing tension.",
      "Stand up and walk around for just 60 seconds, [Name]!",
      "Reach your arms up high and stretch your torso, [Name].",
      "Gently roll your head in a slow half-circle to ease neck tension."
    }
  },
  sleep = {
    tag = "REST & RECHARGE",
    tips = {
      "Take a 2-minute mindful breathing pause, [Name].",
      "Close your eyes, take 3 deep slow breaths, and reset.",
      "Pacing is key! Rest your eyes from the screen for a minute.",
      "Remember to get good quality sleep tonight, [Name]!",
      "Inhale deeply through your nose, and exhale slowly."
    }
  },
  quote = {
    tag = "FOR YOU",
    tips = {
      "[Name], you are doing great today! Be proud of yourself.",
      "Small daily progress leads to huge long-term results.",
      "Inhale calm, exhale worry. You've got this, [Name]!",
      "Progress over perfection. Take things one step at a time.",
      "Be kind and gentle to yourself today, [Name].",
      "Believe in yourself, [Name]. You are capable of amazing things!"
    }
  }
}

local petClickMessages = {
  "[Name], you're the best companion! Keep shining!",
  "Hehe, that tickles! Sending you good energy, [Name]!",
  "*Happy wiggles* Thanks for checking in, [Name]!",
  "I'm so glad to sit on your desktop, [Name]!",
  "You've got a wonderful friend in me! Keep smiling!"
}

local themeKeys = {"water", "posture", "stretch", "quote", "sleep"}

-- ===== State =====
local state = "idle"               -- "idle" | "sleep" | "wakeup"
local petType = "Penguin"
local userName = "Friend"
local petScale = 0.55
local sleepMode = 0

local currentPose = "sit"
local overridePose = nil           -- temporary pose (click reaction)
local overrideTimer = 0
local poseTimer = 0
local bounceTimer = 0

local breathPhase = 0
local blinkCountdown = 4
local blinkStage = nil             -- nil | "half" | "closed"
local blinkTime = 0

local doubleBlink = false

local sleepStep = 1
local wakeupStep = 1
local frameAcc = 0

local autoSleep = false            -- true when the pet dozed off by itself (not the moon button)
local pendingAdvice = false        -- show a reminder as soon as the wake-up animation ends
local inactiveTimer = 0

local poseClock = 0                -- drives the rocking / swaying
local activity = nil               -- current hop / wiggle: { kind, t, dur }
local activityCountdown = 4

local bubbleTimer = 0
local secondsElapsed = 0
local adviceInterval = 1800
local adviceDuration = 5
local themeIndex = 0

local lastFrame = ""
local lastClock = os.clock()

-- ===== Helpers =====
local function DisplayPose()
  return overridePose or currentPose
end

local function CanBlink(pose)
  local b = blinkable[petType]
  return b ~= nil and b[pose] == true and poses[pose].blink ~= nil
end

local function ResetBlink()
  blinkStage = nil
  blinkTime = 0
  blinkCountdown = math.random(20, 40) / 10   -- 2.0 - 4.0 seconds
end

-- Random little hop / wiggle so the pet never just sits there
local function StartActivity()
  local kinds = { "hop", "hop2", "wiggle", "wiggle" }
  local kind = kinds[math.random(1, #kinds)]
  local durations = { hop = 0.55, hop2 = 1.1, wiggle = 1.0 }
  activity = { kind = kind, t = 0, dur = durations[kind] }
  activityCountdown = math.random(30, 70) / 10   -- next one in 3 - 7 seconds
end

-- Returns hop height (px at 100% size) and tilt (degrees) for this moment
local function MotionNow()
  local hop, angle = 0, 0

  -- Constant motion that belongs to the pose
  local pose = DisplayPose()
  if pose == "roll" then
    angle = 14 * math.sin(poseClock * 2 * math.pi / 1.4)      -- rolling around
  elseif pose == "heart" then
    angle = 4 * math.sin(poseClock * 2 * math.pi / 2.2)
  elseif pose == "wave" then
    angle = 3 * math.sin(poseClock * 2 * math.pi / 1.2)
  end

  if activity then
    local p = math.min(1.0, activity.t / activity.dur)
    if activity.kind == "hop" then
      hop = 26 * math.sin(math.pi * p)
    elseif activity.kind == "hop2" then
      hop = 22 * math.abs(math.sin(2 * math.pi * p))
    elseif activity.kind == "wiggle" then
      angle = angle + 9 * math.sin(4 * math.pi * p) * (1.0 - 0.4 * p)
    end
  end
  return hop, angle
end

local function CurrentFrameFile()
  if state == "sleep" then
    return sleepLoopFrames[sleepStep]
  elseif state == "wakeup" then
    return wakeupSequence[wakeupStep]
  end
  local pose = DisplayPose()
  if blinkStage and CanBlink(pose) then
    return "blink_" .. poses[pose].blink .. "_" .. blinkStage .. ".png"
  end
  return poses[pose].frame
end

-- Push the current frame + breathing scale to the skin and redraw
local function Render()
  local bx, by = 1.0, 1.0
  local hop, angle = 0, 0
  if state == "idle" then
    local breath = math.sin(breathPhase)
    bx = 1.0 - 0.02 * breath
    by = 1.0 + 0.05 * breath
    if bounceTimer > 0 then
      local p = 1.0 - (bounceTimer / BOUNCE_SECONDS)
      local amp = math.sin(math.pi * p)
      bx = bx - 0.05 * amp
      by = by + 0.10 * amp
    end
    hop, angle = MotionNow()
  end
  SKIN:Bang('!SetVariable "PetAngle" "' .. string.format("%.2f", angle) .. '"')
  SKIN:Bang('!SetVariable "HopY" "' .. string.format("%.1f", hop * petScale) .. '"')

  local frame = CurrentFrameFile()
  if frame ~= lastFrame then
    lastFrame = frame
    SKIN:Bang('!SetVariable "CurrentFrame" "' .. frame .. '"')
  end
  SKIN:Bang('!SetVariable "BreathX" "' .. string.format("%.4f", bx) .. '"')
  SKIN:Bang('!SetVariable "BreathY" "' .. string.format("%.4f", by) .. '"')
  SKIN:Bang('!UpdateMeter "*"')
  SKIN:Bang('!Redraw')
end

-- Returns a safe display name, or nil if the value is empty / an unsubstituted
-- placeholder such as "$UserInput$" (the InputText plugin passes that through
-- literally when it fails to substitute).
local DEFAULT_NAME = "Friend"

local function CleanName(raw)
  if raw == nil then return nil end
  local s = tostring(raw)
  if s:find("%$[%w_]*%$") then return nil end         -- unresolved $Placeholder$
  s = s:gsub('[%c"#%[%]$;]', "")                      -- characters that break bangs / .inc files
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:sub(1, 24)
  if s == "" then return nil end
  return s
end

function FormatText(rawText)
  local name = userName
  if not name or name == "" then name = "Friend" end
  local res = string.gsub(rawText, "%[Name%]", name)
  return res
end

local function ShowBubble(tag, text, seconds)
  bubbleTimer = os.clock() + seconds     -- wall-clock deadline, independent of the update rate
  SKIN:Bang('!SetVariable "AdviceTag" "' .. tag .. '"')
  SKIN:Bang('!SetVariable "AdviceText" "' .. text .. '"')
  SKIN:Bang('!SetVariable "BubbleHidden" "0"')
end

local function HideBubble()
  bubbleTimer = 0
  SKIN:Bang('!SetVariable "BubbleHidden" "1"')
end

local function NextPose()
  local choices = {}
  for _, p in ipairs(poseOrder) do
    if p ~= currentPose then choices[#choices + 1] = p end
  end
  currentPose = choices[math.random(1, #choices)]
  poseTimer = 0
  bounceTimer = BOUNCE_SECONDS
  ResetBlink()
end

function Initialize()
  math.randomseed(os.time())

  local interval = tonumber(SKIN:GetVariable("AdviceIntervalSeconds"))
  if interval and interval > 0 then adviceInterval = interval end

  local duration = tonumber(SKIN:GetVariable("AdviceDurationSeconds"))
  if duration and duration > 0 then adviceDuration = duration end

  local p = SKIN:GetVariable("PetType")
  if p and p ~= "" then petType = p end

  local savedName = SKIN:GetVariable("UserName")
  local name = CleanName(savedName)
  if name then
    userName = name
  else
    -- Missing or corrupt (e.g. a literal "$UserInput$"): fall back and repair the file
    userName = DEFAULT_NAME
    if savedName ~= DEFAULT_NAME then
      SKIN:Bang('!WriteKeyValue Variables UserName "' .. DEFAULT_NAME .. '" "#@#Settings.inc"')
      SKIN:Bang('!SetVariable "UserName" "' .. DEFAULT_NAME .. '"')
    end
  end

  local sc = tonumber(SKIN:GetVariable("PetScale"))
  if sc and sc > 0 then petScale = sc end

  local sm = tonumber(SKIN:GetVariable("SleepMode"))
  if sm and sm == 1 then
    sleepMode = 1
    state = "sleep"
  else
    sleepMode = 0
    state = "idle"
  end

  currentPose = "sit"
  sleepStep = 1
  wakeupStep = 1
  ResetBlink()
  SKIN:Bang('!SetVariable "BubbleHidden" "1"')
  Render()
end

function Update()
  -- Use real elapsed time so every timer is correct even if Rainmeter updates slower than Update=
  local now = os.clock()
  TICK = math.min(0.25, math.max(0.01, now - lastClock))
  lastClock = now

  if state == "idle" then
    if sleepMode == 1 then
      GoToSleep()
      return 0
    end

    -- Breathing
    breathPhase = breathPhase + TICK * 2 * math.pi / BREATH_PERIOD
    if breathPhase > 2 * math.pi then breathPhase = breathPhase - 2 * math.pi end

    -- Pose change every POSE_SECONDS
    poseTimer = poseTimer + TICK
    if poseTimer >= POSE_SECONDS then NextPose() end
    if bounceTimer > 0 then bounceTimer = math.max(0, bounceTimer - TICK) end

    -- Click reaction pose ends
    if overridePose then
      overrideTimer = overrideTimer - TICK
      if overrideTimer <= 0 then
        overridePose = nil
        ResetBlink()
      end
    end

    -- Blinking: open -> half -> closed -> half -> open (sometimes twice in a row)
    if blinkStage == nil then
      blinkCountdown = blinkCountdown - TICK
      if blinkCountdown <= 0 then
        if CanBlink(DisplayPose()) then
          blinkStage = "half"
          blinkTime = 0
        else
          ResetBlink()
        end
      end
    else
      blinkTime = blinkTime + TICK
      if blinkTime < 0.07 then
        blinkStage = "half"
      elseif blinkTime < 0.17 then
        blinkStage = "closed"
      elseif blinkTime < 0.24 then
        blinkStage = "half"
      else
        ResetBlink()
        if not doubleBlink and math.random() < 0.25 then
          doubleBlink = true
          blinkCountdown = 0.15
        else
          doubleBlink = false
        end
      end
    end

    -- Rocking / swaying clock and random hops & wiggles
    poseClock = poseClock + TICK
    if activity then
      activity.t = activity.t + TICK
      if activity.t >= activity.dur then activity = nil end
    else
      activityCountdown = activityCountdown - TICK
      if activityCountdown <= 0 then StartActivity() end
    end

    -- No interaction for a minute -> doze off
    inactiveTimer = inactiveTimer + TICK
    if inactiveTimer >= SLEEP_AFTER_SECONDS then
      GoToSleep(true)
    end

  elseif state == "sleep" then
    -- Sleeping animation loop (Zzz drifting + slow breathing)
    frameAcc = frameAcc + TICK
    if frameAcc >= SLEEP_FRAME_SECONDS then
      frameAcc = frameAcc - SLEEP_FRAME_SECONDS
      sleepStep = sleepStep + 1
      if sleepStep > #sleepLoopFrames then sleepStep = 1 end
    end

  elseif state == "wakeup" then
    frameAcc = frameAcc + TICK
    if frameAcc >= WAKE_FRAME_SECONDS then
      frameAcc = frameAcc - WAKE_FRAME_SECONDS
      wakeupStep = wakeupStep + 1
      if wakeupStep > #wakeupSequence then
        -- Finished waking up: back to the normal sitting pose
        state = "idle"
        currentPose = "sit"
        overridePose = nil
        poseTimer = 0
        breathPhase = 0
        inactiveTimer = 0
        activity = nil
        activityCountdown = 3
        ResetBlink()
        if pendingAdvice then
          pendingAdvice = false
          ShowAdvice()
        end
      end
    end
  end

  -- Reminder timer: runs while awake or napping on its own (a manual nap pauses it).
  -- A napping pet wakes itself up first, then shows the reminder.
  if state == "idle" or (state == "sleep" and autoSleep) then
    secondsElapsed = secondsElapsed + TICK
    if secondsElapsed >= adviceInterval then
      secondsElapsed = 0
      if state == "sleep" then
        pendingAdvice = true
        WakeUp()
      else
        ShowAdvice()
        inactiveTimer = 0
      end
    end
  end

  -- Speech bubble timeout (works in every state)
  if bubbleTimer > 0 and os.clock() >= bubbleTimer then
    HideBubble()
  end

  Render()
  return 0
end

-- Reminder: only the speech bubble appears; the pose is left alone
function ShowAdvice(selectedTheme)
  if not selectedTheme then
    themeIndex = themeIndex + 1
    if themeIndex > #themeKeys then themeIndex = 1 end
    selectedTheme = themeKeys[themeIndex]
  end

  local category = reminders[selectedTheme] or reminders["water"]
  local tips = category.tips
  local formattedTip = FormatText(tips[math.random(1, #tips)])

  ShowBubble(category.tag, formattedTip, adviceDuration)
  Render()
end

-- Force advice now (used by right click context menu & settings test button)
function ForceAdvice()
  secondsElapsed = 0
  inactiveTimer = 0
  if state == "sleep" or state == "wakeup" then
    pendingAdvice = true       -- shown when the wake-up animation ends
    if state == "sleep" then WakeUp() end
  else
    ShowAdvice()
  end
end

-- Called when the mouse hovers over the pet or settings change: resets the nap timer
function Interact()
  inactiveTimer = 0
end

-- User clicked directly on pet
function PetClicked()
  if state == "sleep" or sleepMode == 1 then
    -- Tapping sleeping pet immediately triggers the wake-up animation!
    WakeUp()
    return
  end

  if state == "wakeup" then
    return
  end

  -- Happy heart pose for a few seconds, then back to the current pose
  inactiveTimer = 0
  overridePose = "heart"
  overrideTimer = CLICK_SECONDS
  bounceTimer = BOUNCE_SECONDS
  activity = { kind = "hop2", t = 0, dur = 1.1 }
  ResetBlink()

  local msg = FormatText(petClickMessages[math.random(1, #petClickMessages)])
  ShowBubble("HAPPY FRIEND", msg, CLICK_SECONDS)
  Render()
end

-- Wake up the pet with the wake-up animation sequence
function WakeUp()
  if state == "wakeup" then return end
  sleepMode = 0
  autoSleep = false
  inactiveTimer = 0
  HideBubble()
  overridePose = nil
  state = "wakeup"
  wakeupStep = 1
  frameAcc = 0
  SKIN:Bang('!WriteKeyValue Variables SleepMode "0" "#@#Settings.inc"')
  SKIN:Bang('!SetVariable "SleepMode" "0"')
  PushToSettings("SleepMode", 0)
  Render()
end

-- Put the pet to sleep
-- auto = true when the pet dozed off from inactivity (not saved, reminders still wake it)
function GoToSleep(auto)
  sleepMode = 1
  autoSleep = (auto == true)
  state = "sleep"
  sleepStep = 1
  frameAcc = 0
  overridePose = nil
  blinkStage = nil
  activity = nil
  HideBubble()
  if not autoSleep then
    SKIN:Bang('!WriteKeyValue Variables SleepMode "1" "#@#Settings.inc"')
  end
  SKIN:Bang('!SetVariable "SleepMode" "1"')
  PushToSettings("SleepMode", 1)
  Render()
end

-- Toggle sleep / wake
function ToggleSleep()
  if state == "sleep" or sleepMode == 1 then
    WakeUp()
  else
    GoToSleep()
  end
end

-- Switch Pet
function SwitchPet(newPet)
  if newPet == "Penguin" or newPet == "Doggo" or newPet == "Catu" then
    petType = newPet
    inactiveTimer = 0
    SKIN:Bang('!WriteKeyValue Variables PetType "' .. newPet .. '" "#@#Settings.inc"')
    SKIN:Bang('!SetVariable "PetType" "' .. newPet .. '"')
    PushToSettings("PetType", newPet)
    ResetBlink()
    Render()
  end
end

-- Keep the Settings skin (if open) in sync without refreshing anything
function PushToSettings(name, value)
  local cfg = SKIN:GetVariable("CURRENTCONFIG") .. "\\Settings"
  SKIN:Bang('!SetVariable', name, tostring(value), cfg)
  SKIN:Bang('!UpdateMeasure', '*', cfg)
  SKIN:Bang('!UpdateMeter', '*', cfg)
  SKIN:Bang('!Redraw', cfg)
end

-- Called by the Settings skin's name box with the typed text.
-- Valid text replaces the saved name; empty text resets to the default;
-- an unresolved "$UserInput$" placeholder is ignored (previous name kept).
function SetUserName(raw)
  inactiveTimer = 0
  raw = tostring(raw or "")
  local name = CleanName(raw)
  if not name then
    if raw:find("%$[%w_]*%$") then return end          -- substitution failed: keep old name
    name = DEFAULT_NAME                                -- user cleared the field
  end
  userName = name
  SKIN:Bang('!SetVariable "UserName" "' .. name .. '"')
  SKIN:Bang('!WriteKeyValue Variables UserName "' .. name .. '" "#@#Settings.inc"')
  PushToSettings("UserName", name)
end

-- Called by the Settings skin after it changed name / pet / size / interval.
-- Applies everything live (no skin refresh, so timers and animation continue).
function ApplySettings()
  inactiveTimer = 0
  -- A name that is empty or an unresolved placeholder never overwrites the saved one
  local name = CleanName(SKIN:GetVariable("UserName"))
  if name then userName = name end

  local p = SKIN:GetVariable("PetType")
  if p == "Penguin" or p == "Doggo" or p == "Catu" then
    if p ~= petType then ResetBlink() end
    petType = p
  end

  local sc = tonumber(SKIN:GetVariable("PetScale"))
  if sc and sc > 0 then petScale = sc end

  local interval = tonumber(SKIN:GetVariable("AdviceIntervalSeconds"))
  if interval and interval > 0 then adviceInterval = interval end

  local vars = {
    UserName = userName,
    PetType = petType,
    PetScale = string.format("%.2f", petScale),
    AdviceIntervalSeconds = tostring(adviceInterval)
  }
  for k, v in pairs(vars) do
    SKIN:Bang('!SetVariable "' .. k .. '" "' .. v .. '"')
    SKIN:Bang('!WriteKeyValue Variables ' .. k .. ' "' .. v .. '" "#@#Settings.inc"')
  end

  Render()
end

-- Set pet size (clamped 0.35 - 1.0), save it and sync the settings panel
function SetScale(sc)
  inactiveTimer = 0
  sc = math.max(0.35, math.min(1.0, math.floor(sc * 100 + 0.5) / 100))
  petScale = sc
  local scStr = string.format("%.2f", sc)
  SKIN:Bang('!WriteKeyValue Variables PetScale "' .. scStr .. '" "#@#Settings.inc"')
  SKIN:Bang('!SetVariable "PetScale" "' .. scStr .. '"')
  PushToSettings("PetScale", scStr)
  Render()
end

-- Mouse Scroll Scale Up (Max 1.0)
function ScaleUp()
  SetScale((tonumber(SKIN:GetVariable("PetScale")) or 0.55) + 0.05)
end

-- Mouse Scroll Scale Down (Min 0.35)
function ScaleDown()
  SetScale((tonumber(SKIN:GetVariable("PetScale")) or 0.55) - 0.05)
end
