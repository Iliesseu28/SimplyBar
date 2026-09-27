// The settings window: the app's real window, one image per state (drawn by make.sh --video), in front.
import React from "react";
import { Easing, Img, interpolate } from "remotion";
import { Manifest, SETTINGS_ORIGIN, sizeOf } from "../layout";
import { MODULES, T } from "../timeline";
import { appImage, box } from "./Glass";

/** A switch or a row reacts when the button comes up, a moment after the press of the click sound. */
const LAG = 0.05;
/** The switch slides for a few frames: the two images cross over as long. */
const SWITCH_TIME = 0.14;

const pages = () => {
  const list: { at: number; name: string; fade: boolean }[] = [{ at: 0, name: "settings-cpu-off", fade: false }];
  for (const module of MODULES) {
    if (module !== "cpu")
      list.push({
        at: T.rows[module] + LAG,
        name: `settings-${module}-off`,
        fade: false,
      });
    list.push({
      at: T.switches[module] + LAG,
      name: `settings-${module}-on`,
      fade: true,
    });
  }
  return list;
};

export const SettingsWindow: React.FC<{
  manifest: Manifest;
  seconds: number;
}> = ({ manifest, seconds }) => {
  if (seconds < T.windowOpen || seconds > T.windowClose + 0.3) return null;
  const size = sizeOf(manifest, "settings-cpu-off");
  const list = pages();
  const index = list.findLastIndex((p) => seconds >= p.at);
  const current = list[index];
  const previous = index > 0 ? list[index - 1] : null;
  const crossing = current.fade && previous ? Math.min(1, (seconds - current.at) / SWITCH_TIME) : 1;

  const opening = interpolate(seconds, [T.windowOpen, T.windowOpen + 0.24], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.out(Easing.cubic),
  });
  const closing = interpolate(seconds, [T.windowClose + LAG, T.windowClose + LAG + 0.18], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: Easing.in(Easing.quad),
  });
  const scale = (0.9 + 0.1 * opening) * (1 - 0.06 * closing);
  const image = (name: string, opacity: number) => (
    <Img src={appImage(name)} style={{ ...box({ x: 0, y: 0, ...size }), opacity }} />
  );
  return (
    <div
      style={{
        ...box({ ...SETTINGS_ORIGIN, ...size }),
        borderRadius: 14,
        overflow: "hidden",
        backgroundColor: "white",
        boxShadow: "0 0 0 0.5px rgba(0,0,0,0.28), 0 22px 60px rgba(8,10,30,0.38), 0 4px 14px rgba(8,10,30,0.18)",
        opacity: opening * (1 - closing),
        transform: `scale(${scale})`,
      }}
    >
      {previous && crossing < 1 ? image(previous.name, 1) : null}
      {image(current.name, crossing)}
    </div>
  );
};
