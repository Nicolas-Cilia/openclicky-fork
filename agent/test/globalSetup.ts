/**
 * One temp folder for the whole run, removed at the end: the tests make throwaway Codex homes and
 * workspaces under os.tmpdir(), and spawned processes inherit the same folder.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export default function setup() {
  const original = { TMPDIR: process.env.TMPDIR, TEMP: process.env.TEMP, TMP: process.env.TMP };
  const folder = fs.mkdtempSync(path.join(os.tmpdir(), "openclicky-agent-tests-"));
  process.env.TMPDIR = process.env.TEMP = process.env.TMP = folder;
  return () => {
    for (const [key, value] of Object.entries(original)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    fs.rmSync(folder, { recursive: true, force: true, maxRetries: 3 });
  };
}
