// OpenCode 2 plugin: every multi skill as an embedded skill (reaches the model
// as `@multi-<name>`) and as a slash command for the TUI (`/multi-<name>`).
//
// The skill bodies come from this repository at load time, so there is one copy
// of each instruction and no `!`-substitution on the way in: the body is text,
// and the probe inside it runs wherever the model runs it.
import { Plugin, Skill } from "@opencode/plugin";
import { CATALOG, skillPrompt, skillText } from "../shared/skills.mjs";

export default Plugin.define({
  id: "multi",
  async setup(ctx) {
    const skills = CATALOG.map((entry) => {
      const text = skillText(entry);
      return {
        id: Skill.ID.make(entry.command),
        name: Skill.Name.make(entry.command),
        description: entry.description,
        path: Skill.Info.fields.path.make(text.file),
        // The body already ends with its `[Skill directory: …]` line: the
        // skill path OpenCode shows the model is not guaranteed, and the body's
        // first step resolves the probe from that directory.
        content: text.text,
      };
    });

    await ctx.skill.transform((editor) => {
      for (const skill of skills) {
        editor.add(skill);
        editor.update(skill.id, (current) => {
          current.autoinvoke = true;
        });
      }
    });

    await ctx.command.transform((editor) => {
      for (const entry of CATALOG) {
        editor.add({
          name: entry.command,
          description: entry.description,
          execute: async ({ sessionID, prompt, delivery }) => {
            const { text } = skillPrompt(entry, prompt.text ?? "");
            await ctx.session.prompt({ ...prompt, sessionID, text, delivery });
          },
        });
      }
    });
  },
});
