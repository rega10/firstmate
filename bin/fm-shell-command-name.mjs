#!/usr/bin/env node

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function commandNames(source, depth = 0) {
  if (depth > 12) return [];
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return [];
  const names = [];
  for (const tokens of splitProgram(lexed.tokens).nodes) {
    const position = commandPosition(tokens);
    if (position.command?.literal && position.command.subs.length === 0) {
      names.push(basename(position.command.value));
    }
    for (const payload of position.wrapperPayloads) {
      names.push(...commandNames(payload, depth + 1));
    }
  }
  return names;
}

const names = commandNames(process.argv[2] || "");
const selected = names.includes("claude") ? "claude" : names[0] || "";
if (selected) process.stdout.write(`${selected}\n`);
