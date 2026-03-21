-- MONODNA
-- one note. infinite variation.
--
-- ENC1: root note
-- ENC2: tempo / rate
-- ENC3: variation intensity
-- KEY2: randomize DNA
-- KEY3: freeze / unfreeze
--
-- all arpeggios are the same note,
-- just mutated across octave, time,
-- pitch drift, filter, and amplitude.

engine.name = "PolyPerc"

local midi_out, opxy_out = nil, nil

local function opxy_note_on(note, vel) if opxy_out then opxy_out:note_on(note, vel, params:get("opxy_channel")) end end
local function opxy_note_off(note) if opxy_out then opxy_out:note_off(note, 0, params:get("opxy_channel")) end end

local frozen = false
local beat_clock = nil
local running = true

local dna = {
  root      = 48,
  rate      = 120,
  intensity = 0.5,
  steps     = 8,
  seed      = 1337,
}

-- Scale quantization
local scale_lock = 1           -- 1=chromatic, 2=pentatonic, 3=dorian, 4=mixolydian, 5=blues
local scale_names = {"chromatic", "pentatonic", "dorian", "mixolydian", "blues"}
local scales = {
  chromatic    = {0,1,2,3,4,5,6,7,8,9,10,11},
  pentatonic   = {0,2,4,7,9},
  dorian       = {0,2,3,5,7,9,10},
  mixolydian   = {0,2,4,5,7,9,10},
  blues        = {0,3,5,6,7,10},
}

-- Mutation history & undo
local history = {}
local history_max = 8
local history_idx = 1

-- Mutation locks per parameter
local mutation_locks = {
  oct_offset = false,
  drift = false,
  amp = false,
  cutoff_mult = false,
  release = false,
  dur_mult = false,
}

local steps = {}
local step_idx = 0

-- -------------------------------------------------------
-- utils
-- -------------------------------------------------------

local function mtof(midi)
  return 440 * 2^((midi - 69) / 12)
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

-- -------------------------------------------------------
-- build steps from DNA
-- -------------------------------------------------------

