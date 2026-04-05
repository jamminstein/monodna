-- MONODNA
-- one note. infinite variation. four tracks.
--
-- K1 tap: cycle pages (DNA/RHYTHM/REPEAT/TRACK)
-- K1+K3: toggle step-lock mode
-- K1+K2: clear step lock (in step-lock mode)
--
-- PAGE 1 (DNA):
--   ENC1: root note  ENC2: tempo  ENC3: chaos
--   K2: randomize  K3: freeze
--
-- PAGE 2 (RHYTHM):
--   ENC1: steps  ENC2: pulses  ENC3: rotate
--   K2: toggle euclidean  K3: freeze
--
-- PAGE 3 (REPEAT):
--   ENC1: count  ENC2: time subdiv  ENC3: pace
--   K2: reset repeater  K3: freeze
--
-- PAGE 4 (TRACK):
--   ENC1: select track  ENC2: MIDI ch  ENC3: scale
--   K2: mute/unmute  K3: freeze

engine.name = "PolyPerc"

local midi_out, opxy_out = nil, nil

local function opxy_note_on(note, vel)
  if opxy_out then opxy_out:note_on(note, vel, params:get("opxy_channel")) end
end
local function opxy_note_off(note)
  if opxy_out then opxy_out:note_off(note, 0, params:get("opxy_channel")) end
end

local running = true

-- -------------------------------------------------------
-- scales
-- -------------------------------------------------------

local scale_names = {"chromatic", "pentatonic", "dorian", "mixolydian", "blues"}
local scales = {
  chromatic   = {0,1,2,3,4,5,6,7,8,9,10,11},
  pentatonic  = {0,2,4,7,9},
  dorian      = {0,2,3,5,7,9,10},
  mixolydian  = {0,2,4,5,7,9,10},
  blues       = {0,3,5,6,7,10},
}

-- -------------------------------------------------------
-- subdivisions for note repeater
-- -------------------------------------------------------

local subdivisions = {1, 0.5, 0.25, 0.125, 0.0625}
local subdiv_names = {"1/4", "1/8", "1/16", "1/32", "1/64"}

-- -------------------------------------------------------
-- page navigation
-- -------------------------------------------------------

local current_page = 1
local page_names = {"DNA", "RHYTHM", "REPEAT", "TRACK"}
local k1_held = false
local k1_other_pressed = false

-- -------------------------------------------------------
-- step lock editing
-- -------------------------------------------------------

local step_lock_mode = false
local step_lock_cursor = 1

-- -------------------------------------------------------
-- multi-track system
-- -------------------------------------------------------

local history_max = 8

local function new_track(id)
  return {
    id = id,
    dna = {
      root = 48, rate = 120, intensity = 0.5, steps = 8,
      seed = math.random(1, 99999),
      euclid_enabled = false, euclid_pulses = 4, euclid_rotate = 0,
      rep_count = 1, rep_time = 3, rep_pace = 0, rep_offset = 0,
    },
    scale_lock = 1,
    midi_channel = id,
    steps = {},
    step_idx = 0,
    mutation_locks = {
      oct_offset = false, drift = false, amp = false,
      cutoff_mult = false, release = false, dur_mult = false,
    },
    step_locks = {},
    frozen = false,
    muted = false,
    history = {},
    history_idx = 1,
    beat_clock = nil,
  }
end

local tracks = {}
local current_track = 1
for i = 1, 4 do tracks[i] = new_track(i) end

-- -------------------------------------------------------
-- utils
-- -------------------------------------------------------

local function mtof(midi_note)
  return 440 * 2 ^ ((midi_note - 69) / 12)
end

local function lerp(a, b, t)
  return a + (b - a) * t
end

local function rnd(lo, hi)
  return lo + math.random() * (hi - lo)
end

local function rnd_int(lo, hi)
  return math.floor(rnd(lo, hi + 0.9999))
end

