// MCP protocol surface for the amazee.io OpenClaw MCP server.
//
// Kept transport- and OpenClaw-agnostic on purpose: everything here is pure
// JSON in / JSON out so it can be exercised by `node --test mcp.test.mjs`
// without a gateway, and so index.js stays a thin HTTP + runtime adapter.
//
// ponytail: hand-rolled JSON-RPC instead of @modelcontextprotocol/sdk. The
// plugin loads from plugins.load.paths inside the image, where only
// `openclaw/plugin-sdk/*` is resolvable -- an npm dependency would mean a
// node_modules tree baked next to the plugin. Stateless streamable HTTP is
// four methods; if we ever need SSE streaming or OAuth, take the SDK then.

export const SERVER_NAME = "openclaw-amazeeio";
export const SERVER_VERSION = "0.1.0";

// Newest first. We answer `initialize` with the client's version when we know
// it, else with our newest, per the MCP lifecycle spec.
export const SUPPORTED_PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
export const LATEST_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0];

export const DEFAULT_RESULT_WAIT_MS = 2000;
export const MAX_RESULT_WAIT_MS = 30000;

export const TOOLS = [
  {
    name: "ask",
    description:
      "Send a message to this OpenClaw instance's agent, which runs with its own workspace and tools. " +
      'Returns `{task_id, status: "running"}` immediately; collect the answer with `result`. ' +
      "Each client has one continuous conversation with the agent, so later asks can refer to earlier ones. " +
      "Only one task per client can be open at a time: `ask` fails until the previous task has been collected with `result`.",
    inputSchema: {
      type: "object",
      properties: {
        prompt: {
          type: "string",
          description: "The message for the agent. It can't see your conversation, so include any context it needs.",
        },
      },
      required: ["prompt"],
      additionalProperties: false,
    },
  },
  {
    name: "result",
    description:
      "Collect the answer for a task id returned by `ask`. Long-polls up to wait_ms, then returns one of: " +
      '`{status: "running"}` (call again), `{status: "done", text}` with the agent\'s final reply, or ' +
      '`{status: "error", error}`. A finished task is removed once returned, so a second call for it fails ' +
      "with an unknown task_id; tasks also expire 30 minutes after `ask`.",
    inputSchema: {
      type: "object",
      properties: {
        task_id: {
          type: "string",
          description: "Task id returned by `ask`.",
        },
        wait_ms: {
          type: "number",
          description: `How long to wait for completion before reporting "running" (0-${MAX_RESULT_WAIT_MS}, default ${DEFAULT_RESULT_WAIT_MS}).`,
        },
      },
      required: ["task_id"],
      additionalProperties: false,
    },
  },
];

/** JSON-RPC error codes we emit. */
export const JSON_RPC = {
  parseError: -32700,
  invalidRequest: -32600,
  methodNotFound: -32601,
  invalidParams: -32602,
  internalError: -32603,
};

export function jsonRpcResult(id, result) {
  return { jsonrpc: "2.0", id, result };
}

export function jsonRpcError(id, code, message) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code, message } };
}

function negotiateProtocolVersion(requested) {
  return typeof requested === "string" && SUPPORTED_PROTOCOL_VERSIONS.includes(requested)
    ? requested
    : LATEST_PROTOCOL_VERSION;
}

function toolResult(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload) }],
    structuredContent: payload,
  };
}

function toolError(message) {
  return {
    content: [{ type: "text", text: message }],
    isError: true,
  };
}

function clampWaitMs(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_RESULT_WAIT_MS;
  }
  return Math.min(MAX_RESULT_WAIT_MS, Math.max(0, Math.floor(value)));
}

async function callTool(params, deps) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  if (name === "ask") {
    const prompt = typeof args.prompt === "string" ? args.prompt.trim() : "";
    if (!prompt) {
      return toolError("`prompt` is required and must be a non-empty string.");
    }
    return toolResult(await deps.ask({ prompt }));
  }
  if (name === "result") {
    const taskId = typeof args.task_id === "string" ? args.task_id.trim() : "";
    if (!taskId) {
      return toolError("`task_id` is required and must be a non-empty string.");
    }
    return toolResult(await deps.result({ taskId, waitMs: clampWaitMs(args.wait_ms) }));
  }
  return toolError(`Unknown tool: ${String(name)}`);
}

