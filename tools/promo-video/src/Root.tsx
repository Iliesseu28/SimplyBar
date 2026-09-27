import React from "react";
import { Composition, staticFile } from "remotion";
import { Manifest } from "./layout";
import { Promo, PromoProps } from "./Promo";
import { DURATION, FPS } from "./timeline";

export const RemotionRoot: React.FC = () => (
  <Composition
    id="SimplyBarPromo"
    component={Promo}
    durationInFrames={Math.round(DURATION * FPS)}
    fps={FPS}
    width={1920}
    height={1080}
    defaultProps={{ manifest: null } as PromoProps}
    calculateMetadata={async () => {
      // Sizes of the app's images, written by tools/screenshots/make.sh --video.
      const response = await fetch(staticFile("app/video-assets.json"));
      if (!response.ok) throw new Error("public/app/video-assets.json is missing: run scripts/render.sh");
      return { props: { manifest: (await response.json()) as Manifest } };
    }}
  />
);
