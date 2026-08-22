import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const skillDirectory = join(import.meta.dir, "..");
const fixture = join(import.meta.dir, "interactive-fixture.json");
const renderer = join(skillDirectory, "scripts", "render_report.py");
let temporaryDirectory = "";
let inlineScript = "";

beforeAll(() => {
  temporaryDirectory = mkdtempSync(join(tmpdir(), "render-html-copy-"));
  const output = join(temporaryDirectory, "report.html");
  const result = Bun.spawnSync([
    "python3",
    renderer,
    "--input",
    fixture,
    "--output",
    output,
  ]);
  expect(result.exitCode).toBe(0);
  const rendered = readFileSync(output, "utf8");
  const scriptMatch = rendered.match(/<script>([\s\S]*?)<\/script>/);
  expect(scriptMatch).not.toBeNull();
  inlineScript = scriptMatch?.[1] ?? "";
});

afterAll(() => {
  rmSync(temporaryDirectory, { force: true, recursive: true });
});

async function runCopy({
  legacyResult,
  modernClipboard,
}: {
  legacyResult: boolean | Error;
  modernClipboard?: { writeText: (value: string) => Promise<void> };
}) {
  const status = { textContent: "" };
  let handler: (() => Promise<void>) | undefined;
  let legacyCalls = 0;
  let removed = false;
  const copy = {
    dataset: { copyPrompt: "Continue the review." },
    parentElement: { querySelector: () => status },
    addEventListener: (_event: string, callback: () => Promise<void>) => {
      handler = callback;
    },
  };
  const area = {
    value: "",
    style: { position: "", opacity: "" },
    setAttribute: () => undefined,
    select: () => undefined,
    remove: () => {
      removed = true;
    },
  };
  const documentStub = {
    body: { appendChild: () => undefined },
    createElement: () => area,
    execCommand: () => {
      legacyCalls += 1;
      if (legacyResult instanceof Error) throw legacyResult;
      return legacyResult;
    },
    querySelectorAll: (selector: string) => {
      if (selector === "[data-copy-prompt]") return [copy];
      return [];
    },
  };
  const navigatorStub = modernClipboard
    ? { clipboard: modernClipboard }
    : { clipboard: undefined };

  new Function("document", "navigator", inlineScript)(
    documentStub,
    navigatorStub,
  );
  expect(handler).toBeDefined();
  await handler?.();
  return { legacyCalls, removed, status: status.textContent };
}

describe("copy discussion prompt", () => {
  test("uses the modern clipboard and reports success", async () => {
    let copiedValue = "";
    const result = await runCopy({
      legacyResult: false,
      modernClipboard: {
        writeText: async (value) => {
          copiedValue = value;
        },
      },
    });

    expect(copiedValue).toBe("Continue the review.");
    expect(result).toEqual({ legacyCalls: 0, removed: false, status: "Copied" });
  });

  test.each([
    ["false", false, "Copy failed"],
    ["a thrown error", new Error("copy blocked"), "Copy failed"],
    ["true", true, "Copied"],
  ])("reports the legacy command result for %s", async (_label, legacyResult, status) => {
    const result = await runCopy({ legacyResult });

    expect(result).toEqual({ legacyCalls: 1, removed: true, status });
  });
});