/**
 * Handles one JSON-RPC message.
 *
 * Returns the response object, or null for notifications (which get a bare 202
 * from the HTTP layer).
 */
export async function handleMcpMessage(message, deps) {
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    // JSON-RPC batching was removed in MCP 2025-06-18, so an array is simply invalid here.
    return jsonRpcError(null, JSON_RPC.invalidRequest, "Expected a single JSON-RPC 2.0 object.");
  }
  const { jsonrpc, method, id, params } = message;
  if (jsonrpc !== "2.0" || typeof method !== "string") {
    return jsonRpcError(id, JSON_RPC.invalidRequest, "Invalid JSON-RPC 2.0 request.");
  }
  // No id means a notification: acknowledge without a response body.
  if (id === undefined || id === null) {
    return null;
  }

  switch (method) {
    case "initialize":
      return jsonRpcResult(id, {
        protocolVersion: negotiateProtocolVersion(params?.protocolVersion),
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        instructions:
          "This MCP server is one person's OpenClaw instance. `ask` submits a prompt to their " +
          "agent and returns a task id; `result` collects the answer once the agent finishes.",
      });
    case "ping":
      return jsonRpcResult(id, {});
    case "tools/list":
      return jsonRpcResult(id, { tools: TOOLS });
    case "tools/call":
      try {
        return jsonRpcResult(id, await callTool(params, deps));
      } catch (error) {
        // Tool failures belong in the result as isError, not as protocol errors:
        // MCP clients surface them to the model instead of dropping the turn.
        return jsonRpcResult(id, toolError(error instanceof Error ? error.message : String(error)));
      }
    default:
      return jsonRpcError(id, JSON_RPC.methodNotFound, `Unknown method: ${method}`);
  }
}

/** Session keys and log lines both carry this, so keep it boring and bounded. */
export function sanitizeClientId(value) {
  const cleaned = String(value ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  return cleaned.slice(0, 48) || "client";
}

/**
 * Reads consumer tokens from the environment.
 *
 * OPENCLAW_MCP_TOKEN        one token, client id "default"
 * OPENCLAW_MCP_TOKENS       "name:token,name2:token2" for several consumers
 *
 * Tokens stay in env and never reach openclaw.json, matching how BRAVE_API_KEY
 * is handled in 60-amazeeai-config.sh.
 *
 * @returns {Map<string, string>} token -> client id
 */
export function parseMcpTokens(env) {
  const tokens = new Map();
  const single = String(env?.OPENCLAW_MCP_TOKEN ?? "").trim();
  if (single) {
    tokens.set(single, "default");
  }
  for (const entry of String(env?.OPENCLAW_MCP_TOKENS ?? "").split(",")) {
    const raw = entry.trim();
    if (!raw) {
      continue;
    }
    const separator = raw.indexOf(":");
    if (separator <= 0) {
      continue;
    }
    const name = sanitizeClientId(raw.slice(0, separator));
    const token = raw.slice(separator + 1).trim();
    if (token) {
      tokens.set(token, name);
    }
  }
  return tokens;
}

/** Picks the newest assistant text out of a sessions.get message list. */
export function lastAssistantText(messages) {
  if (!Array.isArray(messages)) {
    return "";
  }
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!message || typeof message !== "object" || message.role !== "assistant") {
      continue;
    }
    const { content, text } = message;
    if (typeof content === "string" && content.trim()) {
      return content.trim();
    }
    if (Array.isArray(content)) {
      const joined = content
        .map((part) => (part && typeof part === "object" && typeof part.text === "string" ? part.text : ""))
        .filter((part) => part.trim())
        .join("\n")
        .trim();
      if (joined) {
        return joined;
      }
    }
    if (typeof text === "string" && text.trim()) {
      return text.trim();
    }
  }
  return "";
}
