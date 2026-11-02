// OpenCode 2 plugin: every multi skill as an embedded skill (reaches the model
// as `@multi-<name>`) and as a slash command for the TUI (`/multi-<name>`).
//
// The skill bodies come from this repository at load time, so there is one copy
// of each instruction and no `!`-substitution on the way in: the body is text,
// and the probe inside it runs wherever the model runs it.
import { readFileSync } from "node:fs";
import { Plugin, Skill } from "@opencode/plugin";
import { CATALOG, skillPath, skillPrompt, stripFrontmatter } from "../shared/skills.mjs";

export default Plugin.define({
  id: "multi",
  async setup(ctx) {
    const skills = CATALOG.map((entry) => {
      const file = skillPath(entry.skill);
      return {
        id: Skill.ID.make(entry.command),
        name: Skill.Name.make(entry.command),
        description: entry.description,
        path: Skill.Info.fields.path.make(file),
        content: stripFrontmatter(readFileSync(file, "utf8")),
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
