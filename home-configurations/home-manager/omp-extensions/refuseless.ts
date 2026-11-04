/**
 * Refuseless (https://refuseless.com) provider for omp.
 *
 * - `omp login refuseless` / `/login refuseless` stores an API key, checked
 *   against the free, key-protected `GET /v1/credits`.
 * - The model list comes from `GET /v1/models`, which with a key also returns
 *   private models granted to the account.
 * - Refuseless accepts only the reasoning levels each model lists in
 *   `reasoning_efforts` (`off`, `low`, `high`, `max`); any other level is a 400.
 *   Each model therefore declares exactly those efforts, so omp clamps its
 *   ladder onto them, and only models that list `off` can turn thinking off.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const PROVIDER = "refuseless";
const BASE_URL = "https://api.refuseless.com/v1";
// /v1/models states no output limit. Requests ask for at most this many tokens;
// the server also clamps max_tokens to the key's credit reservation.
const MAX_OUTPUT_TOKENS = 131_072;
const DEFAULT_CONTEXT = 131_072;

type WireEffort = "off" | "low" | "high" | "max";
type Effort = "low" | "high" | "max";

interface RefuselessModel {
	id: string;
	vision?: boolean;
	context_length?: number;
	reasoning_efforts?: WireEffort[];
	reasoning_default?: WireEffort;
}

const NAME_WORDS: Record<string, string> = {
	glm: "GLM",
	deepseek: "DeepSeek",
	minimax: "MiniMax",
};

function displayName(id: string): string {
	return id
		.split("-")
		.map(word => NAME_WORDS[word] ?? word.charAt(0).toUpperCase() + word.slice(1))
		.join(" ");
}

async function errorDetail(response: Response): Promise<string> {
	const body = await response.text().catch(() => "");
	try {
		const parsed = JSON.parse(body) as { error?: { message?: string } | string };
		const message = typeof parsed.error === "string" ? parsed.error : parsed.error?.message;
		if (message) return message;
	} catch {}
	return body.slice(0, 200) || response.statusText;
}

function toModelConfig(row: RefuselessModel) {
	const wireEfforts = row.reasoning_efforts ?? [];
	const efforts = wireEfforts.filter((e): e is Effort => e !== "off");
	const canDisable = wireEfforts.includes("off");
	const reasoning = efforts.length > 0;
	const contextWindow = row.context_length && row.context_length > 0 ? row.context_length : DEFAULT_CONTEXT;
	const defaultLevel =
		row.reasoning_default && row.reasoning_default !== "off" && efforts.includes(row.reasoning_default)
			? row.reasoning_default
			: undefined;
	return {
		id: row.id,
		name: displayName(row.id),
		reasoning,
		thinking: reasoning
			? {
					mode: "effort" as const,
					efforts,
					...(defaultLevel ? { defaultLevel } : {}),
					// Without `off`, a thinking-off request goes out at the lowest level
					// instead of a value the server rejects.
					requiresEffort: !canDisable,
				}
			: undefined,
		input: row.vision ? ["text", "image"] : ["text"],
		// /v1/models publishes no prices.
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow,
		maxTokens: Math.min(MAX_OUTPUT_TOKENS, contextWindow),
		compat: {
			supportsReasoningEffort: reasoning,
			reasoningContentField: "reasoning_content" as const,
			// `none` is Refuseless's alias for `off`.
			...(canDisable ? { reasoningDisableMode: "none-effort" as const } : {}),
		},
	};
}

export default function refuseless(pi: ExtensionAPI) {
	pi.registerProvider(PROVIDER, {
		baseUrl: BASE_URL,
		api: "openai-completions",
		oauth: {
			name: "Refuseless",
			async login(callbacks) {
				const key = (
					await callbacks.onPrompt({
						message: "Paste your Refuseless API key",
						secret: true,
					})
				).trim();
				if (!key) throw new Error("No API key entered.");
				const response = await fetch(`${BASE_URL}/credits`, {
					headers: { Authorization: `Bearer ${key}` },
					signal: callbacks.signal,
				});
				if (!response.ok) {
					throw new Error(`Refuseless rejected the key (HTTP ${response.status}): ${await errorDetail(response)}`);
				}
				return key;
			},
		},
		async fetchDynamicModels(apiKey) {
			const response = await fetch(`${BASE_URL}/models`, {
				headers: apiKey ? { Authorization: `Bearer ${apiKey}` } : {},
			});
			if (!response.ok) {
				throw new Error(`Refuseless /v1/models failed (HTTP ${response.status}): ${await errorDetail(response)}`);
			}
			const payload = (await response.json()) as { data?: RefuselessModel[] };
			return (payload.data ?? []).filter(row => typeof row.id === "string" && row.id).map(toModelConfig);
		},
	});
}
