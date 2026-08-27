import { execFileSync } from "node:child_process";

const networkName = "local-network";
const optionName = "com.docker.network.bridge.host_binding_ipv4";

function docker(...args) {
  return execFileSync("docker", args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();
}

try {
  docker("network", "inspect", networkName);
} catch {
  docker("network", "create", "-o", `${optionName}=127.0.0.1`, networkName);
}

const binding = docker(
  "network",
  "inspect",
  networkName,
  "--format",
  `{{index .Options "${optionName}"}}`,
);

if (binding !== "127.0.0.1") {
  throw new Error(
    `Docker network ${networkName} must set ${optionName}=127.0.0.1; found ${binding || "unset"}.`,
  );
}

console.log(`Verified localhost-only Supabase network: ${networkName}`);
