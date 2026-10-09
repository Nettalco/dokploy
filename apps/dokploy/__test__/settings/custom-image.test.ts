import {
	decideUpdate,
	parseImage,
} from "@dokploy/server/services/custom-image";
import { describe, expect, it } from "vitest";

const DIGEST_A = "sha256:aaaa";
const DIGEST_B = "sha256:bbbb";

describe("parseImage", () => {
	it("separa registry, repositorio y tag", () => {
		expect(parseImage("ghcr.io/nettalco/dokploy:canary")).toEqual({
			registry: "ghcr.io",
			repository: "nettalco/dokploy",
			tag: "canary",
		});
	});

	it("asume latest cuando no hay tag", () => {
		expect(parseImage("ghcr.io/nettalco/dokploy").tag).toBe("latest");
	});
});

describe("decideUpdate", () => {
	it("ofrece el update cuando los digests difieren", () => {
		expect(decideUpdate(DIGEST_A, DIGEST_B, "canary")).toEqual({
			latestVersion: "canary",
			updateAvailable: true,
		});
	});

	it("no ofrece nada cuando el digest es el mismo", () => {
		expect(decideUpdate(DIGEST_A, DIGEST_A, "canary").updateAvailable).toBe(
			false,
		);
	});

	// Una imagen construida en el servidor no trae digest: sin comparacion posible,
	// ofrecer el update reemplazaria la imagen propia por la del registry.
	it("no ofrece el update si la imagen local no tiene digest", () => {
		expect(decideUpdate(null, DIGEST_B, "canary").updateAvailable).toBe(false);
	});

	it("no ofrece el update si el registry no respondio digest", () => {
		expect(decideUpdate(DIGEST_A, null, "canary")).toEqual({
			latestVersion: null,
			updateAvailable: false,
		});
	});
});
