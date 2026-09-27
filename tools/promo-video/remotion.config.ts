// Options of `npx remotion render` and of the Studio. scripts/render.sh passes the rest on the command line.
import { Config } from "@remotion/cli/config";

Config.setVideoImageFormat("png");
Config.setOverwriteOutput(true);
// Tag the frames as BT.709 (HD): untagged, ffmpeg reads them as BT.601 and the colours of the MP4 shift.
Config.setColorSpace("bt709");
