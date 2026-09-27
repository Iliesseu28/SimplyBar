// SimplyBar's promo video: a desktop filmed by a moving camera, the app's own views on it, a voice and subtitles.
import React, { useMemo } from "react";
import { AbsoluteFill, Img, interpolate, Sequence, staticFile, useCurrentFrame } from "remotion";
import { Audio } from "@remotion/media";
import { DesktopMenu, DesktopWidgets, Gallery } from "./components/Widgets";
import { MenuBar, Popups } from "./components/MenuBar";
import { Cursor, EndCard, Subtitles } from "./components/Overlay";
import { SettingsWindow } from "./components/SettingsWindow";
import { DESKTOP, K, Manifest, VIDEO } from "./layout";
import { buildCursorPath, cameraAt, cursorAt, toScreen } from "./motion";
import { DURATION, FPS, frame as toFrame, LineId, T, VOICE } from "./timeline";
import voice from "./voice.json";

export type PromoProps = { manifest: Manifest | null };

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

export const Promo: React.FC<PromoProps> = ({ manifest }) => {
  const frame = useCurrentFrame();
  const path = useMemo(() => (manifest ? buildCursorPath(manifest) : null), [manifest]);
  if (!manifest || !path) throw new Error("no manifest: calculateMetadata reads public/app/video-assets.json");
  const seconds = frame / FPS;
  const camera = cameraAt(seconds);
  const cursor = cursorAt(path, seconds);
  const scale = camera.zoom * K;
  const ending = interpolate(seconds, [T.endCard, T.endCard + 0.6], [0, 1], clamp);

  return (
    <AbsoluteFill
      style={{
        backgroundColor: "black",
        fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif',
        WebkitFontSmoothing: "antialiased",
      }}
    >
      {ending > 0 ? (
        <Img
          src={staticFile("gen/wallpaper.jpg")}
          style={{ position: "absolute", inset: 0, width: VIDEO.w, height: VIDEO.h, filter: "blur(30px)" }}
        />
      ) : null}
      <div
        style={{
          position: "absolute",
          left: 0,
          top: 0,
          width: DESKTOP.w,
          height: DESKTOP.h,
          transformOrigin: "0 0",
          transform: `translate(${VIDEO.w / 2 - camera.x * scale}px, ${VIDEO.h / 2 - camera.y * scale}px) scale(${scale})`,
          filter: ending > 0 ? `blur(${ending * 18}px)` : undefined,
        }}
      >
        <Img
          src={staticFile("gen/wallpaper.jpg")}
          style={{
            position: "absolute",
            inset: 0,
            width: DESKTOP.w,
            height: DESKTOP.h,
          }}
        />
        <DesktopWidgets seconds={seconds} cursor={cursor} layer="under" />
        <SettingsWindow manifest={manifest} seconds={seconds} />
        <Gallery manifest={manifest} seconds={seconds} />
        <DesktopWidgets seconds={seconds} cursor={cursor} layer="over" />
        <DesktopMenu manifest={manifest} seconds={seconds} cursor={cursor} />
        <MenuBar manifest={manifest} seconds={seconds} />
        <Popups manifest={manifest} seconds={seconds} />
      </div>
      <Cursor
        at={toScreen(camera, cursor)}
        camera={camera}
        clicks={path.clicks}
        seconds={seconds}
        fade={1 - ending}
        placeOf={(click) => toScreen(camera, cursorAt(path, click.t))}
      />
      <EndCard frame={frame} />
      <Subtitles seconds={seconds} />

      {(Object.keys(VOICE) as LineId[]).map((id) => (
        <Sequence key={id} from={toFrame(VOICE[id])} durationInFrames={Math.ceil(voice[id] * FPS) + 2} layout="none">
          <Audio src={staticFile(`voice/${id}.wav`)} />
        </Sequence>
      ))}
      {path.clicks.map((c) => (
        <Sequence key={`${c.t}-${c.kind ?? "click"}`} from={toFrame(c.t - 0.02)} durationInFrames={8} layout="none">
          <Audio
            src={staticFile(c.kind === "release" ? "gen/drop.wav" : "gen/click.wav")}
            volume={() => (c.button === "right" ? 0.8 : 1)}
          />
        </Sequence>
      ))}
      <Sequence durationInFrames={toFrame(DURATION)} layout="none">
        <Audio src={staticFile("gen/pad.wav")} volume={() => 0.5} />
      </Sequence>
    </AbsoluteFill>
  );
};
