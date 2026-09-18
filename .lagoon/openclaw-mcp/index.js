// amazee.io MCP server plugin: makes this OpenClaw instance an MCP server that
// other people's MCP clients (Claude Code, Cursor, ...) can connect to.
//
// The endpoint rides the gateway's existing HTTP server, so there is no extra
// container, port or Lagoon route. It only exists when OPENCLAW_MCP_TOKEN (or
// OPENCLAW_MCP_TOKENS) is set on the environment -- Polydock injects that as a
// Lagoon project variable, so the feature is per-instance and revocable by
// clearing the variable and redeploying.
//
// Auth is deliberately NOT the gateway token: that credential owns the Control
// UI on the same hostname. MCP consumers get their own tokens, which also
// identify them, so each consumer talks to its own agent session.
import crypto from "node:crypto";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import {
  handleMcpMessage,
  lastAssistantText,
  parseMcpTokens,
  sanitizeClientId,
  SERVER_NAME,
  SERVER_VERSION,
} from "./mcp.js";

const PLUGIN_ID = "amazeeio-mcp";
const DEFAULT_PATH = "/mcp";
const MAX_BODY_BYTES = 256 * 1024;
const BODY_TIMEOUT_MS = 30000;
// A task is dropped once collected; this only reaps tasks nobody ever polled.
const TASK_TTL_MS = 30 * 60 * 1000;
const MAX_TASKS = 500;

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const finish = (error, value) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      if (error) {
        reject(error);
      } else {
        resolve(value);
      }
    };
    const timer = setTimeout(() => {
      req.destroy();
      finish(new Error("request body timed out"));
    }, BODY_TIMEOUT_MS);
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        req.destroy();
        finish(new Error("request body too large"));
        return;
      }
      chunks.push(chunk);
    });
    req.on("error", (error) => finish(error));
    req.on("end", () => {
      try {
        finish(null, JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch (error) {
        finish(error instanceof Error ? error : new Error(String(error)));
      }
    });
  });
}

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.statusCode = statusCode;
  res.setHeader("content-type", "application/json");
  res.setHeader("content-length", Buffer.byteLength(body));
  res.end(body);
}

function constantTimeEquals(a, b) {
  const left = Buffer.from(a, "utf8");
  const right = Buffer.from(b, "utf8");
  // timingSafeEqual throws on length mismatch, so compare a fixed-size digest
  // instead of the raw tokens and keep the comparison itself constant-time.
  return crypto.timingSafeEqual(
    crypto.createHash("sha256").update(left).digest(),
    crypto.createHash("sha256").update(right).digest(),
  );
}

/** Resolves the bearer token to a client id, or undefined when it does not match. */
function authenticate(req, tokens) {
  const header = req.headers?.authorization;
  if (typeof header !== "string") {
    return undefined;
  }
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  const presented = match?.[1]?.trim();
  if (!presented) {
    return undefined;
  }
  let clientId;
  // Walk every token so a wrong token costs the same as a right one.
  for (const [token, id] of tokens) {
    if (constantTimeEquals(token, presented)) {
      clientId = id;
    }
  }
  return clientId;
}

/**
 * Default agent id, mirroring core's resolveDefaultAgentId for the two roster
 * shapes config can hold. Not exported by the plugin SDK, and we only need the
 * id to build a session key.
 */
function resolveAgentId(config) {
  const roster = config?.agents;
  const entries = Array.isArray(roster?.list)
    ? roster.list.filter((entry) => entry && typeof entry === "object")
    : roster?.entries && typeof roster.entries === "object"
      ? Object.entries(roster.entries).map(([id, entry]) => ({ ...(entry ?? {}), id }))
      : [];
  const chosen = entries.find((entry) => entry.default === true) ?? entries[0];
  return typeof chosen?.id === "string" && chosen.id.trim() ? chosen.id.trim() : "main";
}

function pruneTasks(tasks) {
  const cutoff = Date.now() - TASK_TTL_MS;
  for (const [taskId, task] of tasks) {
    if (task.createdAt < cutoff) {
      tasks.delete(taskId);
    }
  }
  while (tasks.size > MAX_TASKS) {
    const oldest = tasks.keys().next();
    if (oldest.done) {
      break;
    }
    tasks.delete(oldest.value);
  }
}

