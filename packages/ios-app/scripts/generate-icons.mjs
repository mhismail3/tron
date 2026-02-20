#!/usr/bin/env bun

import sharp from "sharp";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const IOS_ROOT = join(__dirname, "..");
const ASSETS = join(IOS_ROOT, "Sources", "Assets.xcassets");
const ICON_LAYERS = join(IOS_ROOT, "Sources", "IconLayers");

const SOURCE_SVG = "/Users/moose/Downloads/mhismail3.svg";
const ORIGINAL_FILL = "#3d7f4d";

const COLORS = {
  emerald: "#10B981",
  amber: "#D97706",
  gray: "#808080",
  black: "#000000",
  white: "#FFFFFF",
};

const BG = {
  dark: "#090909",
  white: "#FFFFFF",
};

function recolorSvg(fromColor, toColor) {
  const svg = readFileSync(SOURCE_SVG, "utf-8");
  return svg.replaceAll(fromColor, toColor);
}

async function generateAppIcon(svgString, bgColor, outputPath, size = 1024) {
  const mooseSize = Math.round(size * 0.75);
  const offset = Math.round((size - mooseSize) / 2);

  const moose = await sharp(Buffer.from(svgString))
    .resize(mooseSize, mooseSize, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();

  const r = parseInt(bgColor.slice(1, 3), 16);
  const g = parseInt(bgColor.slice(3, 5), 16);
  const b = parseInt(bgColor.slice(5, 7), 16);

  await sharp({
    create: { width: size, height: size, channels: 4, background: { r, g, b, alpha: 1 } },
  })
    .composite([{ input: moose, top: offset, left: offset }])
    .png()
    .toFile(outputPath);
}

async function generateRasterLogo(svgString, size, outputPath) {
  await sharp(Buffer.from(svgString))
    .resize(size, size, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toFile(outputPath);
}

function generateTemplateSvg(outputPath) {
  let svg = readFileSync(SOURCE_SVG, "utf-8");
  // Strip the Adobe Illustrator comment
  svg = svg.replace(/\s*<!--.*?-->\s*/s, "\n  ");
  // Recolor to black for template rendering
  svg = svg.replaceAll(ORIGINAL_FILL, COLORS.black);
  writeFileSync(outputPath, svg);
}

async function generateDepthLayer(svgString, size, outputPath) {
  const mooseSize = Math.round(size * 0.7);

  await sharp(Buffer.from(svgString))
    .resize(mooseSize, mooseSize, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .extend({
      top: Math.round((size - mooseSize) / 2),
      bottom: size - mooseSize - Math.round((size - mooseSize) / 2),
      left: Math.round((size - mooseSize) / 2),
      right: size - mooseSize - Math.round((size - mooseSize) / 2),
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    })
    .png()
    .toFile(outputPath);
}

async function generateSolidBackground(color, size, outputPath) {
  const r = parseInt(color.slice(1, 3), 16);
  const g = parseInt(color.slice(3, 5), 16);
  const b = parseInt(color.slice(5, 7), 16);

  await sharp({
    create: { width: size, height: size, channels: 4, background: { r, g, b, alpha: 1 } },
  })
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
  mkdirSync(ICON_LAYERS, { recursive: true });

  const whiteSvg = recolorSvg(ORIGINAL_FILL, COLORS.white);
  const emeraldSvg = recolorSvg(ORIGINAL_FILL, COLORS.emerald);
  const amberSvg = recolorSvg(ORIGINAL_FILL, COLORS.amber);
  const graySvg = recolorSvg(ORIGINAL_FILL, COLORS.gray);

  console.log("Generating app icons...");

  // Production icon: white moose on emerald bg (iOS auto-generates dark/tinted)
  await generateAppIcon(whiteSvg, COLORS.emerald, join(ASSETS, "AppIcon.appiconset", "icon-1024.png"));

  // Beta icon: white moose on amber bg (iOS auto-generates dark/tinted)
  await generateAppIcon(whiteSvg, COLORS.amber, join(ASSETS, "AppIconBeta.appiconset", "icon-1024-beta.png"));

  console.log("Generating in-app raster logos...");

  const logoDir = join(ASSETS, "TronLogo.imageset");
  await generateRasterLogo(emeraldSvg, 100, join(logoDir, "tron-logo.png"));
  await generateRasterLogo(emeraldSvg, 200, join(logoDir, "tron-logo@2x.png"));
  await generateRasterLogo(emeraldSvg, 300, join(logoDir, "tron-logo@3x.png"));

  console.log("Generating template SVG...");

  generateTemplateSvg(join(ASSETS, "TronLogoVector.imageset", "tron-logo.svg"));

  console.log("Generating depth layers...");

  await generateDepthLayer(emeraldSvg, 1024, join(ICON_LAYERS, "foreground-emerald.png"));
  await generateDepthLayer(amberSvg, 1024, join(ICON_LAYERS, "foreground-amber.png"));
  await generateDepthLayer(graySvg, 1024, join(ICON_LAYERS, "foreground-gray.png"));
  await generateSolidBackground(BG.dark, 1024, join(ICON_LAYERS, "background-dark.png"));
  await generateSolidBackground(BG.white, 1024, join(ICON_LAYERS, "background-white.png"));

  console.log("\nVerifying outputs...");

  let allOk = true;
  const checks = [
    // App icons (1024x1024, no alpha needed)
    [join(ASSETS, "AppIcon.appiconset", "icon-1024.png"), 1024, 1024],
    [join(ASSETS, "AppIconBeta.appiconset", "icon-1024-beta.png"), 1024, 1024],
    // In-app logos (transparent)
    [join(logoDir, "tron-logo.png"), 100, 100, true],
    [join(logoDir, "tron-logo@2x.png"), 200, 200, true],
    [join(logoDir, "tron-logo@3x.png"), 300, 300, true],
    // Depth layers (transparent foregrounds)
    [join(ICON_LAYERS, "foreground-emerald.png"), 1024, 1024, true],
    [join(ICON_LAYERS, "foreground-amber.png"), 1024, 1024, true],
    [join(ICON_LAYERS, "foreground-gray.png"), 1024, 1024, true],
    [join(ICON_LAYERS, "background-dark.png"), 1024, 1024],
    [join(ICON_LAYERS, "background-white.png"), 1024, 1024],
  ];

  for (const [path, w, h, alpha] of checks) {
    const ok = await verify(path, w, h, alpha);
    if (!ok) allOk = false;
  }

  if (allOk) {
    console.log("\nAll 11 files generated and verified successfully.");
  } else {
    console.error("\nSome verifications failed!");
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
