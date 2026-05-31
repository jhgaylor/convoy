// Convoy builder: a tiny, isolated compile service.
//
// POST /compile  {"language": "rust"|"tinygo"|"assemblyscript", "source": "..."}
//   -> 200 application/wasm  (the compiled module bytes)
//   -> 422 text/plain        (compiler error message)
// GET  /healthz -> 200
//
// This process compiles UNTRUSTED source, so it runs in its own locked-down
// pod (no secrets, no service-account token, NetworkPolicy denying egress,
// non-root, resource-limited). Defenses here are belt-and-suspenders: a hard
// timeout that kills the whole process group, per-request throwaway temp dirs,
// and size caps. Each compiler is invoked single-file (no deps, no build
// scripts). The commands mirror Convoy.Compile in the app.

const http = require("http");
const { spawn } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const PORT = parseInt(process.env.PORT || "8080", 10);
const TIMEOUT_MS = 20_000;
const MAX_SOURCE = 256 * 1024; // 256 KB of source is plenty for a bot
const MAX_WASM = 16 * 1024 * 1024;

// language -> { ext, cmd, args(inFile, outFile) }. Must produce a zero-import
// module (the sim instantiates with an empty import set).
const LANGS = {
  rust: {
    ext: "rs",
    cmd: "rustc",
    args: (i, o) => ["--target", "wasm32-unknown-unknown", "-O", "--crate-type", "cdylib", "-o", o, i],
  },
  tinygo: {
    ext: "go",
    cmd: "tinygo",
    args: (i, o) => ["build", "-target=wasm-unknown", "-scheduler=none", "-gc=leaking", "-no-debug", "-o", o, i],
  },
  assemblyscript: {
    ext: "ts",
    cmd: "asc",
    args: (i, o) => [i, "-o", o, "--runtime", "stub", "--optimize"],
  },
};

function compile(language, source, cb) {
  const lang = LANGS[language];
  if (!lang) return cb({ status: 422, message: `unknown language: ${language}` });

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "convoy-build-"));
  const inFile = path.join(dir, `bot.${lang.ext}`);
  const outFile = path.join(dir, "bot.wasm");
  const cleanup = () => fs.rm(dir, { recursive: true, force: true }, () => {});

  try {
    fs.writeFileSync(inFile, source);
  } catch (e) {
    cleanup();
    return cb({ status: 500, message: "could not stage source" });
  }

  // detached so we get a new process group we can SIGKILL wholesale on timeout
  // (compilers may fork children). We inherit the image's env — it carries
  // RUSTUP_HOME/CARGO_HOME/GOROOT/PATH that the toolchains need, and the
  // builder pod holds no secrets (isolation is the pod boundary, not the env).
  const child = spawn(lang.cmd, lang.args(inFile, outFile), {
    cwd: dir,
    detached: true,
    env: process.env,
  });

  let stderr = "";
  let done = false;
  child.stderr.on("data", (d) => { if (stderr.length < 8192) stderr += d.toString(); });
  child.stdout.on("data", (d) => { if (stderr.length < 8192) stderr += d.toString(); });

  const timer = setTimeout(() => {
    done = true;
    try { process.kill(-child.pid, "SIGKILL"); } catch (_) {}
    cleanup();
    cb({ status: 422, message: `compilation timed out after ${TIMEOUT_MS / 1000}s` });
  }, TIMEOUT_MS);

  child.on("error", (e) => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    cleanup();
    cb({ status: 500, message: `failed to start ${lang.cmd}: ${e.message}` });
  });

  child.on("close", (code) => {
    if (done) return;
    done = true;
    clearTimeout(timer);
    if (code !== 0 || !fs.existsSync(outFile)) {
      cleanup();
      return cb({ status: 422, message: stderr.trim() || `compiler exited ${code}` });
    }
    let wasm;
    try {
      wasm = fs.readFileSync(outFile);
    } catch (e) {
      cleanup();
      return cb({ status: 500, message: "could not read output" });
    }
    cleanup();
    if (wasm.length > MAX_WASM) return cb({ status: 422, message: "output too large" });
    cb({ wasm });
  });
}

const server = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/healthz") {
    res.writeHead(200, { "content-type": "text/plain" });
    return res.end("ok");
  }
  if (req.method !== "POST" || req.url !== "/compile") {
    res.writeHead(404);
    return res.end("not found");
  }

  let body = "";
  let aborted = false;
  req.on("data", (chunk) => {
    body += chunk;
    if (body.length > MAX_SOURCE && !aborted) {
      aborted = true;
      res.writeHead(413, { "content-type": "text/plain" });
      res.end("source too large");
      req.destroy();
    }
  });
  req.on("end", () => {
    if (aborted) return;
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch (_) {
      res.writeHead(400, { "content-type": "text/plain" });
      return res.end("invalid JSON");
    }
    compile(parsed.language, parsed.source || "", (result) => {
      if (result.wasm) {
        res.writeHead(200, { "content-type": "application/wasm" });
        return res.end(result.wasm);
      }
      res.writeHead(result.status || 422, { "content-type": "text/plain" });
      res.end(result.message || "compile failed");
    });
  });
});

server.listen(PORT, () => console.log(`convoy-builder listening on :${PORT}`));
