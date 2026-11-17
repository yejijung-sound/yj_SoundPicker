# yj_SoundPicker
Welcome to yj_SoundPicker! You can easily search, audition, modify and spot sounds from your existing REAPER Media Explorer databases to your session ✨💖
Think of it as an enhanced version of Reaper's own Media Explorer! 

yj_SoundPicker offers OR, NOT, phrases and field syntax search, spectral waveform with range selection, multichannel lanes, pitch, stretch, reverse and EQ & compression FXs.
Drag or press "S" key to spot to your session, with everything you set baked onto the item.

## Installation
‼️[ReaImGui](https://reapack.com/) and [SWS](https://sws-extension.org/) must be installed to use yj_SoundPicker‼️
1. Make sure you have at least one Media Explorer database
2. Extensions > ReaPack > Import repositories
   
   <img width="421" height="167" alt="image" src="https://github.com/user-attachments/assets/a6a20ca5-fc04-4d59-9cb0-fb679437abe2" />

3. Paste the repository URL: https://github.com/yejijung-sound/yj_SoundPicker/raw/main/index.xml

   <img width="432" height="160" alt="image" src="https://github.com/user-attachments/assets/ae2372fd-781d-4fd7-a3e2-52fab71b9304" />

4. Extensions > ReaPack > Browse packages, find yj_SoundPicker, install

   <img width="440" height="316" alt="image" src="https://github.com/user-attachments/assets/e1a892f2-cf85-4ed9-bdb8-b9a8ba1219d6" />

I recommend setting it up as a start-up action (Extensions > SWS/S&M > Startup Actions > Set global startup action), so you don't have to manually open it every time you open REAPER!

<img width="541" height="156" alt="image" src="https://github.com/user-attachments/assets/ba73a227-1575-4494-8fe1-49f29e97776b" />

## KEY FEATURES
### Search
- Words, OR, NOT, "exact phrase", comma for OR, minus for exclude
- Field search: name: path: desc: lib: cat: db:
- Spec tokens read straight from the database: 48k+ 2ch 24b 0.5s- 10s+ 3s=
- Filters dropdown for the same things with checkboxes, including a length range
- Multiple databases with per-database checkboxes, duplicates shown onc
- Shuffle button for randomizing order of the list

### Audition
- Waveform with click to play, drag to select a range
- One lane per channel, up to eight
- Spectral colouring from REAPER’s own peak data, following the theme
- Loop, reverse, auto-play, monitor level that never touches what you spot
- Previews go straight to a chosen output pair
- Preview stops the moment the project transport starts

### Effects
- Volume, pitch in semitones or ratio, preserve pitch on or off for tape-style pitch
- Fit to a length in seconds
- Five-node EQ: HPF, three bells, LPF, with drag and mouse-wheel Q
- Compressor with draggable threshold, ratio, attack, release, makeup and a gain reduction meter
- EQ and comp reset when you pick another sound, so nothing carries over by accident

### Spot
- Spot button, S, Enter or double-click, onto the selected track at the edit cursor
- Does not create a track
- Multi-select with Ctrl, Shift and Shift+arrows, placed one after another
- Drag out to the arrange view with a ghost item showing the real waveform where it will land
- Copy into the project media folder, glue on spot, move cursor after spot

### Themes
- Four themes in light and dark: Rose, Sage, Rainbow, Simple
- Pixel or smooth icons, eight font sizes, dockable too!
- Hover guides you can switch off once you know your way around

## Key	Action
- Up/Down: browse results
- Shift + Up/Down: extend the selection
- Space: play/stop
- S/Enter: spot to session
- Ctrl + click: add or remove a result from the selection
- Shift + click: select a run of results
- Double-click: spot that result
- Ctrl + click or right click slider: reset the slider value
