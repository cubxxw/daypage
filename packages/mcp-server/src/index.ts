#!/usr/bin/env node
import { loadConfig } from "./config.js";
import { createDayPageHttpServer } from "./http.js";

const config = loadConfig();
const server = createDayPageHttpServer(config);

server.listen(config.port, config.host, () => {
  process.stdout.write(
    JSON.stringify({ event: "listening", service: "daypage-cloud-mcp", host: config.host, port: config.port }) + "\n",
  );
});

async function shutdown(signal: string): Promise<void> {
  process.stdout.write(JSON.stringify({ event: "shutdown", signal }) + "\n");
  server.close((error) => process.exit(error ? 1 : 0));
}

process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));
