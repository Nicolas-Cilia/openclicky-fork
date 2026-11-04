import { describe, it, expect, beforeAll, afterAll } from "vitest";
import http from "node:http";
import { gate, parseGateReply, heuristicLane } from "../src/gate.js";
import { resolveConfig } from "../src/config.js";

let server: http.Server;
let url: string;
let mode: "ok" | "garbage" | "fail" = "ok";
const seen: any[] = [];

beforeAll(async () => {
  server = http.createServer((req, res) => {
    let b = "";
    req.on("data", (d) => (b += d));
    req.on("end", () => {
      seen.push({ url: req.url, auth: req.headers.authorization, body: JSON.parse(b) });
      if (mode === "fail") return void res.writeHead(502, { "content-type": "application/json" }).end('{"error":"no key"}');
      const text = mode === "garbage" ? "I cannot decide" : 'Sure. {"lane":"ask","reason":"it is a question"}';
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ role: "assistant", content: [{ type: "text", text }] }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  url = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
});
afterAll(() => server.close());

describe("gate", () => {
  it("parses lenient JSON replies", () => {
    expect(parseGateReply('{"lane":"agent","reason":"x"}')).toEqual({ lane: "agent", reason: "x" });
    expect(parseGateReply('Answer:\n{"lane":"ask"}')).toEqual({ lane: "ask", reason: "" });
    expect(parseGateReply('{"lane":"maybe"}')).toBeUndefined();
    expect(parseGateReply("nope")).toBeUndefined();
  });
  it("heuristic sends questions to the ask lane, even ones about doing work", () => {
    for (const question of [
      "what does this error mean: ENOENT",
      "how do I fix my repo",
      "how do I turn this shape into a circle",
      "How can I make a folder?",
      "can I add a border to this?",
      "hey clicky, how do I remove the background",
      "okay so where do I run this",
      "turn this shape into a circle",
      "do the thing",
    ]) expect(heuristicLane(question), question).toBe("ask");
  });
  it("heuristic sends a request that opens with the work to an agent", () => {
    for (const request of [
      "create a file called hello.txt",
      "fix my repo",
      "Please write a report on this",
      "can you make a folder on my desktop",
      "hey clicky, could you draft an email to Sam",
      "okay, go ahead and run the tests",
    ]) expect(heuristicLane(request), request).toBe("agent");
  });
  it("calls /v1/messages on the own key and returns the model's lane", async () => {
    mode = "ok";
    const d = await gate(resolveConfig({ anthropicBaseUrl: url, anthropicApiKey: "t" }), "create a file called hello.txt");
    expect(d).toEqual({ lane: "ask", reason: "it is a question", gated: true });
    const last = seen.at(-1);
    expect(last.url).toBe("/v1/messages");
    expect(last.body.model).toBe("claude-haiku-4-5-20251001");
    expect(last.body.system).toContain("launch gate");
  });
  it("falls back to the heuristic when the gate is unavailable or unparseable", async () => {
    mode = "fail";
    const a = await gate(resolveConfig({ anthropicBaseUrl: url, anthropicApiKey: "t" }), "create a file");
    expect(a.gated).toBe(false);
    expect(a.lane).toBe("agent");
    mode = "garbage";
    const b = await gate(resolveConfig({ anthropicBaseUrl: url, anthropicApiKey: "t" }), "what is a monad");
    expect(b).toMatchObject({ gated: false, lane: "ask" });
    const c = await gate(resolveConfig({ anthropicBaseUrl: "http://127.0.0.1:1", anthropicApiKey: "t" }), "what is a monad");
    expect(c.gated).toBe(false);
  });
});
