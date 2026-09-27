// Adding the widgets: the desktop menu, the widget gallery (both reconstructed, macOS draws them), and the app's
// real widgets, dragged or sent to their place.
import React from "react";
import { Easing, Img, interpolate, staticFile } from "remotion";
import {
  accentColor,
  DONE_BUTTON,
  GALLERY,
  GALLERY_SIDEBAR,
  galleryTiles,
  lerpRect,
  Manifest,
  menuHeight,
  menuRows,
  MENU_WIDTH,
  Point,
  PREVIEW_SCALE,
  Rect,
  RIGHT_CLICK,
  SUBMENU_ITEMS,
  WIDGETS,
  WidgetId,
  widgetImage,
  WIDGET_INFO,
  WIDGET_SLOTS,
  withinRect,
} from "../layout";
import { T } from "../timeline";
import { box, glass, WidgetCard } from "./Glass";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;
const TEXT = "#1d1d1f";

// MARK: - Desktop menu

export const DesktopMenu: React.FC<{
  manifest: Manifest;
  seconds: number;
  cursor: Point;
}> = ({ manifest, seconds, cursor }) => {
  const open = T.rightClick + 0.05;
  const chosen = T.editWidgets + 0.04;
  if (seconds < open || seconds > chosen + 0.2) return null;
  // Once chosen, the row blinks once, then the menu fades.
  const blink = seconds >= chosen && seconds < chosen + 0.07;
  const fade = interpolate(seconds, [chosen + 0.08, chosen + 0.17], [1, 0], clamp);
  return (
    <div
      style={{
        ...box({
          x: RIGHT_CLICK.x,
          y: RIGHT_CLICK.y,
          w: MENU_WIDTH,
          h: menuHeight(),
        }),
        ...glass("rgba(242,242,245,0.8)", 24),
        borderRadius: 10,
        boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.16), 0 10px 32px rgba(8,10,30,0.32)",
        opacity: Math.min(1, (seconds - open) / 0.06) * fade,
        fontSize: 13,
        color: TEXT,
      }}
    >
      {menuRows().map(({ label, rect }, index) => {
        const local = {
          x: rect.x - RIGHT_CLICK.x,
          y: rect.y - RIGHT_CLICK.y,
          w: rect.w,
          h: rect.h,
        };
        if (label === null) {
          return (
            <div
              key={index}
              style={{
                ...box({
                  x: local.x + 9,
                  y: local.y + 5,
                  w: local.w - 18,
                  h: 1,
                }),
                background: "rgba(0,0,0,0.1)",
              }}
            />
          );
        }
        const hovered = withinRect(cursor, rect) && !blink;
        return (
          <div
            key={index}
            style={{
              ...box(local),
              borderRadius: 6,
              backgroundColor: hovered ? accentColor(manifest) : "transparent",
              color: hovered ? "white" : TEXT,
              display: "flex",
              alignItems: "center",
              justifyContent: "space-between",
              padding: "0 12px 0 14px",
              boxSizing: "border-box",
            }}
          >
            <span>{label}</span>
            {SUBMENU_ITEMS.has(label) ? <Chevron color={hovered ? "white" : "rgba(0,0,0,0.5)"} /> : null}
          </div>
        );
      })}
    </div>
  );
};

const Chevron: React.FC<{ color: string }> = ({ color }) => (
  <svg width="7" height="11" viewBox="0 0 7 11">
    <path d="M1.2 1 L5.6 5.5 L1.2 10" fill="none" stroke={color} strokeWidth="1.6" strokeLinecap="round" />
  </svg>
);

// MARK: - Gallery

const galleryShown = (seconds: number) => {
  const opening = interpolate(seconds, [T.galleryOpen, T.galleryOpen + 0.32], [0, 1], {
    ...clamp,
    easing: Easing.out(Easing.cubic),
  });
  const closing = interpolate(seconds, [T.done + 0.05, T.done + 0.3], [0, 1], {
    ...clamp,
    easing: Easing.in(Easing.quad),
  });
  return { opening, closing };
};

