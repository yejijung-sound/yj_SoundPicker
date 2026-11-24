# yj_SoundPicker
Welcome to yj_SoundPicker! You can easily search, audition, modify and spot sounds from your existing REAPER Media Explorer databases to your session ✨💖
Think of it as an enhanced version of Reaper's own Media Explorer! 

yj_SoundPicker offers OR, NOT, phrases and field syntax search, spectral waveform with range selection, multichannel lanes, pitch, stretch, reverse and EQ & compression FXs.
Drag or press "S" key to spot to your session, with everything you set baked onto the item.

The repository holds three scripts: **yj_SoundPicker** the browser, **yj_SoundSampler** to play what you pick from a MIDI keyboard, and **yj_UpdateChecker** to tell you when a newer version is out.

## Installation
‼️[ReaImGui](https://reapack.com/) and [SWS](https://sws-extension.org/) must be installed to use yj_SoundPicker‼️
1. Make sure you have at least one Media Explorer database
2. Extensions > ReaPack > Import repositories
   
   <img width="421" height="167" alt="image" src="https://github.com/user-attachments/assets/a6a20ca5-fc04-4d59-9cb0-fb679437abe2" />

3. Paste the repository URL: https://github.com/yejijung-sound/yj_SoundPicker/raw/main/index.xml

   <img width="432" height="160" alt="image" src="https://github.com/user-attachments/assets/ae2372fd-781d-4fd7-a3e2-52fab71b9304" />

4. Extensions > ReaPack > Browse packages, find yj_SoundPicker, install

   yj_SoundSampler and yj_UpdateChecker live in the same repository, so install those from the same list whenever you want them

   <img width="440" height="316" alt="image" src="https://github.com/user-attachments/assets/e1a892f2-cf85-4ed9-bdb8-b9a8ba1219d6" />

I recommend setting it up as a start-up action (Extensions > SWS/S&M > Startup Actions > Set global startup action), so you don't have to manually open it every time you open REAPER!

<img width="541" height="156" alt="image" src="https://github.com/user-attachments/assets/ba73a227-1575-4494-8fe1-49f29e97776b" />

## KEY FEATURES
### Search
- Words, OR, NOT, "exact phrase", comma for OR, minus for exclude
- Field search: name: path: desc: lib: cat: db:
- Spec tokens read straight from the database: 48k+ 2ch 24b 0.5s- 10s+ 3s=
- Filters dropdown for the same things with checkboxes, including a length range
- Multiple databases with per-database checkboxes, duplicates shown once
- Shuffle button for randomizing order of the list

### Audition
- Waveform with click to play, drag to select a range
- One lane per channel, up to eight
- Spectral colouring following the theme, from REAPER’s own peak data, and built for you when a file hasn’t got any yet
- Loop, reverse, auto-play, monitor level that never touches what you spot
- Previews go straight to a chosen output pair
- Preview stops the moment the project transport starts

### Effects
- Volume, pitch in semitones or ratio, preserve pitch on or off for tape-style pitch
- Fit to a length in seconds
- Five-node EQ: HPF, three bells, LPF, with drag and mouse-wheel Q
- Compressor with draggable threshold, ratio, attack, release, makeup and a gain reduction meter
- Reset button on each panel, so you can start the EQ or the comp over without touching every node
- EQ and comp reset when you pick another sound, or tick Keep FX between files to audition several files through the same band

### Spot
- Spot button, S, Enter or double-click, onto the selected track at the edit cursor
- Does not create a track
- Multi-select with Ctrl, Shift and Shift+arrows, placed one after another
- Drag out to the arrange view with a ghost item showing the real waveform where it will land
- Right-click or Escape while still holding the mouse cancels a drag
- Copy into the project media folder, glue on spot, move cursor after spot

### Themes
- Four themes in light and dark: Rose, Sage, Rainbow, Simple
- Three icon sets: Pixel, Outline and Bulky, eight font sizes, dockable too!
- Hover guides you can switch off once you know your way around

### Layout
- Reorder columns by dragging a header, hide the ones you don't need by right-clicking, remembered between sessions
- Hide the waveform and the EQ & comp panels for a list-only layout, handy on a vertical monitor
- Put the waveform above the list instead of below

## yj_SoundSampler
Press the keyboard button in the top bar to open it, or run it from the action list 🎹

Plays the sounds you pick from a MIDI keyboard, so you can audition a whole library of takes under your fingers instead of clicking through them.
- Eight slots, each one with its own key range and root note, tiled across the keyboard
- Pick a sound in SoundPicker and it drops straight into the selected slot
- Your waveform selection becomes the slot's in and out points
- Gain, pan, loop, solo and mute per slot
- Envelope with a graph you drag by its corners, on an axis that follows however long the envelope actually is
- Three LFOs per slot, one each for volume, pan and pitch, with their own shape, speed and depth
- An on-screen piano you can click, and your MIDI keyboard plays the same slots
- Ctrl + click resets any control, or clears a slot
- Close it and reopen it: your slots are still there
- Follows SoundPicker's theme, font size and hover guides
- Drag files onto the window to fill slots directly
- Each slot is a ReaSamplomatic5000 on one armed track, so REAPER plays and records it

## yj_UpdateChecker
Tells you whether a newer yj_SoundPicker or yj_SoundSampler has been published.

Open SoundPicker's settings and press **Check for Updates**, or run it from the action list. It runs either way, and offers to open ReaPack's synchronize when something is behind.

## Key	Action
- Up/Down: browse results
- Shift + Up/Down: extend the selection
- Space: play/stop
- S/Enter: spot to session
- Ctrl + click: add or remove a result from the selection
- Shift + click: select a run of results
- Double-click: spot that result
- Ctrl + click or right click slider: reset the slider value
- Escape or right click: cancel a drag in progress
