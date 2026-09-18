// Self-check for the MCP protocol surface: node --test .lagoon/openclaw-mcp/
import assert from "node:assert/strict";
import test from "node:test";
import {
  DEFAULT_RESULT_WAIT_MS,
  handleMcpMessage,
  JSON_RPC,
  LATEST_PROTOCOL_VERSION,
  lastAssistantText,
  MAX_RESULT_WAIT_MS,
  parseMcpTokens,
  sanitizeClientId,
} from "./mcp.js";

function stubDeps(overrides = {}) {
  return {
    calls: [],
    async ask(params) {
      this.calls.push(["ask", params]);
      return { task_id: "t_abc", status: "running" };
    },
    async result(params) {
      this.calls.push(["result", params]);
      return { task_id: params.taskId, status: "done", text: "hi" };
    },
    ...overrides,
  };
}

test("initialize echoes a supported protocol version and falls back otherwise", async () => {
  const known = await handleMcpMessage(
    { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05" } },
    stubDeps(),
  );
  assert.equal(known.result.protocolVersion, "2024-11-05");
  assert.deepEqual(known.result.capabilities, { tools: { listChanged: false } });

  const unknown = await handleMcpMessage(
    { jsonrpc: "2.0", id: 2, method: "initialize", params: { protocolVersion: "1999-01-01" } },
    stubDeps(),
  );
  assert.equal(unknown.result.protocolVersion, LATEST_PROTOCOL_VERSION);
});

test("tools/list advertises ask and result", async () => {
  const reply = await handleMcpMessage({ jsonrpc: "2.0", id: 3, method: "tools/list" }, stubDeps());
  assert.deepEqual(
    reply.result.tools.map((tool) => tool.name),
    ["ask", "result"],
  );
});

test("ask forwards the trimmed prompt and returns structured content", async () => {
  const deps = stubDeps();
  const reply = await handleMcpMessage(
    {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: { name: "ask", arguments: { prompt: "  what is up  " } },
    },
    deps,
  );
  assert.deepEqual(deps.calls, [["ask", { prompt: "what is up" }]]);
  assert.deepEqual(reply.result.structuredContent, { task_id: "t_abc", status: "running" });
  assert.equal(JSON.parse(reply.result.content[0].text).status, "running");
});

test("ask rejects an empty prompt as a tool error, not a protocol error", async () => {
  const reply = await handleMcpMessage(
    { jsonrpc: "2.0", id: 5, method: "tools/call", params: { name: "ask", arguments: { prompt: "  " } } },
    stubDeps(),
  );
  assert.equal(reply.result.isError, true);
  assert.equal(reply.error, undefined);
});

test("result clamps wait_ms into the supported window", async () => {
  const deps = stubDeps();
  await handleMcpMessage(
    { jsonrpc: "2.0", id: 6, method: "tools/call", params: { name: "result", arguments: { task_id: "t_abc" } } },
    deps,
  );
  await handleMcpMessage(
    {
      jsonrpc: "2.0",
      id: 7,
      method: "tools/call",
      params: { name: "result", arguments: { task_id: "t_abc", wait_ms: 999999 } },
    },
    deps,
  );
  await handleMcpMessage(
    {
      jsonrpc: "2.0",
      id: 8,
      method: "tools/call",
      params: { name: "result", arguments: { task_id: "t_abc", wait_ms: -5 } },
    },
    deps,
  );
  assert.deepEqual(
    deps.calls.map(([, params]) => params.waitMs),
    [DEFAULT_RESULT_WAIT_MS, MAX_RESULT_WAIT_MS, 0],
  );
});

test("a failing tool comes back as isError so the client can show the model", async () => {
  const deps = stubDeps({
    async ask() {
      throw new Error("A previous task is still open for this client.");
    },
  });
  const reply = await handleMcpMessage(
    { jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "ask", arguments: { prompt: "x" } } },
    deps,
  );
  assert.equal(reply.result.isError, true);
  assert.match(reply.result.content[0].text, /still open/);
});

test("notifications get no response and unknown methods get -32601", async () => {
  assert.equal(
    await handleMcpMessage({ jsonrpc: "2.0", method: "notifications/initialized" }, stubDeps()),
    null,
  );
  const unknown = await handleMcpMessage({ jsonrpc: "2.0", id: 10, method: "nope" }, stubDeps());
  assert.equal(unknown.error.code, JSON_RPC.methodNotFound);
  const batch = await handleMcpMessage([{ jsonrpc: "2.0", id: 11, method: "ping" }], stubDeps());
  assert.equal(batch.error.code, JSON_RPC.invalidRequest);
});

test("tokens come from either env var and client ids stay session-key safe", () => {
  const tokens = parseMcpTokens({
    OPENCLAW_MCP_TOKEN: "single-token",
    OPENCLAW_MCP_TOKENS: "Ops Team:team-token, broken-entry ,:no-name,trailing:",
  });
  assert.equal(tokens.get("single-token"), "default");
  assert.equal(tokens.get("team-token"), "ops-team");
  assert.equal(tokens.size, 2);
  assert.equal(parseMcpTokens({}).size, 0);
  assert.equal(sanitizeClientId("!!!"), "client");
  assert.equal(sanitizeClientId("A_b/C"), "a-b-c");
});

test("lastAssistantText reads the newest assistant reply in either content shape", () => {
  assert.equal(
    lastAssistantText([
      { role: "assistant", content: "older" },
      { role: "user", content: "question" },
      { role: "assistant", content: [{ type: "text", text: "newer" }, { type: "image" }] },
    ]),
    "newer",
  );
  assert.equal(lastAssistantText([{ role: "user", content: "only a question" }]), "");
  assert.equal(lastAssistantText(undefined), "");
});
