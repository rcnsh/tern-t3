#!/usr/bin/env node
// An Agent Client Protocol (ACP) agent backed by T3 Code, so T3 Code threads
// run in Tern's agent chat. Tern starts it as a custom agent
// (`agents.custom` in Tern's settings.json) and talks JSON-RPC over stdio.
//
// Each ACP session is one T3 thread. The first prompt starts the thread
// (`t3 thread start`), later ones send to it (`t3 thread send`), and the
// agent's replies come from polling `t3 thread show`. The CLI reports whole
// messages, so a reply shows up a message at a time, not a word at a time.
//
// Needs Node 22 or newer and the T3 Code desktop app (which installs `t3`).

import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import * as catalog from "./catalog.mjs";

const VERSION = "0.1.0";
const PROTOCOL_VERSION = 1;
const POLL_MS = 1000;
const T3_TIMEOUT_MS = 30_000;
// `thread start|send` wait for T3 to set the run up; give up on them later so a
// slow start isn't killed after T3 has made the thread.
const T3_START_TIMEOUT_MS = 180_000;
// How long `thread show` may keep failing before a turn gives up following.
const FOLLOW_GIVE_UP_MS = 60_000;
// How many messages past those already shown one poll reads; `follow` reads
// more when a run outgrows it.
const POLL_MESSAGES = 60;
const REPLAY_MESSAGES = 200;

const ENDED = new Set(["completed", "failed", "interrupted", "cancelled"]);

const HOME = homedir();
const T3_HOME = process.env.T3CODE_HOME || join(HOME, ".t3");

// Sessions this agent started before their thread existed, by session id:
// `session/new` comes before the first message, and `t3 thread start` needs
// one. Kept on disk so Tern can resume and load them later.
const STATE_FILE = join(
  process.env.XDG_STATE_HOME || join(HOME, ".local", "state"),
  "tern-t3",
  "acp-sessions.json",
);

function log(...args) {
  process.stderr.write(`t3-acp: ${args.join(" ")}\n`);
}

// ---------------------------------------------------------------------------
// t3 CLI
// ---------------------------------------------------------------------------

// `t3` by name first, then where the desktop app and Homebrew put it: Tern
// may start agents with a PATH that lacks those directories.
function t3Candidates() {
  return ["t3", join(T3_HOME, "bin", "t3"), "/opt/homebrew/bin/t3", "/usr/local/bin/t3"];
}

class T3Error extends Error {
  constructor(message, { timedOut = false } = {}) {
    super(message);
    this.timedOut = timedOut;
  }
}

function runOnce(bin, args, { cwd, stdin, timeout = T3_TIMEOUT_MS }) {
  return new Promise((resolve, reject) => {
    const child = execFile(
      bin,
      args,
      { cwd, timeout, maxBuffer: 64 * 1024 * 1024, env: { ...process.env, NO_COLOR: "1" } },
      (err, stdout, stderr) => {
        if (err && err.code === "ENOENT") {
          reject(err);
          return;
        }
        if (err) {
          const why = (stderr || stdout || "").trim().split("\n").slice(0, 4).join("\n");
          reject(new T3Error(why || (err.killed ? `t3 did not answer within ${timeout / 1000} seconds.` : err.message), { timedOut: !!err.killed }));
          return;
        }
        resolve(stdout);
      },
    );
    if (stdin !== undefined) {
      // t3 may exit before reading a long message; its exit status reports why.
      child.stdin.on("error", () => {});
      child.stdin.end(stdin);
    }
  });
}

let t3Bin = null;

async function t3(args, opts = {}) {
  // A missing folder fails the spawn with the same ENOENT as a missing t3.
  if (opts.cwd && !existsSync(opts.cwd)) throw new T3Error(`The folder ${opts.cwd} no longer exists.`);
  if (t3Bin) return runOnce(t3Bin, args, opts);
  for (const bin of t3Candidates()) {
    if (bin !== "t3" && !existsSync(bin)) continue;
    try {
      const out = await runOnce(bin, args, opts);
      t3Bin = bin;
      return out;
    } catch (err) {
      if (err.code !== "ENOENT") {
        t3Bin = bin;
        throw err;
      }
    }
  }
  throw new T3Error("t3 isn't installed. Install the T3 Code desktop app, which adds it.");
}

async function t3Json(args, opts) {
  return JSON.parse(await t3([...args, "--json"], opts));
}

