// What T3 Code offers a new thread: its projects and its models. The `t3`
// CLI lists neither, so both are read, read-only, from T3 Code's own files
// under ~/.t3/userdata. A T3 Code update that changes them breaks the lists,
// not the chat: a list that can't be read comes back empty, and threads then
// start with T3 Code's defaults.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const PROJECTS_SQL =
  "select project_id as id, title, workspace_root as root, default_model_selection_json as model " +
  "from projection_projects where deleted_at is null order by updated_at desc";

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

// Reads within a few seconds of each other share one sqlite3 run: one request
// asks several times, and a turn polls every second.
const PROJECTS_TTL_MS = 5000;
let cached = { at: 0, home: "", list: [] };

/** @returns {{id: string, title: string, root: string, model: string | null}[]} newest first */
// `fresh` skips the cache, for checking a project picked moments ago.
export function projects(t3Home, { fresh = false } = {}) {
  if (!fresh && cached.home === t3Home && Date.now() - cached.at < PROJECTS_TTL_MS) return cached.list;
  const list = readProjects(t3Home);
  // A failed read (the database busy) isn't kept, so the next call retries.
  if (list) cached = { at: Date.now(), home: t3Home, list };
  return list ?? [];
}

// The projects, or null when the database can't be read.
function readProjects(t3Home) {
  try {
    const out = execFileSync(
      "/usr/bin/sqlite3",
      ["-readonly", "-json", join(t3Home, "userdata", "statev2.sqlite"), PROJECTS_SQL],
      { encoding: "utf8", timeout: 5000 },
    );
    const rows = JSON.parse(out || "[]");
    if (!Array.isArray(rows)) return null;
    return rows
      .filter((r) => r.id && r.root)
      .map((r) => {
        let sel = null;
        try {
          sel = r.model ? JSON.parse(r.model) : null;
        } catch {}
        return { ...r, model: sel?.instanceId && sel?.model ? `${sel.instanceId}/${sel.model}` : null };
      });
  } catch {
    return null;
  }
}

// The project holding `dir`: the one with the longest root that contains it.
export function projectFor(list, dir) {
  let best = null;
  for (const p of list) {
    const root = p.root.replace(/\/+$/, "");
    if ((dir === root || dir.startsWith(`${root}/`)) && (!best || root.length > best.root.length)) best = p;
  }
  return best;
}

/**
 * T3 Code's models, grouped by provider instance: an enabled instance offers
 * its driver's current models from T3's model manifest, its own custom models,
 * and models you favourited for it in T3 Code (kept in settings.json; T3 reads
 * the older client-settings.json copy only while that is unset).
 * @returns {{instance: string, name: string, models: {slug: string, name: string}[]}[]}
 */
export function models(t3Home) {
  const dir = join(t3Home, "userdata");
  const settings = readJson(join(dir, "settings.json")) || {};
  const manifest = readJson(join(dir, "model-manifest.json"))?.manifest || {};
  const favorites = settings.favorites ?? readJson(join(dir, "client-settings.json"))?.favorites ?? [];
  const out = [];
  for (const [instance, cfg] of Object.entries(settings.providerInstances || {})) {
    if (!cfg || cfg.enabled === false) continue;
    const known = manifest.providers?.[cfg.driver]?.models || [];
    const names = new Map(known.map((m) => [m.slug, m.name || m.slug]));
    const slugs = [
      ...known.filter((m) => m.status === "current").map((m) => m.slug),
      ...(cfg.config?.customModels || []),
      ...favorites.filter((f) => f.provider === instance).map((f) => f.model),
    ];
    const seen = new Set();
    const list = [];
    for (const slug of slugs) {
      if (typeof slug !== "string" || !slug || seen.has(slug)) continue;
      seen.add(slug);
      list.push({ slug, name: names.get(slug) || slug });
    }
    if (list.length) out.push({ instance, name: cfg.displayName || driverName(cfg.driver) || instance, models: list });
  }
  return out;
}

function driverName(driver) {
  return { claudeAgent: "Claude", codex: "Codex", antigravity: "Antigravity", cursor: "Cursor", opencode: "OpenCode" }[driver];
}

// The model T3 Code starts a thread in `project` on when given none, as
// `instance/slug`: the project's own default, else the global one; null when
// neither is set. (T3 can still swap it at start, e.g. past a usage limit.)
export function defaultModel(t3Home, project) {
  if (project?.model) return project.model;
  const sel = readJson(join(t3Home, "userdata", "settings.json"))?.defaultModelSelection;
  return sel?.instanceId && sel?.model ? `${sel.instanceId}/${sel.model}` : null;
}

// A model option value `instance/slug` split back into its parts. Instance
// ids hold no `/` (slugs may), so the first `/` divides them.
export function splitModel(value) {
  const i = value.indexOf("/");
  return i > 0 ? { instance: value.slice(0, i), slug: value.slice(i + 1) } : null;
}
