import type { Network } from "@lucid-evolution/lucid";

export const {
  KUPO_ENDPOINT,
  OGMIOS_ENDPOINT,
  DEPLOYER_SEED,
  OUT_FOLDER = "../deployments",
} = Bun.env;

/// `Network` is a union, and `Bun.env` is all strings.
export const NETWORK = (Bun.env.NETWORK ?? "Preprod") as Network;

export function requireEnv(): void {
  const missing = ["KUPO_ENDPOINT", "OGMIOS_ENDPOINT", "DEPLOYER_SEED"].filter(
    (k) => !Bun.env[k],
  );
  if (missing.length) {
    console.error(
      `Missing ${missing.join(", ")}. Copy releases/.env.example to releases/.env and fill it in.`,
    );
    process.exit(1);
  }
}
