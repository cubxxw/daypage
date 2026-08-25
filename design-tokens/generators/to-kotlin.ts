#!/usr/bin/env node
// Generates Compose-ready Kotlin tokens from tokens.json.
// Run: node --experimental-strip-types design-tokens/generators/to-kotlin.ts

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

type Tokens = {
  version: string;
  colors: Record<string, string>;
  fonts: Record<string, string>;
  fontSize: Record<string, number>;
  radii: Record<string, number>;
  shadows: Record<string, string>;
  elevation: Record<string, string>;
  spacing: Record<string, number>;
  motion: Record<string, string | number>;
  dark: {
    colors: Record<string, string>;
    elevation: Record<string, string>;
  };
};

const generatorDirectory = dirname(fileURLToPath(import.meta.url));
const root = join(generatorDirectory, "..", "..");
const tokensPath = join(root, "design-tokens", "tokens.json");
const kotlinPath = join(
  root,
  "design-tokens",
  "generated",
  "kotlin",
  "app",
  "daypage",
  "designsystem",
  "DayPageTokens.kt"
);

function camel(name: string): string {
  return name.replace(/-([a-z0-9])/gi, (_, character: string) => character.toUpperCase());
}

function colorLiteral(hex: string): string {
  return `Color(0xFF${hex.replace("#", "").toUpperCase()})`;
}

function dimensionLiteral(value: number, unit: "dp" | "sp"): string {
  return `${Number.isInteger(value) ? value : `${value}f`}.${unit}`;
}

function escapeKotlin(value: string): string {
  return JSON.stringify(value);
}

function buildKotlin(tokens: Tokens): string {
  const lines: string[] = [];
  lines.push(`// DayPageTokens.kt — DayPage v${tokens.version} design tokens.`);
  lines.push("// DO NOT EDIT by hand. Edit design-tokens/tokens.json and run `make tokens-build`.");
  lines.push("// Content semantics are shared; components still map these values to native Compose primitives.");
  lines.push("");
  lines.push("package app.daypage.designsystem");
  lines.push("");
  lines.push("import androidx.compose.animation.core.CubicBezierEasing");
  lines.push("import androidx.compose.ui.graphics.Color");
  lines.push("import androidx.compose.ui.unit.dp");
  lines.push("import androidx.compose.ui.unit.sp");
  lines.push("");
  lines.push("object DayPageTokens {");
  lines.push(`    const val version = ${escapeKotlin(tokens.version)}`);
  lines.push("");

  lines.push("    object LightColors {");
  for (const [name, value] of Object.entries(tokens.colors)) {
    lines.push(`        val ${camel(name)} = ${colorLiteral(value)}`);
  }
  lines.push("    }");
  lines.push("");

  lines.push("    object DarkColors {");
  for (const [name, lightValue] of Object.entries(tokens.colors)) {
    const value = tokens.dark.colors[name] ?? lightValue;
    lines.push(`        val ${camel(name)} = ${colorLiteral(value)}`);
  }
  lines.push("    }");
  lines.push("");

  lines.push("    object Fonts {");
  for (const [name, value] of Object.entries(tokens.fonts)) {
    lines.push(`        const val ${camel(name)} = ${escapeKotlin(value)}`);
  }
  lines.push("    }");
  lines.push("");

  lines.push("    object FontSize {");
  for (const [name, value] of Object.entries(tokens.fontSize)) {
    lines.push(`        val ${camel(name)} = ${dimensionLiteral(value, "sp")}`);
  }
  lines.push("    }");
  lines.push("");

  lines.push("    object Radii {");
  for (const [name, value] of Object.entries(tokens.radii)) {
    lines.push(`        val ${camel(name)} = ${dimensionLiteral(value, "dp")}`);
  }
  lines.push("    }");
  lines.push("");

  lines.push("    object Spacing {");
  for (const [name, value] of Object.entries(tokens.spacing)) {
    lines.push(`        val ${camel(name)} = ${dimensionLiteral(value, "dp")}`);
  }
  lines.push("    }");
  lines.push("");

  lines.push("    object Motion {");
  lines.push("        val spring = CubicBezierEasing(0.2f, 0.8f, 0.2f, 1.0f)");
  lines.push("        val easeOut = CubicBezierEasing(0.0f, 0.0f, 0.58f, 1.0f)");
  for (const [name, value] of Object.entries(tokens.motion)) {
    if (typeof value === "number") {
      lines.push(`        const val ${camel(name)}Millis = ${value}`);
    }
  }
  lines.push("    }");
  lines.push("");

  // CSS shadows are not portable effect objects. Keeping the references in
  // generated Kotlin prevents value drift while the Android design-system
  // module maps the three semantic levels to platform elevation primitives.
  lines.push("    object ElevationReference {");
  for (const [name, value] of Object.entries(tokens.elevation)) {
    lines.push(`        const val ${camel(name)} = ${escapeKotlin(value)}`);
  }
  for (const [name, value] of Object.entries(tokens.dark.elevation)) {
    lines.push(`        const val ${camel(name)}Dark = ${escapeKotlin(value)}`);
  }
  lines.push("    }");
  lines.push("}");
  lines.push("");
  return lines.join("\n");
}

function main() {
  const tokens: Tokens = JSON.parse(readFileSync(tokensPath, "utf8"));
  const kotlin = buildKotlin(tokens);
  let current = "";
  try {
    current = readFileSync(kotlinPath, "utf8");
  } catch {
    // First generation.
  }

  if (current === kotlin) {
    console.log(`[tokens] ${kotlinPath} already up to date`);
    return;
  }

  mkdirSync(dirname(kotlinPath), { recursive: true });
  writeFileSync(kotlinPath, kotlin);
  console.log(`[tokens] wrote ${kotlinPath}`);
}

main();
