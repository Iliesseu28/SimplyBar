// The menu bar: the system icons, then SimplyBar's items as the settings switch them on, each image one reading
// of the app's own status item view.
import React from "react";
import { Easing, Img, interpolate } from "remotion";
import {
  DESKTOP,
  Manifest,
  MENUBAR_HEIGHT,
  menubarSlots,
  openPopup,
  popupRect,
  Slot,
  stateAt,
  trayRect,
} from "../layout";
import { isShownInMenuBar } from "../motion";
import { FPS, T } from "../timeline";
import { appImage, box, glass } from "./Glass";

const slotsAt = (manifest: Manifest, seconds: number) => {
  const state = stateAt(manifest, seconds);
  return {
    state,
    slots: menubarSlots(manifest, state, (m) => isShownInMenuBar(m, seconds)),
  };
};

export const MenuBar: React.FC<{ manifest: Manifest; seconds: number }> = ({ manifest, seconds }) => {
  const { state, slots } = slotsAt(manifest, seconds);
  const popup = openPopup(seconds);
  return (
    <div
      style={{
        ...box({ x: 0, y: 0, w: DESKTOP.w, h: MENUBAR_HEIGHT }),
        ...glass("rgba(250,250,255,0.41)", 9),
      }}
    >
      <Img src={appImage("menubar-system")} style={{ ...box(trayRect(manifest)), opacity: 0.88 }} />
      {slots.map((slot) => {
        const appear = interpolate(seconds, [T.switches[slot.module] + 0.07, T.switches[slot.module] + 0.3], [0, 1], {
          extrapolateLeft: "clamp",
          extrapolateRight: "clamp",
          easing: Easing.out(Easing.back(2)),
        });
        return (
          <React.Fragment key={slot.module}>
            {popup?.module === slot.module ? (
              <div
                style={{
                  ...box({
                    x: slot.x + 1,
                    y: 2,
                    w: slot.w - 2,
                    h: MENUBAR_HEIGHT - 4,
                  }),
                  borderRadius: 5,
                  backgroundColor: "rgba(0,0,0,0.13)",
                }}
              />
            ) : null}
            <Img
              src={appImage(`menubar-${slot.module}-${state}`)}
              style={{
                ...box(slot.item),
                opacity: 0.88 * Math.min(1, appear * 1.4),
                transform: `scale(${0.6 + 0.4 * appear})`,
              }}
            />
          </React.Fragment>
        );
      })}
    </div>
  );
};

/** The popup of the clicked item, its numbers and history moving one reading at a time. */
export const Popups: React.FC<{ manifest: Manifest; seconds: number }> = ({ manifest, seconds }) => {
  return (
    <>
      {T.popups.map((p, index) => {
        const fadeOut = 0.08;
        if (seconds < p.open || seconds >= p.close + fadeOut) return null;
        // Placed under its item as it was when clicked: a popup does not move once open.
        const slot: Slot | undefined = slotsAt(manifest, p.open).slots.find((s) => s.module === p.module);
        if (!slot) throw new Error(`popup ${p.module} opens while its item is hidden`);
        const state = stateAt(manifest, seconds);
        const rect = popupRect(manifest, p.module, slot, state);
        const opacity = Math.min((seconds - p.open) / 0.1, 1, (p.close + fadeOut - seconds) / fadeOut);
        return (
          <div
            key={index}
            style={{
              ...box(rect),
              ...glass("rgba(246,246,248,0.87)", 20),
              borderRadius: 14,
              boxShadow: "inset 0 0 0 0.75px rgba(0,0,0,0.11), 0 8px 32px rgba(8,10,30,0.4)",
              opacity,
              transform: `translateY(${(1 - Math.min(1, ((seconds - p.open) * FPS) / 4)) * -3}px)`,
            }}
          >
            <Img src={appImage(`popup-${p.module}-${state}`)} style={box({ x: 0, y: 0, w: rect.w, h: rect.h })} />
          </div>
        );
      })}
    </>
  );
};
