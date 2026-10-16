import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { liveSessionRequest } from "../src/live.js";

const PILOT_MINIMAL_WHEN_GENERAL_INSTRUCTIONS = [
  'You are a concise conversational voice liaison for the selected Pi coding agent "general".',
  "Delegation policy:",
  "Backend tools:",
  '- Selected Pi agent "general": answers questions, inspects its existing context, uses its authorized tools, and performs requested work.',
  "Delegate to the backend when:",
  "- The user asks the selected Pi agent to answer, inspect context, use tools, or do work. Emit a client delegation before answering; do not do the backend work yourself.",
  "Do not delegate to the backend when:",
  "- The user greets you, makes ordinary small talk, or asks only for conversational clarification.",
].join("\n");
const PILOT_MINIMAL_WHEN_GENERAL_INSTRUCTIONS_SHA256 = "9b61d8ef09587602e35941f7768b15fa6d3161645362958ebd76e2fd47a68dbe";

test("liaison startup exactly uses the successful pilot prompt with dynamic sanitized agent substitution", () => {
  const general = liveSessionRequest("general", "pilot-webrtc-sdp", "marin", "liaison");
  assert.equal(general.session.instructions, PILOT_MINIMAL_WHEN_GENERAL_INSTRUCTIONS);
  assert.equal(
    createHash("sha256").update(general.session.instructions).digest("hex"),
    PILOT_MINIMAL_WHEN_GENERAL_INSTRUCTIONS_SHA256
  );
  assert.deepEqual(
    { ...general, session: { ...general.session, instructions: "<pilot-minimal-when>" } },
    {
      session: {
        model: "gpt-live-1",
        store: false,
        instructions: "<pilot-minimal-when>",
        audio: { output: { voice: "marin" } },
        delegation: { type: "client" },
      },
      transport: { type: "webrtc", sdp: "pilot-webrtc-sdp" },
    }
  );

  const substituted = liveSessionRequest("General\n  Research", "dynamic-webrtc-sdp", "quartz", "liaison");
  assert.equal(
    substituted.session.instructions,
    PILOT_MINIMAL_WHEN_GENERAL_INSTRUCTIONS.replaceAll('"general"', '"General Research"')
  );
  assert.deepEqual(
    { ...substituted, session: { ...substituted.session, instructions: "<dynamic-pilot-minimal-when>" } },
    {
      session: {
        model: "gpt-live-1",
        store: false,
        instructions: "<dynamic-pilot-minimal-when>",
        audio: { output: { voice: "quartz" } },
        delegation: { type: "client" },
      },
      transport: { type: "webrtc", sdp: "dynamic-webrtc-sdp" },
    }
  );
});