function createDeps({ api, tasks, clientId }) {
  const sessionKey = `agent:${resolveAgentId(api.config)}:subagent:mcp-${clientId}`;
  return {
    async ask({ prompt }) {
      // One session per consumer keeps their transcript continuous, which means
      // two concurrent asks would race over "the newest assistant message".
      // Serialize instead of guessing which reply belongs to which task.
      for (const task of tasks.values()) {
        if (task.clientId === clientId) {
          throw new Error(
            `A previous task (${task.taskId}) is still open for this client. Collect it with \`result\` first.`,
          );
        }
      }
      const { runId } = await api.runtime.subagent.run({
        sessionKey,
        message: prompt,
        deliver: false,
      });
      const taskId = `t_${crypto.randomBytes(8).toString("hex")}`;
      tasks.set(taskId, { taskId, runId, sessionKey, clientId, createdAt: Date.now() });
      pruneTasks(tasks);
      return { task_id: taskId, status: "running" };
    },
    async result({ taskId, waitMs }) {
      const task = tasks.get(taskId);
      if (!task || task.clientId !== clientId) {
        throw new Error(`Unknown task_id: ${taskId}`);
      }
      const { status, error } = await api.runtime.subagent.waitForRun({
        runId: task.runId,
        timeoutMs: waitMs,
      });
      if (status === "timeout") {
        return { task_id: taskId, status: "running" };
      }
      tasks.delete(taskId);
      if (status === "error") {
        return { task_id: taskId, status: "error", error: error ?? "The agent run failed." };
      }
      const { messages } = await api.runtime.subagent.getSessionMessages({
        sessionKey: task.sessionKey,
        limit: 20,
      });
      return { task_id: taskId, status: "done", text: lastAssistantText(messages) };
    },
  };
}

export default definePluginEntry({
  id: PLUGIN_ID,
  name: "amazee.io MCP server",
  description: "Exposes this OpenClaw instance as a remote MCP server over HTTP.",
  register(api) {
    const tokens = parseMcpTokens(process.env);
    if (tokens.size === 0) {
      api.logger?.info?.(
        `[${PLUGIN_ID}] OPENCLAW_MCP_TOKEN/OPENCLAW_MCP_TOKENS not set; MCP endpoint not registered.`,
      );
      return;
    }
    const path = String(process.env.OPENCLAW_MCP_PATH ?? "").trim() || DEFAULT_PATH;
    // ponytail: in-memory task map. A gateway restart drops in-flight task ids
    // and the caller re-asks. Move to api.runtime state if that becomes a real
    // complaint -- durable storage is not available to load-path plugins.
    const tasks = new Map();

    api.registerHttpRoute({
      path,
      auth: "plugin",
      match: "exact",
      handler: async (req, res) => {
        if (req.method !== "POST") {
          // Stateless JSON only: we never open the optional SSE stream, and the
          // spec wants 405 when the endpoint does not offer one.
          res.statusCode = 405;
          res.setHeader("allow", "POST");
          res.end();
          return true;
        }
        const clientId = authenticate(req, tokens);
        if (!clientId) {
          res.statusCode = 401;
          res.setHeader("www-authenticate", 'Bearer realm="openclaw-mcp"');
          res.end();
          return true;
        }
        let message;
        try {
          message = await readJsonBody(req);
        } catch (error) {
          sendJson(res, 400, {
            jsonrpc: "2.0",
            id: null,
            error: { code: -32700, message: error instanceof Error ? error.message : "Parse error" },
          });
          return true;
        }
        const reply = await handleMcpMessage(
          message,
          createDeps({ api, tasks, clientId: sanitizeClientId(clientId) }),
        );
        if (!reply) {
          res.statusCode = 202;
          res.end();
          return true;
        }
        sendJson(res, 200, reply);
        return true;
      },
    });

    api.logger?.info?.(
      `[${PLUGIN_ID}] ${SERVER_NAME} ${SERVER_VERSION} listening on ${path} for ${tokens.size} client token(s).`,
    );
  },
});
