// Where things are on the drawn desktop, in points (the renderer's images are 4 pixels per point).
// Styles and spacing follow tools/screenshots/compose.py, which lays out the App Store screenshots.
import { ModuleId, MODULES, T } from "./timeline";

export const DESKTOP = { w: 1440, h: 810 };
export const VIDEO = { w: 1920, h: 1080 };
/** Video pixels per point when the camera shows the whole desktop. */
export const K = VIDEO.w / DESKTOP.w;
export const MENUBAR_HEIGHT = 24;

export type Point = { x: number; y: number };
export type Rect = { x: number; y: number; w: number; h: number };
export type Size = { w: number; h: number };
export type Manifest = {
  scale: number;
  states: number;
  sizes: Record<string, Size>;
  accent: [number, number, number];
};

export const sizeOf = (manifest: Manifest, name: string): Size => {
  const size = manifest.sizes[name];
  if (!size) throw new Error(`public/app/video-assets.json has no size for ${name}`);
  return size;
};
export const center = (r: Rect): Point => ({
  x: r.x + r.w / 2,
  y: r.y + r.h / 2,
});
export const accentColor = (m: Manifest, alpha = 1) => `rgba(${m.accent.join(",")},${alpha})`;

/** Which reading the menu bar and the popups show at this frame. */
export const stateAt = (manifest: Manifest, seconds: number) => Math.floor(seconds / T.update + 1e-6) % manifest.states;

// MARK: - Menu bar

/** The menu bar right to left: the system icons, then the items, the newest on the left (as macOS inserts them). */
export const MENUBAR_ORDER: ModuleId[] = ["cpu", "memory", "network", "disk"];

export type Slot = { module: ModuleId; x: number; w: number; item: Rect };

export const trayRect = (manifest: Manifest): Rect => {
  const size = sizeOf(manifest, "menubar-system");
  return {
    x: DESKTOP.w - 12 - size.w,
    y: (MENUBAR_HEIGHT - size.h) / 2,
    ...size,
  };
};

/** Slots of the items shown at this time, each 14 points wider than its image, 10 points before the system icons. */
export const menubarSlots = (manifest: Manifest, state: number, shown: (m: ModuleId) => boolean): Slot[] => {
  let x = trayRect(manifest).x - 10;
  const slots: Slot[] = [];
  for (const module of MENUBAR_ORDER) {
    if (!shown(module)) continue;
    const size = sizeOf(manifest, `menubar-${module}-${state}`);
    x -= size.w + 14;
    slots.push({
      module,
      x,
      w: size.w + 14,
      item: { x: x + 7, y: (MENUBAR_HEIGHT - size.h) / 2, ...size },
    });
  }
  return slots;
};

/** A popup opens under its item, left edges aligned, kept on screen. */
export const popupRect = (manifest: Manifest, module: ModuleId, slot: Slot, state: number): Rect => {
  const size = sizeOf(manifest, `popup-${module}-${state}`);
  return {
    x: Math.min(Math.max(8, slot.x), DESKTOP.w - size.w - 8),
    y: MENUBAR_HEIGHT + 5,
    ...size,
  };
};

// MARK: - Settings window (its images are the real window, title bar included)

export const SETTINGS_ORIGIN: Point = { x: 370, y: 70 };
const inWindow = (x: number, y: number): Point => ({
  x: SETTINGS_ORIGIN.x + x,
  y: SETTINGS_ORIGIN.y + y,
});
export const SETTINGS_POINTS = {
  close: inWindow(15.9, 15.4),
  /** "Show in menu bar" while the module is off: the only control of the pane, centred. */
  switchOff: inWindow(493, 252),
  rows: {
    cpu: inWindow(72, 58),
    memory: inWindow(72, 90),
    network: inWindow(78, 153.4),
    disk: inWindow(70, 185.2),
  } as Record<ModuleId, Point>,
};

// MARK: - Widgets

export const SMALL = 170;
/** Where each widget lands: three small ones, then SSD and the medium Storage widget under them. */
export const WIDGET_SLOTS: Record<WidgetId, Rect> = {
  cpu: { x: 40, y: 48, w: SMALL, h: SMALL },
  memory: { x: 234, y: 48, w: SMALL, h: SMALL },
  network: { x: 428, y: 48, w: SMALL, h: SMALL },
  disk: { x: 40, y: 260, w: SMALL, h: SMALL },
  storage: { x: 234, y: 260, w: 364, h: SMALL },
};
export type WidgetId = ModuleId | "storage";
export const WIDGETS: WidgetId[] = [...MODULES, "storage"];
export const widgetImage = (id: WidgetId) => (id === "storage" ? "widget-storage-medium" : `widget-${id}`);

