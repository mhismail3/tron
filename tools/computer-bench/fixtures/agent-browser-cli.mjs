#!/usr/bin/env node
// Purpose: process-boundary fixture for a CLI daemon holding a consent handshake and reporting cleanup failure.
import { createConnection, createServer } from "node:net";
import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const directory = process.env.AGENT_BROWSER_SOCKET_DIR;
if (process.env.AGENT_BROWSER_DAEMON) {
  const session = process.env.AGENT_BROWSER_SESSION;
  let cdpUrl;
  const server = createServer((client) => {
    let input = "";
    client.on("error", () => {});
    client.on("data", (chunk) => {
      input += chunk;
      if (!input.includes("\n")) return;
      const [command, endpoint] = JSON.parse(input.trim());
      const reply = (value) => client.end(JSON.stringify(value));
      if (command === "connect") {
        cdpUrl = endpoint;
        if (process.env.COMPUTER_BENCH_FIXTURE_MODE === "pending") {
          const url = new URL(endpoint);
          const pending = createConnection({ host: url.hostname, port: Number(url.port) });
          pending.on("error", () => {});
        } else reply({ success: true, data: {} });
      } else if (process.env.COMPUTER_BENCH_FIXTURE_MODE === "success") {
        if (command === "get") reply({ success: true, data: endpoint === "cdp-url" ? { cdpUrl } : { title: "Bench Form" } });
        else if (command === "tab") reply({ success: true, data: { tabId: "t1" } });
        else { reply({ success: true, data: { closed: true } }); server.close(); }
      } else if (command === "get") reply({ success: false, error: "primary fixture read failed" });
      else reply({ success: false, error: "secondary fixture cleanup failed" });
    });
  });
  server.listen(join(directory, `${session}.sock`), () => {
    writeFileSync(join(process.env.COMPUTER_BENCH_FIXTURE_OWNER_DIRECTORY, `fixture-${process.pid}.json`), JSON.stringify({ pid: process.pid, directory, socket: join(directory, `${session}.sock`) }));
    writeFileSync(join(directory, `${session}.pid`), process.env.COMPUTER_BENCH_FIXTURE_MODE === "foreign" ? process.env.COMPUTER_BENCH_FIXTURE_FOREIGN_PID : String(process.pid));
  });
} else {
  const args = process.argv.slice(2);
  const index = args.indexOf("--session");
  const session = args[index + 1];
  const path = join(directory, `${session}.sock`);
  if (!existsSync(path)) {
    spawn(process.execPath, [import.meta.filename], {
      env: { ...process.env, AGENT_BROWSER_DAEMON: "1", AGENT_BROWSER_SESSION: session },
      detached: true, stdio: "ignore",
    }).unref();
    for (let attempt = 0; attempt < 100 && !existsSync(path); attempt++) await delay(10);
  }
  const client = createConnection(path, () => client.write(JSON.stringify(args.slice(index + 2)) + "\n"));
  client.on("data", (chunk) => process.stdout.write(chunk));
  client.on("error", (error) => { process.stderr.write(error.message); process.exitCode = 1; });
}
