// Renders Design/AppIcon*.svg into the asset catalog: the app icon at 1024 px without alpha
// (the App Store refuses alpha) and the welcome screen's AppLogo at 360 px.
// Needs sharp: `npm install sharp` here, or run with NODE_PATH pointing at a project that has it.
import { readFileSync } from "node:fs";
import sharp from "sharp";

const jobs = [
  ["Design/AppIcon.svg", "App/OwnAudioBooks/Assets.xcassets/AppIcon.appiconset/AppIcon.png", 1024],
  ["Design/AppIcon-dark.svg", "App/OwnAudioBooks/Assets.xcassets/AppIcon.appiconset/AppIcon-dark.png", 1024],
  ["Design/AppIcon.svg", "App/OwnAudioBooks/Assets.xcassets/AppLogo.imageset/AppLogo.png", 360],
  ["Design/AppIcon-dark.svg", "App/OwnAudioBooks/Assets.xcassets/AppLogo.imageset/AppLogo-dark.png", 360],
];
for (const [source, target, px] of jobs) {
  await sharp(Buffer.from(readFileSync(source)), { density: 600 }).resize(px, px).flatten().png().toFile(target);
  console.log(`${target} ${px}px`);
}
