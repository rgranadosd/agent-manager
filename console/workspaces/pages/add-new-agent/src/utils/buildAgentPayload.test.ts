import { describe, it, expect } from "vitest";
import { buildModelConfig } from "./buildAgentPayload";
import type { LLMProviderFormEntry } from "../form/schema";

function entry(over: Partial<LLMProviderFormEntry> = {}): LLMProviderFormEntry {
  return {
    selectedProviderByEnv: { Development: { uuid: "u1", handle: "openai" } },
    urlVarName: undefined,
    apikeyVarName: undefined,
    guardrails: [],
    ...over,
  };
}

describe("buildModelConfig (flat shape)", () => {
  it("maps a single provider with no env overrides", () => {
    const out = buildModelConfig([entry()]);
    expect(out).toEqual([{ providerName: "openai" }]);
  });

  it("includes env-var name overrides", () => {
    const out = buildModelConfig([entry({ urlVarName: "MY_URL", apikeyVarName: "MY_KEY" })]);
    expect(out?.[0]).toMatchObject({
      providerName: "openai",
      environmentVariables: [
        { key: "url", name: "MY_URL" },
        { key: "apikey", name: "MY_KEY" },
      ],
    });
  });

  it("preserves guardrail policies in configuration", () => {
    const out = buildModelConfig([entry({
      guardrails: [{ name: "pii", version: "v1", settings: { mode: "block" } }],
    })]);
    expect(out?.[0].configuration?.policies).toEqual([
      { name: "pii", version: "v1", paths: [{ path: "/*", methods: ["*"], params: { mode: "block" } }] },
    ]);
  });

  it("returns undefined when no providers", () => {
    expect(buildModelConfig([])).toBeUndefined();
  });
});
