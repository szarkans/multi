// One place where a skill body becomes the text a host sends. Both harness
// adapters read the same catalog and the same frontmatter strip, so a command
// name and a skill body cannot drift apart between hosts.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export const CATALOG = JSON.parse(readFileSync(join(ROOT, "harnesses/skills.json"), "utf8"));

export function skillPath(skill) {
  return join(ROOT, "skills", skill, "SKILL.md");
}

export function stripFrontmatter(text) {
  return text.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, "");
}

// The body plus the one line that says where the skill lives: its first step
// is `<dir of this SKILL.md>/../../scripts/probe.sh`, and a host that does not
// echo the skill's path into the model's context would leave that step with no
// directory to resolve. Nothing here expands `!` lines or shell
// substitutions: a host without them still gets the whole instruction.
export function skillText(entry) {
  const file = skillPath(entry.skill);
  const dir = dirname(file);
  const body = stripFrontmatter(readFileSync(file, "utf8")).trim();
  return { file, dir, text: `${body}\n\n[Skill directory: ${dir}]\n` };
}

export function skillPrompt(entry, args) {
  const { file, dir, text } = skillText(entry);
  const tail = String(args ?? "").trim();
  return {
    file,
    dir,
    text: `The user invoked the multi skill "${entry.skill}".\n\n${text}` + (tail ? `\nUser: ${tail}\n` : ""),
  };
}
