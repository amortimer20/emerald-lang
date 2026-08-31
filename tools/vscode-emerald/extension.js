// Inline diagnostics for Emerald.
//
// Deliberately not a language server. The compiler already knows everything an LSP would
// report, so this runs `emerald check --json` and publishes what comes back. Plain
// JavaScript, so the extension still needs no build step.
//
// Limitation worth knowing: Emerald's diagnostics carry a line but not a column, so a
// squiggle covers the whole line. Columns need the scanner to track them.

const vscode = require("vscode");
const { exec } = require("child_process");
const path = require("path");

/** @param {vscode.ExtensionContext} context */
function activate(context) {
  const diagnostics = vscode.languages.createDiagnosticCollection("emerald");
  context.subscriptions.push(diagnostics);

  const output = vscode.window.createOutputChannel("Emerald");
  context.subscriptions.push(output);

  /** @param {vscode.TextDocument} document */
  function check(document) {
    if (document.languageId !== "emerald") return;

    const config = vscode.workspace.getConfiguration("emerald");
    const template = config.get("checkCommand");
    if (!template) return;

    const command = template.replace(/\{file\}/g, document.fileName);

    exec(command, { timeout: 15000 }, (error, stdout, stderr) => {
      let parsed;
      try {
        parsed = JSON.parse(stdout);
      } catch {
        // A non-JSON reply means the command itself failed — a wrong path, or emerald
        // not on PATH. Say so once in the output channel rather than silently doing
        // nothing, which is the failure mode that wastes an afternoon.
        output.appendLine(`emerald check failed for ${document.fileName}`);
        output.appendLine(`  command: ${command}`);
        if (stderr) output.appendLine(`  stderr: ${stderr.trim()}`);
        if (error && !stderr) output.appendLine(`  error: ${error.message}`);
        diagnostics.delete(document.uri);
        return;
      }

      // Diagnostics can name any file in the project, not just the one saved — a broken
      // file two directories away still breaks the build, and should be visible.
      const byFile = new Map();
      const projectDir = path.dirname(document.fileName);

      for (const item of parsed.diagnostics || []) {
        const file = path.join(projectDir, item.file);
        if (!byFile.has(file)) byFile.set(file, []);

        const line = Math.max(0, (item.line || 1) - 1);
        const range = new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER);

        const message = item.hint ? `${item.message}\n\n${item.hint}` : item.message;
        const diagnostic = new vscode.Diagnostic(
          range,
          message,
          vscode.DiagnosticSeverity.Error
        );
        diagnostic.source = "emerald";
        byFile.get(file).push(diagnostic);
      }

      diagnostics.clear();
      for (const [file, items] of byFile) {
        diagnostics.set(vscode.Uri.file(file), items);
      }
    });
  }

  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument(check),
    vscode.workspace.onDidOpenTextDocument(check),
    vscode.workspace.onDidCloseTextDocument((d) => diagnostics.delete(d.uri))
  );

  vscode.workspace.textDocuments.forEach(check);
}

function deactivate() {}

module.exports = { activate, deactivate };
