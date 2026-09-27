// When things happen, in seconds from the start. The voice lines set the pace: each action lands on the words
// that name it (word times measured on the recordings of public/voice).
import voice from "./voice.json";

export const FPS = 30;
export const DURATION = 29;
export const frame = (seconds: number) => Math.round(seconds * FPS);

export type LineId = keyof typeof voice;

/** Start of each voice line. */
export const VOICE: Record<LineId, number> = {
  intro: 0.25,
  settings: 4.65,
  click: 8.9,
  live: 11.2,
  widgets: 14.6,
  drag: 18.5,
  outro: 24.7,
};
export const voiceEnd = (id: LineId) => VOICE[id] + voice[id];

// A new take of a line (scripts/voice.py --force) may be longer: fail loudly rather than play two lines at once.
(Object.keys(VOICE) as LineId[]).forEach((id, index, ids) => {
  const next = ids[index + 1];
  const limit = next ? VOICE[next] : DURATION;
  if (voiceEnd(id) > limit) {
    throw new Error(`Voice line "${id}" ends at ${voiceEnd(id).toFixed(2)} s, after ${next ?? "the end"} (${limit} s)`);
  }
});

/** Subtitles: one page per sentence, the long ones cut where the voice breathes (seconds into the line). */
export const SUBTITLES: { line: LineId; at: number; text: string }[] = [
  { line: "intro", at: 0, text: "Meet SimplyBar, a free system monitor" },
  { line: "intro", at: 2.66, text: "for your Mac’s menu bar." },
  {
    line: "settings",
    at: 0,
    text: "Open the settings and switch on the modules you want.",
  },
  { line: "click", at: 0, text: "Click any item to see the details." },
  { line: "live", at: 0, text: "Everything updates in real time." },
  { line: "widgets", at: 0, text: "To add widgets, right-click the desktop" },
  { line: "widgets", at: 1.96, text: "and choose Edit Widgets." },
  {
    line: "drag",
    at: 0,
    text: "Drag them in: CPU, memory, network, SSD and storage.",
  },
  {
    line: "outro",
    at: 0,
    text: "SimplyBar. Free and open source, on the Mac App Store.",
  },
];

export const MODULES = ["cpu", "memory", "network", "disk"] as const;
export type ModuleId = (typeof MODULES)[number];

export const T = {
  windowOpen: 1.4,
  /** Sidebar clicks in the settings window (the CPU row is selected when it opens). */
  rows: { memory: 5.5, network: 6.7, disk: 7.9 } as Record<Exclude<ModuleId, "cpu">, number>,
  /** Clicks on "Show in menu bar": the item appears in the menu bar. */
  switches: { cpu: 4.7, memory: 5.95, network: 7.15, disk: 8.35 } as Record<ModuleId, number>,
  windowClose: 8.85,
  /** Clicks on the menu bar items: each opens its popup and closes the previous one. */
  popups: [
    { module: "cpu", open: 9.5, close: 10.9 },
    { module: "memory", open: 10.9, close: 12.2 },
    { module: "network", open: 12.2, close: 13.4 },
    { module: "disk", open: 13.4, close: 14.4 },
    { module: "cpu", open: 23.6, close: 99 },
  ] as { module: ModuleId; open: number; close: number }[],
  rightClick: 15.65,
  editWidgets: 17.3,
  galleryOpen: 17.52,
  dragCpu: { press: 18.85, drop: 19.4 },
  /** Clicks on a widget of the gallery: it goes to the next free place on the desktop. */
  add: { memory: 20.2, network: 20.84, disk: 21.44 },
  dragStorage: { press: 21.78, drop: 22.3 },
  done: 23.0,
  endCard: 24.6,
  /** A new menu bar reading every half second (the app itself reads every 2 seconds at the fastest). */
  update: 0.5,
};
