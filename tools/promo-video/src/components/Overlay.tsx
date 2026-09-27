// What sits over the desktop, in video pixels: the cursor, the subtitles and the end card.
import React from "react";
import { Easing, Img, interpolate, spring, staticFile } from "remotion";
import { Point } from "../layout";
import { Camera, Click } from "../motion";
import { DURATION, FPS, SUBTITLES, T, VOICE, voiceEnd } from "../timeline";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

// MARK: - Cursor

/** The pointer, drawn: an arrow of about 12 by 19 points, black with a white rim, tip at (0, 0). */
const ARROW = "M0 0 L0 16.2 L3.9 12.5 L6.6 18.6 L9.3 17.4 L6.7 11.6 L11.8 11.6 Z";

export const Cursor: React.FC<{
  at: Point;
  camera: Camera;
  clicks: Click[];
  seconds: number;
  fade: number;
  placeOf: (click: Click) => Point;
}> = ({ at, camera, clicks, seconds, fade, placeOf }) => {
  // Bigger when the camera is close, as on a zoomed screen, but less than the zoom so it never fills the view.
  const size = 1.45 * Math.sqrt(camera.zoom);
  const recent = clicks.filter((c) => seconds >= c.t - 0.06 && seconds < c.t + 0.5);
  const press = recent.some((c) => c.kind !== "release" && seconds < c.t + 0.07) ? 0.88 : 1;
  // Between a press and its release, while a widget is dragged.
  const holding = clicks.some(
    (p) =>
      p.kind === "press" && seconds >= p.t && !clicks.some((r) => r.kind === "release" && r.t > p.t && seconds >= r.t),
  );
  return (
    <>
      {/* A ring where each click lands: it stays there while the cursor goes on. */}
      {recent
        .filter((c) => c.kind !== "release" && seconds >= c.t)
        .map((c) => {
          const u = (seconds - c.t) / 0.45;
          const radius = (8 + 22 * Easing.out(Easing.cubic)(u)) * size;
          const place = placeOf(c);
          return (
            <div
              key={c.t}
              style={{
                position: "absolute",
                left: place.x - radius,
                top: place.y - radius,
                width: radius * 2,
                height: radius * 2,
                borderRadius: "50%",
                border: `${2 * size}px solid rgba(255,255,255,${0.75 * (1 - u)})`,
                backgroundColor:
                  c.button === "right" ? `rgba(0,0,0,${0.12 * (1 - u)})` : `rgba(255,255,255,${0.16 * (1 - u)})`,
                boxShadow: `0 0 ${10 * size}px rgba(0,0,0,${0.18 * (1 - u)})`,
                opacity: fade,
              }}
            />
          );
        })}
      <div style={{ position: "absolute", left: at.x, top: at.y, opacity: fade }}>
        <svg
          width={20 * size}
          height={26 * size}
          viewBox="-2 -2 18 24"
          style={{
            position: "absolute",
            left: -2 * size,
            top: -2 * size,
            transform: `scale(${press * (holding ? 0.94 : 1)})`,
            transformOrigin: `${2 * size}px ${2 * size}px`,
            filter: `drop-shadow(0 ${1.2 * size}px ${1.6 * size}px rgba(0,0,0,0.38))`,
            overflow: "visible",
          }}
        >
          <path d={ARROW} fill="black" stroke="white" strokeWidth="1.15" strokeLinejoin="round" />
        </svg>
      </div>
    </>
  );
};

// MARK: - Subtitles

export const Subtitles: React.FC<{ seconds: number }> = ({ seconds }) => {
  const pages = SUBTITLES.map((page, index) => {
    const start = VOICE[page.line] + page.at;
    const next = SUBTITLES[index + 1];
    const nextStart = next ? VOICE[next.line] + next.at : Infinity;
    const sameLine = next && next.line === page.line;
    // A page stays a moment after its words, has faded out when the next one fades in, and is gone before the
    // last frame.
    const end = Math.min(sameLine ? nextStart : voiceEnd(page.line) + 0.25, nextStart - 0.05, DURATION - 0.12);
    return { ...page, start, end };
  });
  const page = pages.find((p) => seconds >= p.start - 0.05 && seconds < p.end);
  if (!page) return null;
  const opacity = Math.min(1, (seconds - page.start + 0.05) / 0.12, (page.end - seconds) / 0.12);
  return (
    <div
      style={{
        position: "absolute",
        left: 80,
        right: 80,
        bottom: 104,
        display: "flex",
        justifyContent: "center",
      }}
    >
      {/* The opacity sits on the pill itself: on a parent, it would switch off the blur behind the pill. */}
      <div
        style={{
          opacity,
          maxWidth: 1760,
          padding: "12px 30px 14px",
          borderRadius: 20,
          backgroundColor: "rgba(12,14,24,0.66)",
          backdropFilter: "blur(12px)",
          color: "white",
          fontSize: 44,
          fontWeight: 600,
          letterSpacing: -0.2,
          lineHeight: 1.2,
          textAlign: "center",
          whiteSpace: "nowrap",
        }}
      >
        {page.text}
      </div>
    </div>
  );
};

// MARK: - End card

export const EndCard: React.FC<{ frame: number }> = ({ frame }) => {
  const start = T.endCard * FPS;
  if (frame < start) return null;
  const pop = (delaySeconds: number) =>
    spring({
      frame: frame - start - delaySeconds * FPS,
      fps: FPS,
      config: { damping: 16, stiffness: 140, mass: 0.8 },
    });
  const veil = interpolate(frame, [start, start + 0.5 * FPS], [0, 1], clamp);
  const icon = pop(0.1);
  const name = pop(0.2);
  // The lines come with the words that say them.
  const free = pop(VOICE.outro + 1.28 - T.endCard - 0.1);
  const store = pop(VOICE.outro + 2.6 - T.endCard - 0.1);
  const rise = (p: number) => ({
    opacity: Math.min(1, p * 1.3),
    transform: `translateY(${(1 - p) * 26}px)`,
  });
  return (
    <div style={{ position: "absolute", inset: 0 }}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          backgroundColor: `rgba(14,16,40,${0.34 * veil})`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          top: 190,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          color: "white",
          textShadow: "0 2px 18px rgba(0,0,0,0.25)",
        }}
      >
        <Img
          src={staticFile("gen/icon.png")}
          style={{
            width: 200,
            height: 200,
            opacity: Math.min(1, icon * 1.4),
            transform: `scale(${0.6 + 0.4 * icon})`,
            filter: "drop-shadow(0 16px 30px rgba(0,0,0,0.3))",
          }}
        />
        <div
          style={{
            fontSize: 112,
            fontWeight: 700,
            letterSpacing: -2,
            marginTop: 18,
            ...rise(name),
          }}
        >
          SimplyBar
        </div>
        <div style={{ fontSize: 50, fontWeight: 500, marginTop: 6, ...rise(free) }}>Free and open source</div>
        <div
          style={{
            marginTop: 30,
            padding: "10px 28px 12px",
            borderRadius: 40,
            fontSize: 36,
            fontWeight: 600,
            backgroundColor: "rgba(255,255,255,0.16)",
            boxShadow: "inset 0 0 0 1.5px rgba(255,255,255,0.4)",
            ...rise(store),
          }}
        >
          On the Mac App Store
        </div>
      </div>
    </div>
  );
};
