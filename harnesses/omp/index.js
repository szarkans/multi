// omp extension: one slash command per multi skill, named `multi-<skill>`.
// The command body is the skill itself, so the model reads the same
// instructions here as in every other harness; the probe runs inside the body,
// not at registration time — `omp plugin install` imports this module on a
// throwaway surface where runtime calls do not exist yet.
import { CATALOG, skillPrompt } from "../shared/skills.mjs";

export default function multi(pi) {
  for (const entry of CATALOG) {
    pi.registerCommand(entry.command, {
      description: entry.description,
      handler: async (args, ctx) => {
        try {
          const { text } = skillPrompt(entry, args);
          // sendMessage with triggerTurn, not sendUserMessage: a command runs
          // inside prompt processing, so a plain user message would be queued
          // behind a turn that is already over in print mode. This starts one.
          await pi.sendMessage(
            {
              customType: "multi-skill",
              content: text,
              display: true,
              attribution: "user",
            },
            { triggerTurn: true },
          );
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          // Print mode and headless hosts have no notify surface; losing the
          // original message to a TypeError on a missing UI would hide why the
          // command failed.
          if (ctx?.ui?.notify) ctx.ui.notify(`multi ${entry.command}: ${message}`, "error");
          else console.error(`multi ${entry.command}: ${message}`);
        }
      },
    });
  }
}
