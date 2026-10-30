import { describe, expect, it } from "vitest";
import { svgCode128 } from "./codigos";

describe("Code 128 del serial", () => {
  it("codifica la serie heredada de 10 dígitos", () => {
    const svg = svgCode128("23-1-000001-9");
    expect(svg).toContain("data:image/svg+xml");
    expect(svg!.length).toBeGreaterThan(100);
  });

  it("codifica la serie nueva de 11 dígitos cambiando al juego B", () => {
    const svg = svgCode128("23-1-0000001-9");
    expect(svg).toContain("data:image/svg+xml");
    expect(svg!.length).toBeGreaterThan(100);
  });

  it("no inventa barras para un serial vacío", () => {
    expect(svgCode128("")).toBeNull();
  });
});