local function build_steps()
  math.randomseed(dna.seed)
  local n = dna.steps
  local chaos = dna.intensity
  local scale_tbl = scales[scale_names[scale_lock]]

  -- Save current state to history before mutation
  local prev_steps = {}
  for i = 1, #steps do
    prev_steps[i] = {}
    for k, v in pairs(steps[i]) do prev_steps[i][k] = v end
  end
  history[history_idx] = prev_steps
  history_idx = (history_idx % history_max) + 1

  steps = {}
  for i = 1, n do
    local oct_range   = math.floor(lerp(0, 3, chaos))
    local oct_offset  = mutation_locks.oct_offset and (steps[i] and steps[i].oct_offset or 0) or rnd_int(-oct_range, oct_range) * 12
    local drift       = mutation_locks.drift and (steps[i] and steps[i].drift or 0) or rnd(-chaos * 0.4, chaos * 0.4)
    local amp         = mutation_locks.amp and (steps[i] and steps[i].amp or 0.8) or rnd(lerp(0.8, 0.2, chaos), 1.0)
    local cutoff_mult = mutation_locks.cutoff_mult and (steps[i] and steps[i].cutoff_mult or 1.0) or rnd(1.0, lerp(2.0, 10.0, chaos))
    local release     = mutation_locks.release and (steps[i] and steps[i].release or 0.3) or rnd(0.05, lerp(0.3, 1.5, chaos))
    local is_rest     = math.random() < (chaos * 0.25)
    local dur_choices = {0.5, 1, 1, 1, 1, 1.5, 2}
    local dur_mult    = mutation_locks.dur_mult and (steps[i] and steps[i].dur_mult or 1) or dur_choices[rnd_int(1, #dur_choices)]
    if chaos < 0.3 then dur_mult = 1 end

    -- Quantize drift to scale if not chromatic
    if scale_lock > 1 then
      local drift_semitones = math.floor(drift)
      drift = quantize_to_scale(drift_semitones, scale_tbl) - (drift_semitones % 12)
    end

    steps[i] = {
      oct_offset   = oct_offset,
      drift        = drift,
      amp          = amp,
      cutoff_mult  = cutoff_mult,
      release      = release,
      is_rest      = is_rest,
      dur_mult     = dur_mult,
    }
  end
end

-- -------------------------------------------------------
-- play step
-- -------------------------------------------------------

local function play_step(s)
  if s.is_rest then return end

  local midi_note = math.max(24, math.min(108, dna.root + s.oct_offset))
  local freq      = mtof(midi_note) * (2 ^ (s.drift / 12))
  local cutoff    = math.min(freq * s.cutoff_mult, 8000)

  engine.release(s.release)
  engine.cutoff(cutoff)
  engine.amp(s.amp * 0.8)
  engine.hz(freq)
  local vel = math.floor(s.amp * 0.8 * 127)
  if midi_out then midi_out:note_on(midi_note, vel, params:get("midi_channel")) end
  opxy_note_on(midi_note, vel)
  clock.run(function()
    clock.sleep(s.release)
    if midi_out then midi_out:note_off(midi_note, 0, params:get("midi_channel")) end
    opxy_note_off(midi_note)
  end)
end

-- -------------------------------------------------------
-- clock
-- -------------------------------------------------------

local function step_dur()
  return 60 / dna.rate / 4
end

local function run_arp()
  while running do
    step_idx = (step_idx % dna.steps) + 1
    local s = steps[step_idx]
    if not frozen then
      play_step(s)
    end
    clock.sleep(step_dur() * (s.dur_mult or 1))
    redraw()
  end
end

-- -------------------------------------------------------
-- DNA mutation & history
-- -------------------------------------------------------

local function randomize_dna()
  dna.seed  = math.random(1, 99999)
  dna.steps = rnd_int(4, 16)
  build_steps()
end

local function undo_mutation()
  if #history == 0 then print("MONODNA: no history"); return end
  history_idx = history_idx - 1
  if history_idx < 1 then history_idx = history_max end
  if history[history_idx] then
    steps = {}
    for i = 1, #history[history_idx] do
      steps[i] = {}
      for k, v in pairs(history[history_idx][i]) do steps[i][k] = v end
    end
  end
end

-- MIDI CC learn state
local cc_learn_enabled = false
local cc_learn_param = nil

-- -------------------------------------------------------
-- norns keys & encoders
-- -------------------------------------------------------

function key(n, z)
  if z == 1 then
    if n == 2 then
      randomize_dna()
      redraw()
    elseif n == 3 then
      frozen = not frozen
      redraw()
    end
  end
end

function enc(n, d)
  if n == 1 then
    dna.root = util.clamp(dna.root + d, 24, 96)
  elseif n == 2 then
    dna.rate = util.clamp(dna.rate + d, 40, 300)
    params:set("clock_tempo", dna.rate)
  elseif n == 3 then
    dna.intensity = util.clamp(dna.intensity + d * 0.02, 0, 1)
    build_steps()
  end
  redraw()
end

-- -------------------------------------------------------
-- display
-- -------------------------------------------------------

local note_names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local function midi_to_name(m)
  local n = (m % 12) + 1
  local o = math.floor(m / 12) - 1
  return note_names[n] .. o
end

-- -------------------------------------------------------
-- MIDI CC event handling
-- -------------------------------------------------------
function midi.event(data)
  local msg = midi.to_msg(data)
  if msg.type == "cc" then
    -- CC 14: mutation rate via CC
    if msg.cc == 14 then
      dna.intensity = util.clamp(msg.val / 127, 0, 1)
      build_steps()
    end
  end
end

function redraw()
  screen.clear()
  screen.aa(1)

  screen.level(15)
  screen.font_face(1)
  screen.font_size(8)
  screen.move(2, 9)
  screen.text("MONODNA")

  if frozen then
    screen.level(5)
    screen.move(88, 9)
    screen.text("FROZEN")
  end

  -- big root note
  screen.level(15)
  screen.font_size(28)
  screen.move(2, 42)
  screen.text(midi_to_name(dna.root))

  -- BPM
  screen.font_size(8)
  screen.level(10)
  screen.move(68, 42)
  screen.text(string.format("%d bpm", dna.rate))

  -- intensity label + bar
  screen.level(5)
  screen.move(68, 26)
  screen.text("chaos")
  screen.level(15)
  screen.rect(68, 29, math.floor(dna.intensity * 56), 4)
  screen.fill()

  -- step dots
  local total_w = 124
  local sw = math.floor(total_w / dna.steps) - 1
  sw = math.max(2, sw)
  for i = 1, dna.steps do
    local s = steps[i]
    local x = 2 + (i - 1) * (sw + 1)
    if i == step_idx then
      screen.level(15)
      screen.rect(x, 50, sw, 8)
      screen.fill()
    elseif s and s.is_rest then
      screen.level(2)
      screen.rect(x, 50, sw, 8)
      screen.stroke()
    else
      local lv = s and math.max(3, 10 - math.abs(s.oct_offset / 12) * 2) or 6
      screen.level(math.floor(lv))
      screen.rect(x, 50, sw, 8)
      screen.fill()
    end
  end

  screen.level(3)
  screen.font_size(8)
  screen.move(2, 64)
  screen.text(string.format("%d steps  seed:%05d", dna.steps, dna.seed))

  screen.update()
end

-- -------------------------------------------------------
-- init
-- -------------------------------------------------------

function init()
  math.randomseed(os.time())

  -- PolyPerc valid commands: amp, cutoff, gain, hz, pan, pw, release
  engine.amp(0.8)
  engine.cutoff(2000)
  engine.release(0.3)
  engine.pw(0.5)
  engine.pan(0)
  engine.gain(2.0)

  params:add_separator("MONODNA")
  params:add_number("root", "Root Note", 24, 96, dna.root)
  params:set_action("root", function(v) dna.root = v end)
  params:add_number("rate", "Rate (BPM)", 40, 300, dna.rate)
  params:set_action("rate", function(v)
    dna.rate = v
    params:set("clock_tempo", v)
  end)
  params:add_control("intensity", "Intensity",
    controlspec.new(0, 1, "lin", 0.01, 0.5, ""))
  params:set_action("intensity", function(v)
    dna.intensity = v
    build_steps()
  end)

  params:add_separator("MUTATIONS")
  params:add_option("scale_lock", "Scale Lock", scale_names, scale_lock)
  params:set_action("scale_lock", function(v)
    scale_lock = v
    build_steps()
  end)

  params:add_toggle("lock_oct", "Lock Octave Offset", mutation_locks.oct_offset)
  params:set_action("lock_oct", function(v) mutation_locks.oct_offset = v end)

  params:add_toggle("lock_drift", "Lock Pitch Drift", mutation_locks.drift)
  params:set_action("lock_drift", function(v) mutation_locks.drift = v end)

  params:add_toggle("lock_amp", "Lock Amplitude", mutation_locks.amp)
  params:set_action("lock_amp", function(v) mutation_locks.amp = v end)

  params:add_toggle("lock_cutoff", "Lock Cutoff", mutation_locks.cutoff_mult)
  params:set_action("lock_cutoff", function(v) mutation_locks.cutoff_mult = v end)

  build_steps()
  params:set("clock_tempo", dna.rate)

  params:add_separator("MIDI Out")
  params:add{type="number", id="midi_device", name="MIDI Device", min=1, max=16, default=1, action=function(v) midi_out = midi.connect(v) end}
  params:add{type="number", id="midi_channel", name="MIDI Channel", min=1, max=16, default=1}
  params:add_separator("OP-XY MIDI")
  params:add{type="number", id="opxy_device", name="OP-XY Device", min=1, max=16, default=2, action=function(v) opxy_out = midi.connect(v) end}
  params:add{type="number", id="opxy_channel", name="OP-XY Channel", min=1, max=16, default=1}
  midi_out = midi.connect(params:get("midi_device"))
  opxy_out = midi.connect(params:get("opxy_device"))

  beat_clock = clock.run(run_arp)
  redraw()
  print("MONODNA: running")
end

function cleanup()
  running = false
  if beat_clock then clock.cancel(beat_clock) end
  if midi_out then for ch=1,16 do midi_out:cc(123,0,ch) end end
  if opxy_out then for ch=1,16 do opxy_out:cc(123,0,ch) end end
end