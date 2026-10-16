// code-guardian's pi adapter (docs/harness-pi.md → Adapter): pi has no hooks,
// so this extension turns pi's events into the Claude Code hook payloads and
// runs the same hook scripts (../claude-code/*.sh) — one implementation of
// every rule for both harnesses. install.sh links it into
// ~/.pi/agent/extensions/, where pi loads it into every session.
//
//   tool_call (bash)        → guard-definition-issue.sh  (exit 2 blocks the call)
//   tool_result, failed     → log-tool-event.sh           (PostToolUseFailure)
//   tool_result, bash       → log-review-step.sh          (PostToolUse)
//   agent_before_settle     → enforce-review-completion.sh (Stop; exit 2 continues the run)
//                             or log-api-failure.sh when the run ended on an API error
//   session_shutdown        → log-session-tokens.sh       (SessionEnd)
//
// A nested subagent session (subagents.sh sets CG_PI_PARENT_SESSION) logs
// under its parent's run id and runs the guard and the failure log only: the
// parent's events cover its usage, steps and stop. The scripts act on the
// definition this file belongs to and its work/ (WORK_DIR); every script
// no-ops without work/CONFIG.md, the guard excepted. A script failure never
// breaks a session.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

declare const process: { env: Record<string, string | undefined> };

const ROOT = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "..", "..");
const HOOKS = join(ROOT, "scripts", "harness", "claude-code");
const TIMEOUT_MS = 30_000;
// Claude Code's names for pi's built-in tools, as the hook scripts match them
const TOOL_NAMES: Record<string, string> = {
	bash: "Bash", read: "Read", edit: "Edit", write: "Write", grep: "Grep", find: "Glob", ls: "LS",
};

type Result = { code: number; stderr: string };

function run(script: string, payload: unknown): Promise<Result> {
	return new Promise((resolve) => {
		let stderr = "";
		let done = false;
		const finish = (code: number) => {
			if (done) return;
			done = true;
			resolve({ code, stderr });
		};
		try {
			const child = spawn("bash", [join(HOOKS, script)], {
				env: { ...process.env, WORK_DIR: join(ROOT, "work") },
				stdio: ["pipe", "ignore", "pipe"],
			});
			const timer = setTimeout(() => {
				child.kill("SIGKILL");
				finish(0);
			}, TIMEOUT_MS);
			child.stderr?.on("data", (d) => (stderr += String(d)));
			child.on("error", () => finish(0));
			child.on("close", (code) => {
				clearTimeout(timer);
				finish(code ?? 0);
			});
			child.stdin?.on("error", () => {});
			child.stdin?.end(JSON.stringify(payload));
		} catch {
			finish(0);
		}
	});
}

function text(content: unknown): string {
	if (!Array.isArray(content)) return "";
	return content
		.map((c) => (c && typeof c === "object" && "text" in c ? String((c as { text: unknown }).text) : ""))
		.join("");
}

// the error class log-api-failure.sh records, from the provider's message
// (Claude Code's StopFailure classes, docs/monitor.md)
function errorClass(message: string): string {
	const m = message.toLowerCase();
	if (/\b429\b|rate.?limit|too many requests/.test(m)) return "rate_limit";
	if (/\b529\b|overloaded/.test(m)) return "overloaded";
	if (/\b401\b|\b403\b|unauthori[sz]ed|authentication|forbidden/.test(m)) return "authentication_failed";
	if (/billing|quota|credit|budget/.test(m)) return "billing_error";
	if (/model.*(not found|unknown|unsupported)|\b404\b/.test(m)) return "model_not_found";
	if (/\b400\b|invalid.?request/.test(m)) return "invalid_request";
	if (/\b5\d\d\b|server error|internal error|bad gateway|unavailable|timed? ?out|econn|socket/.test(m)) return "server_error";
	return "unknown";
}

export default function register(pi: ExtensionAPI): void {
	const parent = process.env.CG_PI_PARENT_SESSION || undefined;
	const sid = (ctx: { sessionManager: { getSessionId(): string } }) =>
		parent ?? ctx.sessionManager.getSessionId();
	const transcript = (ctx: { sessionManager: { getSessionFile(): string | undefined } }) =>
		ctx.sessionManager.getSessionFile() ?? "";

	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName !== "bash") return;
		const command = String((event.input as { command?: unknown }).command ?? "");
		const r = await run("guard-definition-issue.sh", {
			hook_event_name: "PreToolUse",
			session_id: sid(ctx),
			tool_name: "Bash",
			tool_input: { command },
		});
		if (r.code === 2) return { block: true, reason: r.stderr.trim() || "refused by code-guardian" };
	});

	pi.on("tool_result", async (event, ctx) => {
		const tool = TOOL_NAMES[event.toolName] ?? event.toolName;
		const out = text(event.content);
		if (event.isError) {
			await run("log-tool-event.sh", {
				hook_event_name: "PostToolUseFailure",
				session_id: sid(ctx),
				tool_name: tool,
				tool_input: event.input,
				error: out,
			});
		} else if (tool === "Bash" && !parent) {
			await run("log-review-step.sh", {
				hook_event_name: "PostToolUse",
				session_id: sid(ctx),
				transcript_path: transcript(ctx),
				tool_name: "Bash",
				tool_input: event.input,
				tool_response: { stdout: out },
			});
		}
	});

	pi.on("agent_before_settle", async (event, ctx) => {
		if (parent) return;
		if (event.outcome === "error") {
			const last = [...event.context.contextMessages]
				.reverse()
				.find((m) => (m as { role?: string }).role === "assistant") as
				| { errorMessage?: string; stopReason?: string }
				| undefined;
			const detail = last?.errorMessage ?? last?.stopReason ?? "";
			await run("log-api-failure.sh", {
				session_id: sid(ctx),
				error: errorClass(detail),
				error_details: detail,
			});
			return;
		}
		if (event.outcome !== "completed" || event.continue) return;
		const r = await run("enforce-review-completion.sh", {
			hook_event_name: "Stop",
			session_id: sid(ctx),
			transcript_path: transcript(ctx),
		});
		if (r.code !== 2 || !r.stderr.trim()) return;
		return {
			continue: true,
			entries: [
				{ type: "custom_message", customType: "code-guardian", content: r.stderr.trim(), display: true },
			],
		};
	});

	pi.on("session_shutdown", async (_event, ctx) => {
		if (parent) return;
		await run("log-session-tokens.sh", { session_id: sid(ctx), transcript_path: transcript(ctx) });
	});
}