local function quantize_to_scale(value, scale_tbl)
  if not scale_tbl or #scale_tbl == 0 then return value end
  local idx = 1
  local min_dist = math.abs(value - scale_tbl[1])
  for i = 2, #scale_tbl do
    local dist = math.abs(value - scale_tbl[i])
    if dist < min_dist then
      min_dist = dist
      idx = i
    end
  end
  return scale_tbl[idx]
end

local note_names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local function midi_to_name(m)
  local n = (m % 12) + 1
  local o = math.floor(m / 12) - 1
  return note_names[n] .. o
end

-- -------------------------------------------------------
-- euclidean pattern (Bjorklund)
-- -------------------------------------------------------

local function euclid_pattern(num_steps, pulses, rotate)
  if pulses >= num_steps then
    local pattern = {}
    for i = 1, num_steps do pattern[i] = true end
    return pattern
  end
  if pulses <= 0 then
    local pattern = {}
    for i = 1, num_steps do pattern[i] = false end
    return pattern
  end
  local pattern = {}
  for i = 1, num_steps do
    pattern[i] = (((i - 1) * pulses) % num_steps) < pulses
  end
  if rotate > 0 then
    local rotated = {}
    for i = 1, num_steps do
      rotated[i] = pattern[((i - 1 + rotate) % num_steps) + 1]
    end
    pattern = rotated
  end
  return pattern
end

-- -------------------------------------------------------
-- build steps from DNA (per track)
-- -------------------------------------------------------

