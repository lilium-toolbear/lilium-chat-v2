import { describe, expect, it } from "vitest";
import { captureForDiff, diffCaptures, diffValues } from "../src/diff.js";

describe("diffValues", () => {
  it("returns no entries for identical values", () => {
    expect(diffValues({ a: [1, { b: "x" }], c: null }, { a: [1, { b: "x" }], c: null })).toEqual([]);
  });

  it("reports scalar mismatches with a path", () => {
    const diffs = diffValues({ a: { b: 1 } }, { a: { b: 2 } });
    expect(diffs).toEqual([{ path: "$.a.b", left: 1, right: 2 }]);
  });

  it("reports keys missing on one side", () => {
    const diffs = diffValues({ a: 1, gone: "x" }, { a: 1 });
    expect(diffs).toHaveLength(1);
    expect(diffs[0]!.path).toBe("$.gone");
    expect(diffs[0]!.left).toBe("x");
    expect(diffs[0]!.right).toBeUndefined();
  });

  it("reports array length mismatches element-wise", () => {
    const diffs = diffValues({ list: [1, 2, 3] }, { list: [1, 2] });
    expect(diffs).toEqual([{ path: "$.list[2]", left: 3, right: undefined }]);
  });

  it("reports type mismatches", () => {
    const diffs = diffValues({ v: "1" }, { v: 1 });
    expect(diffs).toEqual([{ path: "$.v", left: "1", right: 1 }]);
  });

  it("handles nested arrays of objects", () => {
    const diffs = diffValues(
      { steps: [{ wsReceived: [{ type: "event" }] }] },
      { steps: [{ wsReceived: [{ type: "other" }] }] },
    );
    expect(diffs).toEqual([{ path: "$.steps[0].wsReceived[0].type", left: "event", right: "other" }]);
  });
});

describe("diffCaptures", () => {
  it("caps the entry count for fully divergent captures", () => {
    const big = Array.from({ length: 1000 }, (_, i) => ({ i, v: i }));
    const other = big.map((x) => ({ ...x, v: x.v + 1 }));
    const { diffs, truncated } = diffCaptures({ items: big }, { items: other });
    expect(truncated).toBe(true);
    expect(diffs.length).toBeLessThanOrEqual(500);
  });
});

describe("captureForDiff", () => {
  it("strips per-target readObservation but keeps wire payload", () => {
    const capture = {
      scenario: "s",
      target: "t",
      steps: [
        { index: 0, kind: "http", readObservation: { ok: true, hiddenWrites: [] }, http: { response: { status: 200 } } },
        { index: 1, kind: "ws.event", wsReceived: [{ type: "message.created" }] },
      ],
    };
    const out = captureForDiff(capture) as { steps: Array<Record<string, unknown>> };
    expect(out).not.toHaveProperty("target");
    expect(out.steps[0]).not.toHaveProperty("readObservation");
    expect(out.steps[0]).toHaveProperty("http");
    expect(out.steps[1]).toEqual({ index: 1, kind: "ws.event", wsReceived: [{ type: "message.created" }] });
  });
});