// This machine's T3 Code environment id, for app links.
function localEnvironment() {
  try {
    return readFileSync(join(T3_HOME, "userdata", "environment-id"), "utf8").trim() || null;
  } catch {
    return null;
  }
}

function appLink(threadId) {
  const env = localEnvironment();
  return env ? `t3code://threads/${env}/${encodeURIComponent(threadId)}` : null;
}

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

function loadState() {
  try {
    const data = JSON.parse(readFileSync(STATE_FILE, "utf8"));
    return data && typeof data === "object" ? data : {};
  } catch {
    return {};
  }
}

function saveState(state) {
  try {
    mkdirSync(dirname(STATE_FILE), { recursive: true });
    const tmp = `${STATE_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, JSON.stringify(state, null, 2));
    renameSync(tmp, STATE_FILE);
  } catch (err) {
    log("couldn't save sessions:", err.message);
  }
}

// The thread a session id names: one this agent mapped, else the id itself
// (sessions Tern lists come straight from T3's thread ids).
function threadFor(sessionId) {
  const saved = loadState()[sessionId];
  if (saved) return saved.threadId;
  return sessionId.startsWith("t3-new-") ? null : sessionId;
}

function remember(sessionId, threadId, cwd) {
  const state = loadState();
  state[sessionId] = { threadId, cwd };
  saveState(state);
}

function forget(sessionId) {
  const state = loadState();
  if (state[sessionId]) {
    delete state[sessionId];
    saveState(state);
  }
}

/**
 * A chat session. Before its thread starts, `project` and `model` hold what
 * the user picked (`model` null: T3 Code's default); once it has started,
 * `fixed` holds the thread's own project and model, which the CLI can't change.
 * @typedef {{cancelled: boolean, whenCancelled: Promise<symbol>, cancel: () => void}} Turn
 * @typedef {{
 *   cwd: string, threadId: string | null, turn: Turn | null,
 *   project: string | null, model: string | null,
 *   fixed: {projectId: string | null, model: string | null} | null,
 * }} Session
 * @type {Map<string, Session>}
 */
const sessions = new Map();

// A session's first-message start. It outlives the turn that began it (Esc
// stops the waiting, not the start) and the Session object (a chat closed and
// resumed meanwhile), so the next message waits for it rather than starting
// a second thread. `done` settles to the thread T3 made or the reason it
// didn't; whichever turn sees a failure first reports it (`reported`).
/**
 * @typedef {{
 *   picks: {cwd: string, project: string | null, model: string | null},
 *   done: Promise<{started?: any, err?: Error}>, settled: boolean, reported: boolean,
 * }} Start
 * @type {Map<string, Start>} by session id; a failed start stays until reported
 */
const starting = new Map();

function newTurn() {
  let wake;
  const turn = {
    cancelled: false,
    whenCancelled: new Promise((r) => (wake = r)),
    cancel() {
      turn.cancelled = true;
      wake(CANCELLED);
    },
  };
  return turn;
}

function newSession(sessionId, cwd, threadId) {
  // A start on its way carries the picks it was made with. Otherwise the
  // folder's project, else the most recent one, which the chat shows so it
  // can be changed before the first message.
  const picks = starting.get(sessionId)?.picks;
  if (picks) return { cwd, threadId, turn: null, project: picks.project, model: picks.model, fixed: null };
  const list = catalog.projects(T3_HOME);
  const project = catalog.projectFor(list, cwd) || list[0];
  return { cwd, threadId, turn: null, project: project?.id ?? null, model: null, fixed: null };
}

const CANCELLED = Symbol("cancelled");

// Starts a session's thread; see `starting`. The thread is recorded the
// moment T3 makes it, on the Session that asked and on whichever one now
// holds the id.
function beginStart(sessionId, s, text) {
  const entry = { picks: { cwd: s.cwd, project: s.project, model: s.model }, reported: false, settled: false, done: null };
  entry.done = startThread(s, text).then(
    (started) => {
      entry.settled = true;
      if (starting.get(sessionId) !== entry) return { started }; // the chat was deleted
      starting.delete(sessionId);
      remember(sessionId, started.threadId, entry.picks.cwd);
      const now = sessions.get(sessionId);
      for (const x of new Set([s, now].filter(Boolean))) {
        x.threadId = started.threadId;
        x.fixed = { projectId: started.projectId || entry.picks.project, model: entry.picks.model };
      }
      describeThread(sessionId, started.threadId);
      return { started };
    },
    (err) => {
      entry.settled = true;
      return { err };
    },
  );
  starting.set(sessionId, entry);
  return entry;
}

// Shows a new thread's actual project and model on its chips: T3 may pick a
// model other than the chip's default (a project default, a usage-limit
// fallback). Runs alongside the turn, which needn't wait for it.
async function describeThread(sessionId, threadId) {
  try {
    const s = sessions.get(sessionId);
    if (!s) return;
    fix(s, (await t3Json(["thread", "show", threadId, "--messages", "0"], { cwd: workdir(s) })).thread || {});
    if (sessions.get(sessionId) === s) {
      update(sessionId, { sessionUpdate: "config_option_update", configOptions: configOptions(s) });
    }
    const link = appLink(threadId);
    if (link) log("started", threadId, link);
  } catch (err) {
    log("show after start failed:", err.message);
  }
}

// Fills in a started session's project and model from its thread.
function fix(s, thread) {
  s.fixed = {
    projectId: thread.projectId || null,
    model: thread.providerInstanceId && thread.model ? `${thread.providerInstanceId}/${thread.model}` : null,
  };
}

// Where `t3` runs for a session: its folder while that exists, else its
// project's root.
function workdir(s) {
  if (existsSync(s.cwd)) return s.cwd;
  const id = s.fixed?.projectId || s.project;
  return catalog.projects(T3_HOME).find((p) => p.id === id)?.root || s.cwd;
}

// Where to run `t3 thread show` for a thread whose project isn't known yet:
// show takes a thread id, so any folder does once the chat's is gone.
function showDir(cwd) {
  return existsSync(cwd) ? cwd : HOME;
}

// Starts the session's thread with `text`. In the chat's own folder when it
// lies in the picked project (so T3 sees that folder), else by project id.
async function startThread(s, text) {
  const list = catalog.projects(T3_HOME);
  const here = existsSync(s.cwd) ? catalog.projectFor(list, s.cwd) : null;
  const picked = list.find((p) => p.id === s.project);
  if (!picked && !here) {
    throw new T3Error("Pick a T3 Code project for this chat; this folder isn't in one. Add one in T3 Code first.");
  }
  const target = here && (!picked || picked.id === here.id) ? s.cwd : picked.id;
  const args = ["thread", "start", target, "-"];
  const model = s.model && catalog.splitModel(s.model);
  if (model) args.push("--provider", model.instance, "--model", model.slug);
  return t3Json(args, { cwd: target === s.cwd ? s.cwd : picked.root, stdin: text, timeout: T3_START_TIMEOUT_MS });
}

// ---------------------------------------------------------------------------
// Session config: project and model
// ---------------------------------------------------------------------------

const UNKNOWN = "unknown";
// T3 Code's own pick, when it has no default model the chip can name.
const DEFAULT = "default";

// The model picker: every model grouped by provider, with `value` (an
// `instance/slug`, or UNKNOWN) among them. A value the lists lack, such as a
// retired model an older thread runs on, joins its provider's group.
function modelOption(value) {
  const groups = catalog.models(T3_HOME).map((g) => ({
    group: g.instance,
    name: g.name,
    options: g.models.map((m) => ({ value: `${g.instance}/${m.slug}`, name: m.name })),
  }));
  if (!groups.some((g) => g.options.some((o) => o.value === value))) {
    const parts = catalog.splitModel(value);
    const option = { value, name: parts?.slug || (value === DEFAULT ? "T3 Code's default" : "Unknown model") };
    const home = groups.find((g) => g.group === (parts?.instance || UNKNOWN));
    if (home) home.options.unshift(option);
    else groups.unshift({ group: parts?.instance || UNKNOWN, name: parts?.instance || "T3 Code", options: [option] });
  }
  return { id: "model", name: "Model", category: "model", type: "select", currentValue: value, options: groups };
}

// The project picker. ACP has no project category, and Tern shows only the
// `model` and `mode` categories as chips under the composer (others go to
// /config), so the project takes the mode chip. Tern hides that chip when it
// has one choice, so a started thread still lists every project.
function projectOption(value, list) {
  const options = list.map((p) => ({ value: p.id, name: p.title || p.root }));
  if (!options.some((o) => o.value === value)) {
    options.unshift({ value, name: value === UNKNOWN ? "Unknown project" : value === "none" ? "No T3 Code projects" : value });
  }
  return { id: "project", name: "Project", category: "mode", type: "select", currentValue: value, options };
}

// Every project and model, with the session's picks, or once its thread has
// started, the thread's own (`session/set_config_option` then refuses).
function configOptions(s) {
  const list = catalog.projects(T3_HOME);
  if (s.fixed) return [projectOption(s.fixed.projectId || UNKNOWN, list), modelOption(s.fixed.model || UNKNOWN)];
  const project = list.find((p) => p.id === s.project);
  const model = s.model || catalog.defaultModel(T3_HOME, project) || DEFAULT;
  return [projectOption(s.project || "none", list), modelOption(model)];
}

// ---------------------------------------------------------------------------
// JSON-RPC over stdio
// ---------------------------------------------------------------------------

class RpcError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function send(msg) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...msg })}\n`);
}

