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
// no-ops without work/CONFIG.md, the guard excepted. A script that cannot run
// or times out never breaks a session: the adapter fails open, as a Claude
// Code hook that fails does, and logs one `adapter_failure` warn naming it.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

declare const process: { env: Record<string, string | undefined> };

const ROOT = join(dirname(realpathSync(fileURLToPath(import.meta.url))), "..", "..", "..");
const HOOKS = join(ROOT, "scripts", "harness", "claude-code");
// a hook script that runs longer is killed; CG_PI_HOOK_TIMEOUT_MS overrides it (the tests)
const TIMEOUT_MS = Number(process.env.CG_PI_HOOK_TIMEOUT_MS) || 30_000;
// Claude Code's names for pi's built-in tools, as the hook scripts match them
const TOOL_NAMES: Record<string, string> = {
	bash: "Bash", read: "Read", edit: "Edit", write: "Write", grep: "Grep", find: "Glob", ls: "LS",
};

// `failed` is set when the script did not run to an exit code: it timed out,
// could not start, or was killed. The caller then treats the call as not
// made — fail open — and the failure is logged.
type Result = { code: number; stderr: string; failed?: string };

function spawnBash(args: string[], payload: string | undefined, sid: string): Promise<Result> {
	return new Promise((resolve) => {
		let stderr = "";
		let done = false;
		const finish = (r: Result) => {
			if (done) return;
			done = true;
			resolve(r);
		};
		try {
			const child = spawn("bash", args, {
				env: { ...process.env, WORK_DIR: join(ROOT, "work"), LOG_RUN_ID: sid },
				stdio: ["pipe", "ignore", "pipe"],
			});
			const timer = setTimeout(() => {
				child.kill("SIGKILL");
				finish({ code: -1, stderr, failed: `timed out after ${TIMEOUT_MS / 1000} s` });
			}, TIMEOUT_MS);
			child.stderr?.on("data", (d) => (stderr += String(d)));
			child.on("error", (e) => {
				clearTimeout(timer);
				finish({ code: -1, stderr, failed: `could not start: ${e.message}` });
			});
			child.on("close", (code, signal) => {
				clearTimeout(timer);
				finish(code === null ? { code: -1, stderr, failed: `killed by ${signal}` } : { code, stderr });
			});
			child.stdin?.on("error", () => {});
			child.stdin?.end(payload ?? "");
		} catch (e) {
			finish({ code: -1, stderr, failed: `could not start: ${(e as Error).message}` });
		}
	});
}

async function run(script: string, payload: { session_id: string; [field: string]: unknown }): Promise<Result> {
	const r = await spawnBash([join(HOOKS, script)], JSON.stringify(payload), payload.session_id);
	if (r.failed) {
		const msg = `${script} ${r.failed} — the call went through unchecked (fail open)`;
		console.warn(`[code-guardian] ${msg}`);
		await spawnBash(
			["-c", '. "$1" && logev warn adapter_failure "$2"', "log", join(ROOT, "scripts", "log.sh"), msg],
			undefined,
			payload.session_id,
		);
	}
	return r;
}

function text(content: unknown): string {
	if (!Array.isArray(content)) return "";
	return content
		.map((c) => (c && typeof c === "object" && "text" in c ? String((c as { text: unknown }).text) : ""))
		.join("");
}

// the error class log-api-failure.sh records, from the provider's message —
// one of docs/monitor.md → The `api_failure` classes (test_monitor.sh compares)
function errorClass(message: string): string {
	const m = message.toLowerCase();
	if (/\b429\b|rate.?limit|too many requests/.test(m)) return "rate_limit";
	if (/\b529\b|overloaded/.test(m)) return "overloaded";
	if (/max.?output.?tokens|output token limit/.test(m)) return "max_output_tokens";
	// a cloud provider's credentials (Bedrock, Vertex) before a plain 401/403
	if (/credential|security token|expiredtoken|signature.*(expired|invalid)/.test(m)) return "cloud_credential_error";
	if (/oauth.*not allowed|organi[sz]ation.*not allowed/.test(m)) return "oauth_org_not_allowed";
	if (/account.*(on hold|suspended|disabled)/.test(m)) return "account_on_hold";
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
