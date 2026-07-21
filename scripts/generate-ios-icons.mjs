#!/usr/bin/env bun

import sharp from "sharp";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const IOS_ROOT = join(__dirname, "..", "packages", "ios-app");
const ASSETS = join(IOS_ROOT, "Sources", "Assets.xcassets");

const SOURCE_SVG = join(ASSETS, "TronLogoVector.imageset", "tron-logo.svg");
const ORIGINAL_FILL = "#000000";

const COLORS = {
  emerald: "#10B981",
  amber: "#D97706",
  white: "#FFFFFF",
};

const BG = {
  cream: "#F3EDE3",
};

function recolorSvg(fromColor, toColor) {
  const svg = readFileSync(SOURCE_SVG, "utf-8");
  return svg.replaceAll(fromColor, toColor);
}

async function generateAppIcon(svgString, bgColor, outputPath, size = 1024) {
  const logoSize = Math.round(size * 0.75);
  const offset = Math.round((size - logoSize) / 2);

  const logo = await sharp(Buffer.from(svgString))
    .resize(logoSize, logoSize, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();

  const r = parseInt(bgColor.slice(1, 3), 16);
  const g = parseInt(bgColor.slice(3, 5), 16);
  const b = parseInt(bgColor.slice(5, 7), 16);

  await sharp({
    create: { width: size, height: size, channels: 4, background: { r, g, b, alpha: 1 } },
  })
    .composite([{ input: logo, top: offset, left: offset }])
    .png()
    .toFile(outputPath);
}

async function generateRasterLogo(svgString, size, outputPath) {
  await sharp(Buffer.from(svgString))
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(outputPath);
}

async function verify(path, expectedWidth, expectedHeight, expectAlpha = false) {
  const meta = await sharp(path).metadata();
  const issues = [];
  if (meta.width !== expectedWidth) issues.push(`width: ${meta.width} != ${expectedWidth}`);
  if (meta.height !== expectedHeight) issues.push(`height: ${meta.height} != ${expectedHeight}`);
  if (meta.format !== "png") issues.push(`format: ${meta.format} != png`);
  if (expectAlpha && !meta.hasAlpha) issues.push("missing alpha channel");
  if (issues.length) {
    console.error(`  FAIL ${path}: ${issues.join(", ")}`);
    return false;
  }
  console.log(`  OK   ${path} (${meta.width}x${meta.height})`);
  return true;
}

async function main() {
  const whiteSvg = recolorSvg(ORIGINAL_FILL, COLORS.white);
  const emeraldSvg = recolorSvg(ORIGINAL_FILL, COLORS.emerald);

  console.log("Generating app icons...");

  // Production icon: emerald logo on cream (iOS auto-generates dark variant)
  const deepEmeraldSvg = recolorSvg(ORIGINAL_FILL, "#059669");
  await generateAppIcon(deepEmeraldSvg, BG.cream, join(ASSETS, "AppIcon.appiconset", "icon-1024.png"));

  // Beta icon: white logo on amber bg (iOS auto-generates dark/tinted)
  await generateAppIcon(whiteSvg, COLORS.amber, join(ASSETS, "AppIconBeta.appiconset", "icon-1024-beta.png"));

  console.log("Generating README logo preview...");

  const readmeLogo = join(IOS_ROOT, "docs", "assets", "tron-logo.png");
  await generateRasterLogo(emeraldSvg, 100, readmeLogo);

  console.log("\nVerifying outputs...");

  let allOk = true;
  const checks = [
    // App icons (1024x1024, no alpha needed)
    [join(ASSETS, "AppIcon.appiconset", "icon-1024.png"), 1024, 1024],
    [join(ASSETS, "AppIconBeta.appiconset", "icon-1024-beta.png"), 1024, 1024],
    // README preview (transparent)
    [readmeLogo, 100, 100, true],
  ];

  for (const [path, w, h, alpha] of checks) {
    const ok = await verify(path, w, h, alpha);
    if (!ok) allOk = false;
  }

  if (allOk) {
    console.log("\nAll 3 files generated and verified successfully.");
  } else {
    console.error("\nSome verifications failed!");
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