local function build_steps(track)
  math.randomseed(track.dna.seed)
  local n = track.dna.steps
  local chaos = track.dna.intensity
  local scale_tbl = scales[scale_names[track.scale_lock]]

  -- save current state to history
  local prev_steps = {}
  for i = 1, #track.steps do
    prev_steps[i] = {}
    for k, v in pairs(track.steps[i]) do prev_steps[i][k] = v end
  end
  track.history[track.history_idx] = prev_steps
  track.history_idx = (track.history_idx % history_max) + 1

  -- euclidean pattern
  local euc_pat = nil
  if track.dna.euclid_enabled then
    euc_pat = euclid_pattern(n, track.dna.euclid_pulses, track.dna.euclid_rotate)
  end

  track.steps = {}
  for i = 1, n do
    local oct_range   = math.floor(lerp(0, 3, chaos))
    local oct_offset  = track.mutation_locks.oct_offset and (track.steps[i] and track.steps[i].oct_offset or 0)
                        or rnd_int(-oct_range, oct_range) * 12
    local drift       = track.mutation_locks.drift and (track.steps[i] and track.steps[i].drift or 0)
                        or rnd(-chaos * 0.4, chaos * 0.4)
    local amp         = track.mutation_locks.amp and (track.steps[i] and track.steps[i].amp or 0.8)
                        or rnd(lerp(0.8, 0.2, chaos), 1.0)
    local cutoff_mult = track.mutation_locks.cutoff_mult and (track.steps[i] and track.steps[i].cutoff_mult or 1.0)
                        or rnd(1.0, lerp(2.0, 10.0, chaos))
    local release     = track.mutation_locks.release and (track.steps[i] and track.steps[i].release or 0.3)
                        or rnd(0.05, lerp(0.3, 1.5, chaos))
    local dur_choices = {0.5, 1, 1, 1, 1, 1.5, 2}
    local dur_mult    = track.mutation_locks.dur_mult and (track.steps[i] and track.steps[i].dur_mult or 1)
                        or dur_choices[rnd_int(1, #dur_choices)]
    if chaos < 0.3 then dur_mult = 1 end

    local is_rest
    if euc_pat then
      is_rest = not euc_pat[i]
    else
      is_rest = math.random() < (chaos * 0.25)
    end

    -- quantize drift to scale if not chromatic
    if track.scale_lock > 1 then
      local drift_semitones = math.floor(drift)
      drift = quantize_to_scale(drift_semitones, scale_tbl) - (drift_semitones % 12)
    end

    track.steps[i] = {
      oct_offset  = oct_offset,
      drift       = drift,
      amp         = amp,
      cutoff_mult = cutoff_mult,
      release     = release,
      is_rest     = is_rest,
      dur_mult    = dur_mult,
    }

    -- apply step locks
    if track.step_locks[i] then
      for k, v in pairs(track.step_locks[i]) do
        track.steps[i][k] = v
      end
    end
  end
end

-- -------------------------------------------------------
-- play step (per track)
-- -------------------------------------------------------

local function play_step(track, s)
  if s.is_rest then return end

  local midi_note = math.max(24, math.min(108, track.dna.root + s.oct_offset))
  local freq      = mtof(midi_note) * (2 ^ (s.drift / 12))
  local cutoff    = math.min(freq * s.cutoff_mult, 8000)
  local vel       = math.floor(s.amp * 0.8 * 127)

  -- track 1: internal engine + MIDI
  if track.id == 1 then
    engine.release(s.release)
    engine.cutoff(cutoff)
    engine.amp(s.amp * 0.8)
    engine.hz(freq)
  end

  -- MIDI output
  if midi_out then
    midi_out:note_on(midi_note, vel, track.midi_channel)
  end
  if track.id == 1 then
    opxy_note_on(midi_note, vel)
  end

  clock.run(function()
    clock.sleep(s.release)
    if midi_out then
      midi_out:note_off(midi_note, 0, track.midi_channel)
    end
    if track.id == 1 then
      opxy_note_off(midi_note)
    end
  end)
end

-- -------------------------------------------------------
-- note repeater
-- -------------------------------------------------------

local function play_step_with_repeats(track, s)
  play_step(track, s)
  local count = track.dna.rep_count
  if count <= 1 then return end

  clock.run(function()
    local base_interval = subdivisions[track.dna.rep_time] * (60 / track.dna.rate)
    local pace = track.dna.rep_pace
    local offset = track.dna.rep_offset

    for r = 2, count do
      local interval = base_interval * (1 + pace * (r - 1) / (count - 1))
      clock.sleep(math.max(0.01, interval))

      if not running then return end
      -- create modified step with offset velocity
      local amp_scale = 1 + offset * (r - 1) / (count - 1)
      local mod_s = {}
      for k, v in pairs(s) do mod_s[k] = v end
      mod_s.amp = util.clamp(s.amp * amp_scale, 0.1, 1.0)
      play_step(track, mod_s)
    end
  end)
end

-- -------------------------------------------------------
-- clock
-- -------------------------------------------------------

local function step_dur(track)
  return 60 / track.dna.rate / 4
end

local function run_track_arp(track)
  while running do
    track.step_idx = (track.step_idx % track.dna.steps) + 1
    local s = track.steps[track.step_idx]
    if not track.frozen and not track.muted and s then
      play_step_with_repeats(track, s)
    end
    clock.sleep(step_dur(track) * (s and s.dur_mult or 1))
    if track.id == current_track then redraw() end
  end
end

-- -------------------------------------------------------
-- DNA mutation
-- -------------------------------------------------------

local function randomize_dna(track)
  track.dna.seed  = math.random(1, 99999)
  track.dna.steps = rnd_int(4, 16)
  build_steps(track)
end

-- -------------------------------------------------------
-- norns keys & encoders
-- -------------------------------------------------------

function key(n, z)
  local tr = tracks[current_track]

  if n == 1 then
    if z == 1 then
      k1_held = true
      k1_other_pressed = false
    else
      -- release
      if not k1_other_pressed then
        current_page = (current_page % 4) + 1
      end
      k1_held = false
    end
    redraw()
    return
  end

  if z == 1 then
    if k1_held then
      k1_other_pressed = true
      if n == 3 then
        step_lock_mode = not step_lock_mode
        if step_lock_mode then step_lock_cursor = 1 end
      elseif n == 2 then
        if step_lock_mode then
          tr.step_locks[step_lock_cursor] = nil
          build_steps(tr)
        end
      end
      redraw()
      return
    end

    -- page-dependent K2/K3
    if current_page == 1 then
      if n == 2 then randomize_dna(tr); redraw()
      elseif n == 3 then tr.frozen = not tr.frozen; redraw() end

    elseif current_page == 2 then
      if n == 2 then
        tr.dna.euclid_enabled = not tr.dna.euclid_enabled
        build_steps(tr); redraw()
      elseif n == 3 then tr.frozen = not tr.frozen; redraw() end

    elseif current_page == 3 then
      if n == 2 then
        tr.dna.rep_count = 1; tr.dna.rep_time = 3
        tr.dna.rep_pace = 0; tr.dna.rep_offset = 0
        redraw()
      elseif n == 3 then tr.frozen = not tr.frozen; redraw() end

    elseif current_page == 4 then
      if n == 2 then tr.muted = not tr.muted; redraw()
      elseif n == 3 then tr.frozen = not tr.frozen; redraw() end
    end
  end
end

function enc(n, d)
  local tr = tracks[current_track]

  -- step lock mode overrides
  if step_lock_mode and current_page ~= 4 then
    if n == 1 then
      step_lock_cursor = util.clamp(step_lock_cursor + d, 1, tr.dna.steps)
      redraw(); return
    end
    -- lock values on current step
    local locks = tr.step_locks[step_lock_cursor] or {}
    if current_page == 1 then
      if n == 2 then
        locks.oct_offset = util.clamp((locks.oct_offset or 0) + d * 12, -36, 36)
      elseif n == 3 then
        locks.amp = util.clamp((locks.amp or 0.8) + d * 0.05, 0.1, 1.0)
      end
    elseif current_page == 2 then
      if n == 2 then
        locks.dur_mult = util.clamp((locks.dur_mult or 1) + d * 0.5, 0.5, 4)
      elseif n == 3 then
        locks.is_rest = d > 0
      end
    elseif current_page == 3 then
      if n == 2 then
        locks.cutoff_mult = util.clamp((locks.cutoff_mult or 1) + d * 0.5, 0.5, 10)
      elseif n == 3 then
        locks.release = util.clamp((locks.release or 0.3) + d * 0.05, 0.05, 2.0)
      end
    end
    tr.step_locks[step_lock_cursor] = locks
    build_steps(tr)
    redraw(); return
  end

  if current_page == 1 then
    if n == 1 then
      tr.dna.root = util.clamp(tr.dna.root + d, 24, 96)
    elseif n == 2 then
      tr.dna.rate = util.clamp(tr.dna.rate + d, 40, 300)
      if tr.id == 1 then params:set("clock_tempo", tr.dna.rate) end
    elseif n == 3 then
      tr.dna.intensity = util.clamp(tr.dna.intensity + d * 0.02, 0, 1)
      build_steps(tr)
    end

  elseif current_page == 2 then
    if n == 1 then
      tr.dna.steps = util.clamp(tr.dna.steps + d, 4, 32)
      tr.dna.euclid_pulses = util.clamp(tr.dna.euclid_pulses, 1, tr.dna.steps)
      tr.dna.euclid_rotate = util.clamp(tr.dna.euclid_rotate, 0, tr.dna.steps - 1)
      build_steps(tr)
    elseif n == 2 then
      tr.dna.euclid_pulses = util.clamp(tr.dna.euclid_pulses + d, 1, tr.dna.steps)
      if tr.dna.euclid_enabled then build_steps(tr) end
    elseif n == 3 then
      tr.dna.euclid_rotate = util.clamp(tr.dna.euclid_rotate + d, 0, tr.dna.steps - 1)
      if tr.dna.euclid_enabled then build_steps(tr) end
    end

  elseif current_page == 3 then
    if n == 1 then
      tr.dna.rep_count = util.clamp(tr.dna.rep_count + d, 1, 8)
    elseif n == 2 then
      tr.dna.rep_time = util.clamp(tr.dna.rep_time + d, 1, 5)
    elseif n == 3 then
      tr.dna.rep_pace = util.clamp(tr.dna.rep_pace + d * 0.05, -1.0, 1.0)
    end

  elseif current_page == 4 then
    if n == 1 then
      current_track = util.clamp(current_track + d, 1, 4)
    elseif n == 2 then
      tracks[current_track].midi_channel = util.clamp(tracks[current_track].midi_channel + d, 1, 16)
    elseif n == 3 then
      tracks[current_track].scale_lock = util.clamp(tracks[current_track].scale_lock + d, 1, 5)
      if tracks[current_track].scale_lock < 1 then tracks[current_track].scale_lock = 5
      elseif tracks[current_track].scale_lock > 5 then tracks[current_track].scale_lock = 1 end
      build_steps(tracks[current_track])
    end
  end
  redraw()
end

-- -------------------------------------------------------
-- display helpers
-- -------------------------------------------------------

local function draw_header()
  local tr = tracks[current_track]
  screen.level(tr.frozen and 5 or 15)
  screen.font_face(1)
  screen.font_size(8)
  screen.move(2, 9)
  screen.text(page_names[current_page])

  -- track indicator
  screen.level(10)
  screen.move(90, 9)
  screen.text("TR" .. current_track)

  if tr.frozen then
    screen.level(8)
    screen.move(126, 9)
    screen.text_right("FRZ")
  end

  if tr.muted then
    screen.level(4)
    screen.move(110, 9)
    screen.text("M")
  end

  if step_lock_mode then
    screen.level(15)
    screen.move(60, 9)
    screen.text("LOCK")
  end
end

local function draw_step_bar()
  local tr = tracks[current_track]
  local total_w = 124
  local sw = math.floor(total_w / tr.dna.steps) - 1
  sw = math.max(2, sw)
  for i = 1, tr.dna.steps do
    local s = tr.steps[i]
    local x = 2 + (i - 1) * (sw + 1)
    if s then
      local base_h = 8
      local h = math.max(2, base_h + math.floor(s.oct_offset / 12) * 2)
      local y = 58 - h

      if step_lock_mode and i == step_lock_cursor then
        screen.level(15)
        screen.rect(x, y - 1, sw, h + 2)
        screen.stroke()
        if not s.is_rest then
          screen.level(10)
          screen.rect(x, y, sw, h)
          screen.fill()
        end
      elseif i == tr.step_idx then
        screen.level(15)
        screen.rect(x, y, sw, h)
        screen.fill()
      elseif s.is_rest then
        screen.level(2)
        screen.rect(x, 56, sw, 2)
        screen.stroke()
      else
        local lv = math.max(3, math.floor(s.amp * 12))
        screen.level(lv)
        screen.rect(x, y, sw, h)
        screen.fill()
      end

      -- step lock indicator
      if tr.step_locks[i] then
        screen.level(12)
        screen.pixel(x + math.floor(sw / 2), 60)
        screen.fill()
      end
    end
  end
end

-- -------------------------------------------------------
-- page draw functions
-- -------------------------------------------------------

local function draw_page_dna()
  local tr = tracks[current_track]

  -- big root note
  screen.level(15)
  screen.font_face(25)
  screen.font_size(20)
  screen.move(2, 40)
  screen.text(midi_to_name(tr.dna.root))
  screen.font_face(1)

  -- scale indicator
  screen.level(4)
  screen.font_size(8)
  screen.move(126, 20)
  screen.text_right(scale_names[tr.scale_lock])

  -- BPM
  screen.level(10)
  screen.move(68, 42)
  screen.text(string.format("%d bpm", tr.dna.rate))

  -- chaos bar
  screen.level(3)
  screen.move(68, 26)
  screen.text("chaos")
  screen.level(2)
  screen.rect(68, 29, 56, 5)
  screen.stroke()
  local bar_w = math.floor(tr.dna.intensity * 56)
  if bar_w > 0 then
    screen.level(math.floor(5 + tr.dna.intensity * 10))
    screen.rect(68, 29, bar_w, 5)
    screen.fill()
  end

  -- bottom info
  screen.level(3)
  screen.font_size(8)
  screen.move(2, 64)
  screen.text(string.format("%d steps  seed:%05d", tr.dna.steps, tr.dna.seed))
end

local function draw_page_rhythm()
  local tr = tracks[current_track]
  local n = tr.dna.steps
  local cx, cy, r = 40, 34, 14

  -- circular ring
  local euc_pat = nil
  if tr.dna.euclid_enabled then
    euc_pat = euclid_pattern(n, tr.dna.euclid_pulses, tr.dna.euclid_rotate)
  end

  for i = 1, n do
    local angle = (i - 1) * (2 * math.pi / n) - math.pi / 2
    local px = cx + math.cos(angle) * r
    local py = cy + math.sin(angle) * r

    if i == tr.step_idx then
      screen.level(15)
      screen.rect(math.floor(px) - 2, math.floor(py) - 2, 5, 5)
      screen.fill()
    elseif euc_pat and euc_pat[i] then
      screen.level(10)
      screen.rect(math.floor(px) - 1, math.floor(py) - 1, 3, 3)
      screen.fill()
    else
      screen.level(3)
      screen.rect(math.floor(px), math.floor(py), 2, 2)
      screen.fill()
    end
  end

  -- status
  screen.font_face(1)
  screen.font_size(8)
  screen.level(tr.dna.euclid_enabled and 15 or 4)
  screen.move(70, 22)
  screen.text(tr.dna.euclid_enabled and "EUCLID" or "off")

  -- numeric readout
  screen.level(10)
  screen.move(70, 34)
  screen.text(string.format("S:%d P:%d R:%d", n, tr.dna.euclid_pulses, tr.dna.euclid_rotate))

  -- bottom info
  screen.level(3)
  screen.move(2, 64)
  screen.text(string.format("%d steps  seed:%05d", tr.dna.steps, tr.dna.seed))
end

local function draw_page_repeat()
  local tr = tracks[current_track]
  local count = tr.dna.rep_count
  local pace = tr.dna.rep_pace
  local offset = tr.dna.rep_offset

  -- horizontal bars showing repeats
  local start_x = 10
  local total_w = 108
  local base_interval = total_w / math.max(count, 1)

  for r = 1, count do
    local x_pos
    if count == 1 then
      x_pos = start_x
    else
      local interval = base_interval * (1 + pace * (r - 1) / (count - 1))
      x_pos = start_x
      if r > 1 then
        local accum = 0
        for j = 1, r - 1 do
          accum = accum + base_interval * (1 + pace * (j - 1) / (count - 1))
        end
        x_pos = start_x + accum
      end
    end

    -- bar height = velocity
    local amp_scale = 1
    if count > 1 then
      amp_scale = util.clamp(1 + offset * (r - 1) / (count - 1), 0.1, 1.0)
    end
    local bar_h = math.floor(amp_scale * 20)
    local bar_y = 46 - bar_h

    screen.level(r == 1 and 15 or 8)
    screen.rect(math.floor(x_pos), bar_y, 4, bar_h)
    screen.fill()
  end

  -- numeric readout
  screen.font_face(1)
  screen.font_size(8)
  screen.level(10)
  screen.move(2, 22)
  screen.text(string.format("x%d  %s  pace:%.1f", count, subdiv_names[tr.dna.rep_time], pace))

  screen.level(4)
  screen.move(2, 32)
  screen.text(string.format("offset:%.1f", offset))

  -- bottom info
  screen.level(3)
  screen.move(2, 64)
  screen.text(string.format("%d steps  seed:%05d", tr.dna.steps, tr.dna.seed))
end

local function draw_page_track()
  -- 4 track rows
  for i = 1, 4 do
    local t = tracks[i]
    local y = 14 + (i - 1) * 12
    local is_sel = (i == current_track)

    screen.level(is_sel and 15 or 4)
    screen.font_face(1)
    screen.font_size(8)
    screen.move(2, y)
    local mute_str = t.muted and "M" or " "
    local frz_str = t.frozen and "F" or " "
    screen.text(string.format("TR%d %s%s %2dstep %s", i, mute_str, frz_str, t.dna.steps, midi_to_name(t.dna.root)))

    if is_sel then
      screen.level(8)
      screen.move(126, y)
      screen.text_right(string.format("ch%d %s", t.midi_channel, scale_names[t.scale_lock]))
    end
  end

  -- bottom info
  local tr = tracks[current_track]
  screen.level(3)
  screen.move(2, 64)
  screen.text(string.format("TR%d  %d bpm  seed:%05d", current_track, tr.dna.rate, tr.dna.seed))
end

-- -------------------------------------------------------
-- redraw
-- -------------------------------------------------------

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)

  draw_header()

  if current_page == 1 then
    draw_page_dna()
  elseif current_page == 2 then
    draw_page_rhythm()
  elseif current_page == 3 then
    draw_page_repeat()
  elseif current_page == 4 then
    draw_page_track()
  end

  draw_step_bar()
  screen.update()
end

-- -------------------------------------------------------
-- MIDI CC event handling
-- -------------------------------------------------------

function midi.event(data)
  local msg = midi.to_msg(data)
  if msg.type == "cc" then
    if msg.cc == 14 then
      tracks[current_track].dna.intensity = util.clamp(msg.val / 127, 0, 1)
      build_steps(tracks[current_track])
    end
  end
end

-- -------------------------------------------------------
-- init
-- -------------------------------------------------------

function init()
  math.randomseed(os.time())

  -- PolyPerc defaults
  engine.amp(0.8)
  engine.cutoff(2000)
  engine.release(0.3)
  engine.pw(0.5)
  engine.pan(0)
  engine.gain(2.0)

  params:add_separator("MONODNA")
  params:add_number("root", "Root Note", 24, 96, 48)
  params:set_action("root", function(v) tracks[current_track].dna.root = v end)
  params:add_number("rate", "Rate (BPM)", 40, 300, 120)
  params:set_action("rate", function(v)
    tracks[current_track].dna.rate = v
    params:set("clock_tempo", v)
  end)
  params:add_control("intensity", "Intensity",
    controlspec.new(0, 1, "lin", 0.01, 0.5, ""))
  params:set_action("intensity", function(v)
    tracks[current_track].dna.intensity = v
    build_steps(tracks[current_track])
  end)

  params:add_separator("MUTATIONS")
  params:add_option("scale_lock", "Scale Lock", scale_names, 1)
  params:set_action("scale_lock", function(v)
    tracks[current_track].scale_lock = v
    build_steps(tracks[current_track])
  end)

  params:add_separator("MIDI Out")
  params:add{type="number", id="midi_device", name="MIDI Device", min=1, max=16, default=1,
    action=function(v) midi_out = midi.connect(v) end}
  params:add{type="number", id="midi_channel", name="MIDI Channel", min=1, max=16, default=1}

  params:add_separator("OP-XY MIDI")
  params:add{type="number", id="opxy_device", name="OP-XY Device", min=1, max=16, default=2,
    action=function(v) opxy_out = midi.connect(v) end}
  params:add{type="number", id="opxy_channel", name="OP-XY Channel", min=1, max=16, default=1}

  midi_out = midi.connect(params:get("midi_device"))
  opxy_out = midi.connect(params:get("opxy_device"))

  -- build steps and start clocks for all tracks
  for i = 1, 4 do
    build_steps(tracks[i])
    tracks[i].beat_clock = clock.run(function() run_track_arp(tracks[i]) end)
  end

  params:set("clock_tempo", tracks[1].dna.rate)
  redraw()
  print("MONODNA: running (4 tracks)")
end

function cleanup()
  running = false
  for i = 1, 4 do
    if tracks[i].beat_clock then clock.cancel(tracks[i].beat_clock) end
  end
  if midi_out then for ch = 1, 16 do midi_out:cc(123, 0, ch) end end
  if opxy_out then for ch = 1, 16 do opxy_out:cc(123, 0, ch) end end
end
