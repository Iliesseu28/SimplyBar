// Frosted surfaces of the desktop, with the tints and shadows of tools/screenshots/compose.py.
import React from "react";
import { Img, staticFile } from "remotion";
import { Rect } from "../layout";

export const appImage = (name: string) => staticFile(`app/${name}.png`);

export const box = (r: Rect): React.CSSProperties => ({
  position: "absolute",
  left: r.x,
  top: r.y,
  width: r.w,
  height: r.h,
});

export const glass = (tint: string, blur: number): React.CSSProperties => ({
  backgroundColor: tint,
  backdropFilter: `blur(${blur}px) saturate(1.5)`,
  WebkitBackdropFilter: `blur(${blur}px) saturate(1.5)`,
});

/** A widget as the desktop shows it: its image on a light glass card; `scale` shrinks it in the gallery. */
export const WidgetCard: React.FC<{
  image: string;
  rect: Rect;
  scale: number;
  lifted?: number;
  opacity?: number;
}> = ({ image, rect, scale, lifted = 0, opacity = 1 }) => (
  <div
    style={{
      ...box(rect),
      ...glass("rgba(250,250,252,0.77)", 18 * scale),
      borderRadius: 22 * scale,
      boxShadow: [
        `inset 0 0 0 ${Math.max(0.5, scale)}px rgba(255,255,255,0.47)`,
        `0 ${4 + 10 * lifted}px ${20 + 30 * lifted}px rgba(8,10,30,${0.25 + 0.12 * lifted})`,
      ].join(", "),
      opacity,
      overflow: "hidden",
    }}
  >
    <Img
      src={appImage(image)}
      style={{
        position: "absolute",
        left: 0,
        top: 0,
        width: "100%",
        height: "100%",
      }}
    />
  </div>
);
