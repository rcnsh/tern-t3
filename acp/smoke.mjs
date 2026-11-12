// Drives t3-acp.mjs over stdio as Tern would: initialize, a new session, two
// prompts (the first starts a T3 thread, the second sends to it), list, and
// an unknown method. It starts a real T3 thread in the project at argv[3].
//
//   node acp/smoke.mjs acp/t3-acp.mjs ~/dev/tern-t3
import { spawn } from "node:child_process";
const p = spawn("node", [process.argv[2]], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "", id = 0; const waiting = new Map();
p.stdout.on("data", d => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { const line = buf.slice(0, i); buf = buf.slice(i + 1);
  const m = JSON.parse(line); if (m.id != null && waiting.has(m.id)) { waiting.get(m.id)(m); waiting.delete(m.id); } else console.log("<-", JSON.stringify(m).slice(0, 220)); } });
const req = (method, params) => new Promise(r => { const n = ++id; waiting.set(n, r); p.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: n, method, params }) + "\n"); });
const cwd = process.argv[3] || process.cwd();
console.log("init", JSON.stringify(await req("initialize", { protocolVersion: 1, clientCapabilities: {} })));
const s = (await req("session/new", { cwd, mcpServers: [] })).result; console.log("new", JSON.stringify(s));
const t0 = Date.now();
console.log("prompt1", JSON.stringify(await req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "t3-acp smoke test. Say 'first' in one short sentence, then run the shell command `sleep 3` and then say 'second' in a separate message. Nothing else." }] })), (Date.now()-t0)/1000);
console.log("prompt2", JSON.stringify(await req("session/prompt", { sessionId: s.sessionId, prompt: [{ type: "text", text: "Reply with just: ok" }] })));
const l = await req("session/list", { cwd }); console.log("list", JSON.stringify(l.result.sessions.slice(0, 2)));
console.log("bogus", JSON.stringify(await req("nope", {})));
p.stdin.end();
