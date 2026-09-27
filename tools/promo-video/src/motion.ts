// The camera and the cursor: where they are at any time, from a few keyframes.
import { Easing } from "remotion";
import {
  center,
  DESKTOP,
  DONE_BUTTON,
  editWidgetsRow,
  galleryTiles,
  K,
  Manifest,
  menubarSlots,
  Point,
  RIGHT_CLICK,
  SETTINGS_POINTS,
  stateAt,
  VIDEO,
  WIDGET_SLOTS,
} from "./layout";
import { ModuleId, T } from "./timeline";

const smooth = Easing.bezier(0.45, 0, 0.25, 1);
/** A hand moves fast, then slows down onto its target. */
const reach = Easing.bezier(0.3, 0.05, 0.12, 1);

// MARK: - Camera

export type Camera = { zoom: number; x: number; y: number };

/**
 * Keyframes: a zoom, and where the view sits in the room it has at that zoom (0: against the left or top edge of
 * the desktop, 1: against the right or bottom one). The view never shows beyond the desktop, and a view pinned to
 * the menu bar's corner stays pinned while it zooms.
 */
const CAMERA: { t: number; zoom: number; ax: number; ay: number }[] = [
  { t: 0, zoom: 1, ax: 0.5, ay: 0.5 },
  { t: 1.3, zoom: 1.04, ax: 1, ay: 0 },
  { t: 2.6, zoom: 1.22, ax: 1, ay: 0 },
  { t: 8.7, zoom: 1.24, ax: 1, ay: 0 },
  { t: 9.45, zoom: 1.4, ax: 1, ay: 0 },
  { t: 14.4, zoom: 1.44, ax: 1, ay: 0 },
  { t: 15.25, zoom: 1, ax: 0.5, ay: 0.5 },
];

export const cameraAt = (seconds: number): Camera => {
  const next = CAMERA.findIndex((k) => k.t > seconds);
  const a = CAMERA[Math.max(0, next === -1 ? CAMERA.length - 1 : next - 1)];
  const b = next <= 0 ? a : CAMERA[next];
  const u = a === b ? 0 : smooth((seconds - a.t) / (b.t - a.t));
  // The zoom moves on a log scale, so a push in feels as steady at its end as at its start.
  const zoom = Math.exp(Math.log(a.zoom) + (Math.log(b.zoom) - Math.log(a.zoom)) * u);
  const ax = a.ax + (b.ax - a.ax) * u;
  const ay = a.ay + (b.ay - a.ay) * u;
  const w = DESKTOP.w / zoom;
  const h = DESKTOP.h / zoom;
  return { zoom, x: w / 2 + ax * (DESKTOP.w - w), y: h / 2 + ay * (DESKTOP.h - h) };
};

/** Video pixels of a desktop point. */
export const toScreen = (c: Camera, p: Point): Point => ({
  x: (p.x - c.x) * c.zoom * K + VIDEO.w / 2,
  y: (p.y - c.y) * c.zoom * K + VIDEO.h / 2,
});

// MARK: - Cursor

type Move = { from: number; to: number; target: Point; bend: number };
export type Click = {
  t: number;
  button: "left" | "right";
  kind?: "press" | "release";
};
export type CursorPath = { start: Point; moves: Move[]; clicks: Click[] };

export const isShownInMenuBar = (module: ModuleId, seconds: number) => seconds >= T.switches[module] + 0.07;

