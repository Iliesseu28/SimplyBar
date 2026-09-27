# SimplyBar promo video

The 29-second video at the top of the README (`docs/video/simplybar-promo.mp4`), made with
[Remotion](https://www.remotion.dev). Every window, popup, menu bar item and widget in it is an image of the app's
own SwiftUI views, drawn with demo numbers by `tools/screenshots/make.sh --video`. The desktop, the cursor, the
desktop menu and the widget gallery are drawn here, since macOS draws them. The voice is Gemini text-to-speech on
Vertex AI, recorded once and kept in `public/voice`; the clicks and the quiet pad are synthesized by
`scripts/prepare.py`.

## Render again

```sh
cd tools/promo-video
npm ci
zsh scripts/render.sh            # add --assets after a change of the app's views
```

It writes `docs/video/simplybar-promo.mp4` (1920 x 1080, 30 fps, H.264, AAC stereo, -16 LUFS) and
`docs/video/simplybar-promo-poster.jpg`. `npm run dev` opens the Remotion Studio.

## Files

| Path | Role |
| --- | --- |
| `src/timeline.ts` | when things happen, voice lines and subtitles |
| `src/layout.ts` | where things are on the desktop, in points |
| `src/motion.ts` | the camera and the cursor |
| `src/components/` | menu bar and popups, settings window, widgets and gallery, cursor, subtitles, end card |
| `src/narration.json` | the voice-over text; `python3 scripts/voice.py --force` records it again |
