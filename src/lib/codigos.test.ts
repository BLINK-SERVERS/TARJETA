import { describe, expect, it } from "vitest";
import { svgCode128 } from "./codigos";

describe("Code 128 del serial", () => {
  it("codifica el serial alfanumérico compacto", () => {
    const svg = svgCode128("G00001001N");
    expect(svg).toContain("data:image/svg+xml");
    expect(svg!.length).toBeGreaterThan(100);
  });

  it("ignora guiones y mayúsculas: el Code 128 lleva el serial compacto", () => {
    expect(svgCode128("G-00001-001-N")).toBe(svgCode128("G00001001N"));
    expect(svgCode128("g-00001-001-n")).toBe(svgCode128("G00001001N"));
  });

  it("no inventa barras para un serial vacío", () => {
    expect(svgCode128("")).toBeNull();
    expect(svgCode128("---")).toBeNull();
  });
});