export const buildCursorPath = (manifest: Manifest): CursorPath => {
  const moves: Move[] = [];
  const clicks: Click[] = [];
  const move = (from: number, to: number, target: Point, bend = 0.12) => moves.push({ from, to, target, bend });
  const click = (t: number, button: Click["button"] = "left") => clicks.push({ t, button });

  /** Centre of a menu bar item at the time it is clicked. */
  const item = (module: ModuleId, t: number): Point => {
    const state = stateAt(manifest, t);
    const slot = menubarSlots(manifest, state, (m) => isShownInMenuBar(m, t)).find((s) => s.module === module);
    if (!slot) throw new Error(`${module} is not in the menu bar at ${t} s`);
    return { x: slot.x + slot.w / 2, y: 12 };
  };
  const s = SETTINGS_POINTS;
  const tiles = galleryTiles();

  // Desktop, then the settings window: each module is selected, then switched on.
  move(0.05, 1.2, { x: 800, y: 470 }, 0.18);
  move(1.5, 2.1, { x: 770, y: 428 }, -0.1);
  move(2.6, 3.35, s.rows.cpu, 0.14);
  move(3.85, 4.55, s.switchOff, -0.12);
  click(T.switches.cpu);
  move(4.95, 5.4, s.rows.memory, 0.1);
  click(T.rows.memory);
  move(5.56, 5.88, s.switchOff, -0.08);
  click(T.switches.memory);
  move(6.2, 6.62, s.rows.network, 0.1);
  click(T.rows.network);
  move(6.76, 7.08, s.switchOff, -0.08);
  click(T.switches.network);
  move(7.4, 7.83, s.rows.disk, 0.1);
  click(T.rows.disk);
  move(7.96, 8.28, s.switchOff, -0.08);
  click(T.switches.disk);
  move(8.42, 8.78, s.close, 0.1);
  click(T.windowClose);

  // Menu bar: one item after the other, the last one clicked again to close its popup.
  const [cpu, memory, network, disk] = T.popups;
  move(8.95, 9.42, item("cpu", cpu.open), -0.14);
  click(cpu.open);
  move(10.5, 10.82, item("memory", memory.open), 0.05);
  click(memory.open);
  move(11.8, 12.12, item("network", network.open), 0.05);
  click(network.open);
  move(13.0, 13.32, item("disk", disk.open), 0.05);
  click(disk.open);
  click(disk.close);

  // Desktop menu, then the gallery.
  move(14.6, 15.5, RIGHT_CLICK, 0.16);
  click(T.rightClick, "right");
  const edit = editWidgetsRow();
  move(16.45, 17.15, { x: edit.x + 62, y: edit.y + edit.h / 2 }, 0.1);
  click(T.editWidgets);

  move(17.9, 18.7, center(tiles.cpu.preview), -0.12);
  clicks.push({ t: T.dragCpu.press, button: "left", kind: "press" });
  move(18.95, 19.35, center(WIDGET_SLOTS.cpu), 0.1);
  clicks.push({ t: T.dragCpu.drop, button: "left", kind: "release" });
  move(19.55, 20.1, center(tiles.memory.preview), -0.1);
  click(T.add.memory);
  move(20.5, 20.76, center(tiles.network.preview), 0.04);
  click(T.add.network);
  move(21.1, 21.36, center(tiles.disk.preview), 0.04);
  click(T.add.disk);
  move(21.46, 21.72, center(tiles.storage.preview), 0.04);
  clicks.push({ t: T.dragStorage.press, button: "left", kind: "press" });
  move(21.85, 22.25, center(WIDGET_SLOTS.storage), -0.1);
  clicks.push({ t: T.dragStorage.drop, button: "left", kind: "release" });
  move(22.45, 22.92, center(DONE_BUTTON), 0.12);
  click(T.done);

  // Last look: a popup open over the finished desktop (the poster frame).
  const last = T.popups[4];
  move(23.1, 23.52, item("cpu", last.open), -0.12);
  click(last.open);
  move(23.9, 24.5, { x: 1052, y: 176 }, 0.1);

  return { start: { x: 600, y: 650 }, moves, clicks };
};

export const cursorAt = (path: CursorPath, seconds: number): Point => {
  let position = path.start;
  for (const m of path.moves) {
    if (seconds <= m.from) break;
    const from = position;
    if (seconds >= m.to) {
      position = m.target;
      continue;
    }
    // A curved stroke: a quadratic Bezier bent to one side of the straight line.
    const u = reach((seconds - m.from) / (m.to - m.from));
    const dx = m.target.x - from.x;
    const dy = m.target.y - from.y;
    const control = {
      x: (from.x + m.target.x) / 2 - dy * m.bend,
      y: (from.y + m.target.y) / 2 + dx * m.bend,
    };
    const a = (1 - u) * (1 - u);
    const b = 2 * (1 - u) * u;
    const c = u * u;
    return {
      x: a * from.x + b * control.x + c * m.target.x,
      y: a * from.y + b * control.y + c * m.target.y,
    };
  }
  return position;
};