// The widget gallery, reconstructed (macOS draws it): the names and descriptions are the widgets' own.
export const GALLERY: Rect = { x: 240, y: 462, w: 960, h: 206 };
export const GALLERY_SIDEBAR = 180;
export const PREVIEW_SCALE = 0.5;
export const WIDGET_INFO: Record<WidgetId, { name: string; description: string }> = {
  cpu: { name: "CPU", description: "CPU load and its recent history." },
  memory: { name: "RAM", description: "Memory in use and how it splits." },
  network: { name: "Network", description: "Download and upload speeds." },
  disk: { name: "SSD", description: "Space used on the startup disk." },
  storage: {
    name: "Storage",
    description: "Used, free and purgeable space on every disk.",
  },
};
const COLUMN = { small: 124, wide: 200, gap: 11 };
const TILES_TOP = GALLERY.y + 52;

export type Tile = { column: Rect; preview: Rect };
export const galleryTiles = (): Record<WidgetId, Tile> => {
  let x = GALLERY.x + GALLERY_SIDEBAR + 20;
  const tiles = {} as Record<WidgetId, Tile>;
  for (const id of WIDGETS) {
    const full = WIDGET_SLOTS[id];
    const width = id === "storage" ? COLUMN.wide : COLUMN.small;
    const preview = { w: full.w * PREVIEW_SCALE, h: full.h * PREVIEW_SCALE };
    tiles[id] = {
      column: {
        x,
        y: TILES_TOP,
        w: width,
        h: GALLERY.y + GALLERY.h - TILES_TOP,
      },
      preview: { x: x + (width - preview.w) / 2, y: TILES_TOP, ...preview },
    };
    x += width + COLUMN.gap;
  }
  return tiles;
};
export const DONE_BUTTON: Rect = {
  x: GALLERY.x + GALLERY.w - 20 - 64,
  y: GALLERY.y + 13,
  w: 64,
  h: 26,
};

// MARK: - Desktop menu (reconstructed: the right-click menu of the macOS desktop)

export const RIGHT_CLICK: Point = { x: 700, y: 430 };
export const MENU_WIDTH = 214;
export const MENU_ROW = 24;
export const MENU_SEPARATOR = 11;
export const MENU_PADDING = 5;
export const MENU_ITEMS: (string | null)[] = [
  "New Folder",
  null,
  "Get Info",
  null,
  "Change Wallpaper…",
  "Edit Widgets…",
  null,
  "Use Stacks",
  "Sort By",
  "Clean Up",
  "Show View Options",
];
export const SUBMENU_ITEMS = new Set(["Sort By"]);

/** Rows of the desktop menu, in desktop points. */
export const menuRows = (): { label: string | null; rect: Rect }[] => {
  let y = RIGHT_CLICK.y + MENU_PADDING;
  return MENU_ITEMS.map((label) => {
    const h = label === null ? MENU_SEPARATOR : MENU_ROW;
    const row = {
      label,
      rect: {
        x: RIGHT_CLICK.x + MENU_PADDING,
        y,
        w: MENU_WIDTH - 2 * MENU_PADDING,
        h,
      },
    };
    y += h;
    return row;
  });
};
export const menuHeight = () =>
  MENU_ITEMS.reduce((sum, label) => sum + (label === null ? MENU_SEPARATOR : MENU_ROW), 2 * MENU_PADDING);
export const editWidgetsRow = () => {
  const row = menuRows().find((r) => r.label === "Edit Widgets…");
  if (!row) throw new Error("no Edit Widgets row");
  return row.rect;
};

export const withinRect = (p: Point, r: Rect) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
export const lerpRect = (a: Rect, b: Rect, t: number): Rect => ({
  x: a.x + (b.x - a.x) * t,
  y: a.y + (b.y - a.y) * t,
  w: a.w + (b.w - a.w) * t,
  h: a.h + (b.h - a.h) * t,
});

/** Times the popups are open, with the module shown. */
export const openPopup = (seconds: number) => T.popups.find((p) => seconds >= p.open && seconds < p.close) ?? null;
