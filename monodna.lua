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

local frozen = false
local beat_clock = nil

local dna = {
  root      = 48,
  rate      = 120,
  intensity = 0.5,
  steps     = 8,
  seed      = 1337,
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

-- -------------------------------------------------------
-- build steps from DNA
-- -------------------------------------------------------

local function build_steps()
  math.randomseed(dna.seed)
  local n = dna.steps
  local chaos = dna.intensity

  steps = {}
  for i = 1, n do
    local oct_range   = math.floor(lerp(0, 3, chaos))
    local oct_offset  = rnd_int(-oct_range, oct_range) * 12
    local drift       = rnd(-chaos * 0.4, chaos * 0.4)
    local amp         = rnd(lerp(0.8, 0.2, chaos), 1.0)
    local cutoff_mult = rnd(1.0, lerp(2.0, 10.0, chaos))
    local release     = rnd(0.05, lerp(0.3, 1.5, chaos))
    local is_rest     = math.random() < (chaos * 0.25)
    local dur_choices = {0.5, 1, 1, 1, 1, 1.5, 2}
    local dur_mult    = dur_choices[rnd_int(1, #dur_choices)]
    if chaos < 0.3 then dur_mult = 1 end

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
end

-- -------------------------------------------------------
-- clock
-- -------------------------------------------------------

local function step_dur()
  return 60 / dna.rate / 4
end

local function run_arp()
  while true do
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
-- DNA mutation
-- -------------------------------------------------------

local function randomize_dna()
  dna.seed  = math.random(1, 99999)
  dna.steps = rnd_int(4, 16)
  build_steps()
end

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

  build_steps()
  params:set("clock_tempo", dna.rate)

  beat_clock = clock.run(run_arp)
  redraw()
  print("MONODNA: running")
end

function cleanup()
  if beat_clock then clock.cancel(beat_clock) end
end