function notify(method, params) {
  send({ method, params });
}

function update(sessionId, update) {
  notify("session/update", { sessionId, update });
}

function say(sessionId, text, messageId) {
  update(sessionId, {
    sessionUpdate: "agent_message_chunk",
    content: { type: "text", text },
    ...(messageId ? { messageId } : {}),
  });
}

// ---------------------------------------------------------------------------
// ACP methods
// ---------------------------------------------------------------------------

function session(sessionId) {
  const s = sessions.get(sessionId);
  if (!s) throw new RpcError(-32602, `Unknown session ${sessionId}`);
  return s;
}

// A resource's place as T3 should read it: a path for file: URIs.
function where(uri) {
  if (typeof uri !== "string") return "";
  try {
    return uri.startsWith("file:") ? fileURLToPath(uri) : uri;
  } catch {
    return uri;
  }
}

// A prompt's content blocks as one message for T3.
function promptText(blocks) {
  const parts = [];
  for (const b of blocks || []) {
    if (b.type === "text") {
      parts.push(b.text);
    } else if (b.type === "resource_link" && b.uri) {
      parts.push(`@${where(b.uri)}`);
    } else if (b.type === "resource" && b.resource) {
      const r = b.resource;
      if (typeof r.text === "string") parts.push(`${r.uri ? `${where(r.uri)}:\n` : ""}\`\`\`\n${r.text}\n\`\`\``);
      else if (r.uri) parts.push(`@${where(r.uri)}`);
    }
  }
  return parts.join("\n\n").trim();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A run id's place in its thread (`run:thread:<id>:ordinal:<n>`), -1 when
// it has none.
function ordinal(runId) {
  const m = /:ordinal:(\d+)$/.exec(runId || "");
  return m ? Number(m[1]) : -1;
}

// Follows run `runId` of `threadId`, passing its new assistant text to Tern,
// until the run ends, waits on the user, or Tern cancels the turn.
async function follow(sessionId, s, threadId, runId, turn) {
  // `show` lists finished messages only, oldest first, so the run's assistant
  // messages past the first `sent` are the new ones. That holds while the
  // window reaches back to the run's own prompt; when it doesn't, read more.
  let sent = 0;
  let window = POLL_MESSAGES;
  let answeredAt = Date.now();
  for (;;) {
    if (turn.cancelled) return "cancelled";
    let data;
    try {
      data = await t3Json(["thread", "show", threadId, "--messages", String(sent + window)], { cwd: workdir(s) });
      answeredAt = Date.now();
    } catch (err) {
      log("show failed:", err.message);
      const quiet = Date.now() - answeredAt;
      if (quiet > FOLLOW_GIVE_UP_MS) {
        say(sessionId, `\n\nStopped following: T3 Code hasn't answered for ${Math.round(quiet / 1000)} s (${err.message}).`);
        return "end_turn";
      }
      await sleep(POLL_MS);
      continue;
    }
    if (turn.cancelled) return "cancelled";
    const thread = data.thread || {};
    const messages = data.messages || [];
    const ours = messages.filter((m) => m.runId === runId);
    if (ours.length > 0 && !ours.some((m) => m.role === "user") && messages.length >= sent + window) {
      window *= 2;
      continue;
    }
    const mine = ours.filter((m) => m.role === "assistant");
    for (; sent < mine.length; sent++) {
      // A message after the first starts a new paragraph when Tern joins them.
      say(sessionId, (sent > 0 ? "\n\n" : "") + mine[sent].text, `${runId}#${sent}`);
    }

    const current = thread.latestRunId === runId;
    const status = thread.status;
    if (current && ENDED.has(status)) {
      if (status === "failed") say(sessionId, "\n\nThe run failed in T3 Code.");
      if (status === "interrupted" || status === "cancelled") say(sessionId, "\n\nThe run was stopped in T3 Code.");
      return "end_turn";
    }
    // `waiting` with nothing pending passes in a moment; with a request
    // pending, the agent wants an answer only the app can take.
    if (current && status === "waiting" && thread.pendingRequestCount > 0) {
      const link = appLink(threadId);
      say(sessionId, `\n\nT3 Code is waiting for your answer. Answer it in the app${link ? `: ${link}` : "."}`);
      return "end_turn";
    }
    if (!current && ordinal(thread.latestRunId) > ordinal(runId)) {
      // A later run took over (someone sent from the app); this one is done.
      return "end_turn";
    }
    await sleep(POLL_MS);
  }
}

const handlers = {
  async initialize(params) {
    const asked = Number(params?.protocolVersion) || PROTOCOL_VERSION;
    return {
      protocolVersion: Math.min(asked, PROTOCOL_VERSION),
      agentCapabilities: {
        loadSession: true,
        promptCapabilities: { image: false, audio: false, embeddedContext: true },
        sessionCapabilities: { list: {}, resume: {}, close: {}, delete: {} },
      },
      authMethods: [],
      agentInfo: { name: "t3-acp", title: "T3 Code", version: VERSION },
    };
  },

  async "session/new"(params) {
    const sessionId = `t3-new-${randomUUID()}`;
    const s = newSession(sessionId, params.cwd, null);
    sessions.set(sessionId, s);
    return { sessionId, configOptions: configOptions(s) };
  },

  async "session/resume"(params) {
    const threadId = threadFor(params.sessionId);
    const s = newSession(params.sessionId, params.cwd, threadId);
    sessions.set(params.sessionId, s);
    if (threadId) {
      try {
        fix(s, (await t3Json(["thread", "show", threadId, "--messages", "0"], { cwd: showDir(params.cwd) })).thread || {});
      } catch (err) {
        log("resume: show failed:", err.message);
        s.fixed = { projectId: null, model: null };
      }
    }
    return { configOptions: configOptions(s) };
  },

  async "session/set_config_option"(params) {
    const s = session(params.sessionId);
    const value = String(params.value);
    // The first message's `t3 thread start` has read the picks already.
    const pending = starting.get(params.sessionId);
    if (s.fixed || s.turn || (pending && !pending.settled)) {
      // Tern moves the chip before it hears back, so put it back first.
      update(params.sessionId, { sessionUpdate: "config_option_update", configOptions: configOptions(s) });
      throw new RpcError(-32602, "The project and model are set when the thread starts; open a new chat to change them.");
    }
    if (params.configId === "project") {
      if (!catalog.projects(T3_HOME, { fresh: true }).some((p) => p.id === value)) throw new RpcError(-32602, `No T3 Code project ${value}`);
      s.project = value;
    } else if (params.configId === "model") {
      if (value !== DEFAULT && !catalog.splitModel(value)) throw new RpcError(-32602, `No model ${value}`);
      s.model = value === DEFAULT ? null : value;
    } else {
      throw new RpcError(-32602, `No setting ${params.configId}`);
    }
    return { configOptions: configOptions(s) };
  },

  async "session/load"(params) {
    const { sessionId, cwd } = params;
    const threadId = threadFor(sessionId);
    const s = newSession(sessionId, cwd, threadId);
    sessions.set(sessionId, s);
    if (!threadId) return { configOptions: configOptions(s) };
    let data;
    try {
      data = await t3Json(["thread", "show", threadId, "--messages", String(REPLAY_MESSAGES)], { cwd: showDir(cwd) });
    } catch (err) {
      throw new RpcError(-32002, `Couldn't load T3 thread ${threadId}: ${err.message}`);
    }
    fix(s, data.thread || {});
    (data.messages || []).forEach((m, i) => {
      update(sessionId, {
        sessionUpdate: m.role === "user" ? "user_message_chunk" : "agent_message_chunk",
        content: { type: "text", text: m.text },
        messageId: `${m.runId}#load${i}`,
      });
    });
    if (data.thread?.title) update(sessionId, { sessionUpdate: "session_info_update", title: data.thread.title });
    return { configOptions: configOptions(s) };
  },

  async "session/list"(params) {
    const cwd = params?.cwd || process.cwd();
    let threads;
    try {
      // `--project` with a folder outside every project falls back to the
      // process's own folder, so run it there too.
      threads = await t3Json(["thread", "list", "--project", cwd], { cwd });
    } catch (err) {
      log("list failed:", err.message);
      return { sessions: [] };
    }
    // Sessions this agent started keep the id Tern knows them by.
    const byThread = new Map(Object.entries(loadState()).map(([sid, v]) => [v.threadId, sid]));
    return {
      sessions: (Array.isArray(threads) ? threads : []).map((t) => ({
        sessionId: byThread.get(t.threadId) || t.threadId,
        cwd: t.worktreePath || cwd,
        title: t.title || null,
        updatedAt: t.updatedAt || null,
      })),
    };
  },

  async "session/close"(params) {
    sessions.get(params.sessionId)?.turn?.cancel();
    sessions.delete(params.sessionId);
    return {};
  },

  async "session/delete"(params) {
    // The T3 thread stays; only this agent's record of the session goes.
    sessions.get(params.sessionId)?.turn?.cancel();
    starting.delete(params.sessionId);
    sessions.delete(params.sessionId);
    forget(params.sessionId);
    return {};
  },

  async "session/prompt"(params) {
    const { sessionId } = params;
    const s = session(sessionId);
    if (s.turn) throw new RpcError(-32602, "A turn is already running in this session.");
    const text = promptText(params.prompt);
    if (!text) return { stopReason: "end_turn" };

    const turn = newTurn();
    s.turn = turn;
    try {
      let runId;
      try {
        // A start Tern stopped waiting for may still be on its way.
        const pending = starting.get(sessionId);
        if (!s.threadId && pending) {
          const outcome = await Promise.race([pending.done, turn.whenCancelled]);
          if (outcome === CANCELLED) return { stopReason: "cancelled" };
          if (outcome.err && !pending.reported) {
            pending.reported = true;
            starting.delete(sessionId);
            const maybe = outcome.err.timedOut ? " It may still have made a thread, so check T3 Code." : "";
            say(sessionId, `Your last message didn't start a thread: ${outcome.err.message}${maybe} Starting one with this message.\n\n`);
          }
        }
        let result;
        if (s.threadId) {
          // Carries on if Tern cancels; T3 queues it either way.
          const sent = t3Json(["thread", "send", s.threadId, "-"], { cwd: workdir(s), stdin: text, timeout: T3_START_TIMEOUT_MS });
          sent.catch(() => {});
          result = await Promise.race([sent, turn.whenCancelled]);
        } else {
          const start = beginStart(sessionId, s, text);
          const outcome = await Promise.race([start.done, turn.whenCancelled]);
          if (outcome !== CANCELLED) {
            start.reported = true;
            if (outcome.err) {
              starting.delete(sessionId);
              throw outcome.err;
            }
          }
          result = outcome === CANCELLED ? CANCELLED : outcome.started;
        }
        if (result === CANCELLED) return { stopReason: "cancelled" };
        runId = result.runId;
      } catch (err) {
        // ACP wants `cancelled` after a cancel, whatever else went wrong.
        if (turn.cancelled) return { stopReason: "cancelled" };
        if (err instanceof T3Error) {
          const maybe = err.timedOut ? " It may still have gone through, so check T3 Code before sending it again." : "";
          say(sessionId, `T3 Code couldn't take that message: ${err.message}${maybe}`);
          return { stopReason: "end_turn" };
        }
        throw err;
      }
      if (!runId) return { stopReason: turn.cancelled ? "cancelled" : "end_turn" };
      const stopReason = await follow(sessionId, s, s.threadId, runId, turn);
      if (stopReason === "cancelled") {
        say(sessionId, "\n\nStopped following. The t3 CLI can't interrupt a run, so it keeps going in T3 Code.");
      }
      return { stopReason };
    } finally {
      if (s.turn === turn) s.turn = null;
    }
  },
};

const notifications = {
  "session/cancel"(params) {
    sessions.get(params?.sessionId)?.turn?.cancel();
  },
};

async function dispatch(msg) {
  if (typeof msg !== "object" || msg === null) return;
  const { id, method, params } = msg;
  if (method === undefined) return; // a response; this agent sends no requests
  if (id === undefined || id === null) {
    try {
      notifications[method]?.(params);
    } catch (err) {
      log(`${method} failed:`, err.message);
    }
    return;
  }
  const handler = handlers[method];
  if (!handler) {
    send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
    return;
  }
  try {
    send({ id, result: (await handler(params || {})) ?? null });
  } catch (err) {
    const code = err instanceof RpcError ? err.code : -32603;
    send({ id, error: { code, message: err.message || String(err) } });
  }
}

const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    send({ id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }
  dispatch(msg);
});
rl.on("close", () => process.exit(0));
