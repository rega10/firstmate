#!/usr/bin/env node

import { Lexer, splitProgram, commandPosition, shellInvocation, evalPayload, startsShellControlGrammar } from "./fm-arm-command-policy.mjs";

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function commandNames(source, depth = 0) {
  if (depth > 12) return null;
  const lexed = new Lexer(source).tokenize();
  if (lexed.error) return null;
  const names = [];
  for (const tokens of splitProgram(lexed.tokens).nodes) {
    if (startsShellControlGrammar(tokens) || tokens.some((token) => token.type === "group")) return null;
    const position = commandPosition(tokens);
    if (position.unresolvedWrapperOption) return null;
    if (position.command) {
      if (!position.command.literal || position.command.subs.length > 0) return null;
      names.push(basename(position.command.value));
    }
    for (const payload of position.wrapperPayloads) {
      const nested = commandNames(payload, depth + 1);
      if (nested === null) return null;
      names.push(...nested);
    }
    for (const token of tokens) {
      if (token.type === "group") {
        const nested = commandNames(token.content, depth + 1);
        if (nested === null) return null;
        names.push(...nested);
      }
      if (token.type !== "word") continue;
      for (const substitution of token.subs) {
        const nested = commandNames(substitution.content, depth + 1);
        if (nested === null) return null;
        names.push(...nested);
      }
    }
    const shell = shellInvocation(position);
    if (shell?.kind === "command" && shell.payload) {
      if (!shell.payload.literal || shell.payload.subs.length > 0) return null;
      const nested = commandNames(shell.payload.value, depth + 1);
      if (nested === null) return null;
      names.push(...nested);
    }
    const evaluated = evalPayload(position);
    if (basename(position.command?.value || "") === "eval" && position.words.length > position.index + 1 && evaluated === null) return null;
    if (evaluated !== null) {
      const nested = commandNames(evaluated, depth + 1);
      if (nested === null) return null;
      names.push(...nested);
    }
  }
  return names;
}

const names = commandNames(process.argv[2] || "");
const selected = names?.includes("claude") ? "claude" : names?.[0] || "";
if (selected) {
  process.stdout.write(`${selected}\n`);
} else {
  process.exitCode = 1;
}
