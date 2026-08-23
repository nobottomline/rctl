# Foreground App Hooks

This component loads only into UIKit applications. `Tweak.mm` owns lightweight
app actions and still-camera hooks; `media/` owns foreground live camera and
virtual-microphone behavior.

Do not move SpringBoard capture/input or `mediaserverd` playback capture here.
Keep hooks idle until leased and release camera/audio resources on viewer loss,
process exit, and failed handoff. See `docs/CAM.md`, `docs/MEDIA.md`, and
`docs/VIRTUAL_MIC.md` before changing process ownership.
