import { execAsync } from "@dokploy/server/utils/process/execAsync";

/**
 * Archivo propio del fork Nettalco. Vive aparte para que los rebases con upstream
 * no lo toquen: en settings.ts solo quedan los dos enganches minimos.
 *
 * Dokploy compara su version contra dokploy/dokploy en Docker Hub y actualiza con
 * esa imagen. Este fork corre su propia imagen con el branding, asi que ese camino
 * la reemplazaria por la oficial. Con DOKPLOY_CUSTOM_IMAGE definida, el chequeo y
 * el update apuntan al registry propio.
 */

interface CustomImageUpdate {
	latestVersion: string | null;
	updateAvailable: boolean;
}

/**
 * Registries a los que se permite mandar credenciales. DOKPLOY_CUSTOM_IMAGE la define
 * el operador, y el host se usa tal cual en la cabecera Authorization: si apuntara a
 * otro lado, el PAT saldria del servidor. Ampliar solo a registries propios.
 */
const ALLOWED_REGISTRIES = new Set(["ghcr.io"]);

/** `ghcr.io/nettalco/dokploy:canary`, o vacio para usar el camino de upstream. */
export const getCustomImage = () => process.env.DOKPLOY_CUSTOM_IMAGE || "";

/**
 * Separa `ghcr.io/owner/repo:tag` en sus partes. Solo contempla registries sin
 * puerto, que es lo unico que usamos; `registry:5000/foo:tag` no esta soportado.
 */
export const parseImage = (image: string) => {
	const [ref, tag = "latest"] = image.split(":");
	const [registry, ...path] = (ref ?? "").split("/");
	return { registry: registry ?? "", repository: path.join("/"), tag };
};

/** Solo para pruebas: el conjunto de registries a los que se mandan credenciales. */
export const isAllowedRegistry = (registry: string) =>
	ALLOWED_REGISTRIES.has(registry);

/**
 * Ante la duda no ofrecer el update: un reemplazo innecesario de la imagen es peor
 * que no avisar de una build nueva.
 */
export const decideUpdate = (
	running: string | null,
	published: string | null,
	tag: string,
): CustomImageUpdate => {
	if (!published) {
		return { latestVersion: null, updateAvailable: false };
	}
	// Sin digest local (imagen construida en el servidor) no hay con que comparar.
	if (!running) {
		return { latestVersion: tag, updateAvailable: false };
	}
	return { latestVersion: tag, updateAvailable: running !== published };
};

/** Digest que corre ahora el servicio swarm, o null si la imagen no lo trae. */
const getRunningDigest = async () => {
	const { stdout } = await execAsync(
		"docker service inspect dokploy --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}'",
	);
	return stdout.trim().split("@")[1] || null;
};

/** Lee el token de archivo si se monto como secreto de swarm; si no, del entorno. */
const readRegistryToken = async () => {
	const file = process.env.DOKPLOY_REGISTRY_TOKEN_FILE;
	if (file) {
		const { readFile } = await import("node:fs/promises");
		return (await readFile(file, "utf8")).trim();
	}
	return process.env.DOKPLOY_REGISTRY_TOKEN || "";
};

/**
 * Digest publicado para ese tag. GHCR exige token aunque el paquete sea privado:
 * se pide con un PAT con read:packages.
 */
const getPublishedDigest = async (image: string) => {
	const { registry, repository, tag } = parseImage(image);

	if (!ALLOWED_REGISTRIES.has(registry)) {
		throw new Error(
			`Registry no permitido: ${registry}. Revisa DOKPLOY_CUSTOM_IMAGE.`,
		);
	}

	const user = process.env.DOKPLOY_REGISTRY_USER || "";
	const token = await readRegistryToken();

	const auth = await fetch(
		`https://${registry}/token?scope=repository:${repository}:pull&service=${registry}`,
		{
			headers: token
				? {
						Authorization: `Basic ${Buffer.from(`${user}:${token}`).toString("base64")}`,
					}
				: {},
		},
	);
	if (!auth.ok) {
		throw new Error(`No pude autenticar contra ${registry}: ${auth.status}`);
	}
	const { token: bearer } = (await auth.json()) as { token: string };

	// HEAD basta: el digest viaja en la cabecera, sin descargar el manifiesto.
	const manifest = await fetch(
		`https://${registry}/v2/${repository}/manifests/${tag}`,
		{
			method: "HEAD",
			headers: {
				Authorization: `Bearer ${bearer}`,
				Accept: [
					"application/vnd.oci.image.index.v1+json",
					"application/vnd.docker.distribution.manifest.list.v2+json",
					"application/vnd.oci.image.manifest.v1+json",
					"application/vnd.docker.distribution.manifest.v2+json",
				].join(", "),
			},
		},
	);
	if (!manifest.ok) {
		throw new Error(
			`No pude leer el manifiesto de ${image}: ${manifest.status}`,
		);
	}
	return manifest.headers.get("docker-content-digest");
};

/**
 * Compara digests en vez de numeros de version: el tag es movil (`canary` siempre
 * apunta a la ultima build), asi que semver no sirve aca.
 */
export const getCustomImageUpdate = async (
	image: string,
): Promise<CustomImageUpdate> => {
	const { tag } = parseImage(image);
	try {
		const [running, published] = await Promise.all([
			getRunningDigest(),
			getPublishedDigest(image),
		]);

		return decideUpdate(running, published, tag);
	} catch (error) {
		console.error("Error consultando el registry propio:", error);
		return { latestVersion: null, updateAvailable: false };
	}
};