export const Gallery: React.FC<{ manifest: Manifest; seconds: number }> = ({ manifest, seconds }) => {
  const { opening, closing } = galleryShown(seconds);
  if (opening === 0 || closing === 1) return null;
  const tiles = galleryTiles();
  const local = (r: Rect): Rect => ({
    x: r.x - GALLERY.x,
    y: r.y - GALLERY.y,
    w: r.w,
    h: r.h,
  });
  const donePressed = seconds >= T.done - 0.03 && seconds < T.done + 0.08;
  return (
    <div
      style={{
        ...box(GALLERY),
        ...glass("rgba(244,244,247,0.86)", 30),
        borderRadius: 16,
        boxShadow: "inset 0 0 0 0.5px rgba(0,0,0,0.14), 0 18px 50px rgba(8,10,30,0.34)",
        opacity: opening * (1 - closing),
        transform: `translateY(${(1 - opening) * 26 + closing * 18}px)`,
        color: TEXT,
      }}
    >
      {/* Sidebar: the search field, then the app, selected. */}
      <div
        style={{
          ...box({ x: 0, y: 0, w: GALLERY_SIDEBAR, h: GALLERY.h }),
          borderRight: "0.5px solid rgba(0,0,0,0.12)",
        }}
      >
        <div
          style={{
            ...box({ x: 12, y: 14, w: GALLERY_SIDEBAR - 24, h: 24 }),
            borderRadius: 7,
            background: "rgba(0,0,0,0.06)",
            display: "flex",
            alignItems: "center",
            gap: 6,
            paddingLeft: 8,
            boxSizing: "border-box",
            fontSize: 12.5,
            color: "rgba(0,0,0,0.42)",
          }}
        >
          <Magnifier />
          Search Widgets
        </div>
        <div
          style={{
            ...box({ x: 8, y: 48, w: GALLERY_SIDEBAR - 16, h: 28 }),
            borderRadius: 7,
            background: "rgba(0,0,0,0.08)",
            display: "flex",
            alignItems: "center",
            gap: 8,
            paddingLeft: 8,
            boxSizing: "border-box",
            fontSize: 13,
            fontWeight: 500,
          }}
        >
          <Img src={staticFile("gen/icon.png")} style={{ width: 20, height: 20 }} />
          SimplyBar
        </div>
      </div>
      <div
        style={{
          ...box({ x: GALLERY_SIDEBAR + 20, y: 14, w: 300, h: 24 }),
          fontSize: 15,
          fontWeight: 700,
          lineHeight: "24px",
        }}
      >
        SimplyBar
      </div>
      <div
        style={{
          ...box(local(DONE_BUTTON)),
          borderRadius: 7,
          background: accentColor(manifest),
          color: "white",
          fontSize: 13,
          fontWeight: 500,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          filter: donePressed ? "brightness(0.82)" : undefined,
          boxShadow: "0 1px 2px rgba(0,0,0,0.18)",
        }}
      >
        Done
      </div>
      {WIDGETS.map((id) => {
        const tile = tiles[id];
        const column = local(tile.column);
        return (
          <React.Fragment key={id}>
            <WidgetCard image={widgetImage(id)} rect={local(tile.preview)} scale={PREVIEW_SCALE} />
            <div
              style={{
                ...box({
                  x: column.x - 4,
                  y: column.y + tile.preview.h + 7,
                  w: column.w + 8,
                  h: 50,
                }),
                textAlign: "center",
                lineHeight: 1.25,
              }}
            >
              <div style={{ fontSize: 12, fontWeight: 600 }}>{WIDGET_INFO[id].name}</div>
              <div
                style={{
                  fontSize: 10.5,
                  color: "rgba(0,0,0,0.55)",
                  marginTop: 2,
                }}
              >
                {WIDGET_INFO[id].description}
              </div>
            </div>
          </React.Fragment>
        );
      })}
    </div>
  );
};

const Magnifier: React.FC = () => (
  <svg width="12" height="12" viewBox="0 0 12 12">
    <circle cx="5" cy="5" r="3.8" fill="none" stroke="rgba(0,0,0,0.45)" strokeWidth="1.4" />
    <path d="M7.8 7.8 L11 11" stroke="rgba(0,0,0,0.45)" strokeWidth="1.5" strokeLinecap="round" />
  </svg>
);

// MARK: - Widgets on the desktop

/** Where a widget is at this time: nowhere yet, following the cursor, flying to its place, or in place. */
const widgetPlace = (id: WidgetId, seconds: number, cursor: Point): { rect: Rect; lifted: number } | null => {
  const tile = galleryTiles()[id];
  const slot = WIDGET_SLOTS[id];
  const drag = id === "cpu" ? T.dragCpu : id === "storage" ? T.dragStorage : null;
  if (drag) {
    if (seconds < drag.press) return null;
    if (seconds >= drag.drop)
      return {
        rect: slot,
        lifted: interpolate(seconds, [drag.drop, drag.drop + 0.15], [1, 0], clamp),
      };
    // Pressed at its centre in the gallery, it grows to its size on the desktop under the cursor.
    const grow = interpolate(seconds, [drag.press, drag.press + 0.28], [0, 1], {
      ...clamp,
      easing: Easing.out(Easing.cubic),
    });
    const w = tile.preview.w + (slot.w - tile.preview.w) * grow;
    const h = tile.preview.h + (slot.h - tile.preview.h) * grow;
    return {
      rect: { x: cursor.x - w / 2, y: cursor.y - h / 2, w, h },
      lifted: 1,
    };
  }
  const added = T.add[id as keyof typeof T.add] + 0.05;
  if (seconds < added) return null;
  const fly = interpolate(seconds, [added, added + 0.42], [0, 1], {
    ...clamp,
    easing: Easing.inOut(Easing.cubic),
  });
  return {
    rect: lerpRect(tile.preview, slot, fly),
    lifted: Math.sin(fly * Math.PI),
  };
};

export const DesktopWidgets: React.FC<{
  seconds: number;
  cursor: Point;
  layer: "under" | "over";
}> = ({ seconds, cursor, layer }) => {
  const { closing } = galleryShown(seconds);
  return (
    <>
      {WIDGETS.map((id) => {
        const place = widgetPlace(id, seconds, cursor);
        if (!place) return null;
        // A widget in flight passes over the gallery; once in place, it lies on the desktop, under it.
        const moving = place.lifted > 0.02 && closing < 1;
        if ((layer === "over") !== moving) return null;
        return (
          <WidgetCard
            key={id}
            image={widgetImage(id)}
            rect={place.rect}
            scale={place.rect.w / WIDGET_SLOTS[id].w}
            lifted={place.lifted}
          />
        );
      })}
    </>
  );
};
