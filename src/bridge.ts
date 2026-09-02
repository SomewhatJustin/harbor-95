/**
 * PROTOTYPE: a deliberately flat NDJSON bridge between Tcl/Tk and Harbor's
 * real Node SDK. Base64 keeps Tcl's intentionally tiny JSON reader honest.
 */

import { mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { COLLECTION, v2 } from "@polycentric/js-core";
import { createPolycentricNodeClient } from "./node-client.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const dataDirectory = process.env.HARBOR95_DATA_DIR
	? path.resolve(process.env.HARBOR95_DATA_DIR)
	: path.resolve(here, "..", "harbormaster-95-PROTOTYPE-data");
const servers = (
	process.env.POLYCENTRIC_SEED_SERVERS ??
	"https://srv.harbor.social,https://srv.polycentric.io"
)
	.split(",")
	.map((server) => server.trim())
	.filter(Boolean);

const b64 = (value: unknown) =>
	Buffer.from(String(value ?? ""), "utf8").toString("base64");
const fromB64 = (value: unknown) =>
	Buffer.from(String(value ?? ""), "base64").toString("utf8");
const sleep = (milliseconds: number) =>
	new Promise((resolve) => setTimeout(resolve, milliseconds));

function send(message: Record<string, string | number | boolean>) {
	process.stdout.write(`${JSON.stringify(message)}\n`);
}

function fail(id: number, error: unknown) {
	const message = error instanceof Error ? error.message : String(error);
	send({ id, ok: false, type: "error", messageB64: b64(message) });
}

// Keep diagnostics away from the protocol stream.
console.log = (...values: unknown[]) => console.error(...values);
console.info = (...values: unknown[]) => console.error(...values);

await mkdir(dataDirectory, { recursive: true });
const client = await createPolycentricNodeClient({
	databasePath: path.join(dataDirectory, "harbormaster-95-PROTOTYPE.sqlite3"),
	blobDirectory: path.join(dataDirectory, "blobs"),
	seedServers: servers,
});

function decodePost(bundle: v2.EventBundle) {
	if (!bundle.signedEvent || !bundle.serializedContent?.contentBytes) {
		return null;
	}

	try {
		const event = v2.Event.fromBinary(bundle.signedEvent.eventBytes);
		const content = v2.Content.fromBinary(
			bundle.serializedContent.contentBytes,
		);
		if (content.contentBody.oneofKind !== "post") return null;

		return {
			id: Buffer.from(bundle.signedEvent.signature).toString("hex"),
			author: event.key?.identity ?? "unknown identity",
			createdAt: Number(event.createdAt ?? 0n),
			text: content.contentBody.post.text,
			images: content.contentBody.post.images.flatMap((set) => {
				const image = set.images.at(-1);
				const digest = image?.blob?.digest;
				return digest ? (client.blobUrl(digest) ?? []) : [];
			}),
		};
	} catch {
		return null;
	}
}

function localPosts() {
	if (!client.activeIdentityKey) return [];
	return client
		.listValidEvents(client.activeIdentityKey, COLLECTION.FEED)
		.map(decodePost)
		.filter((post) => post !== null);
}

async function remotePosts() {
	const timeout = new Promise<never>((_, reject) =>
		setTimeout(() => reject(new Error("server query timed out")), 7_000),
	);
	const bundles = await Promise.race([
		client.listEvents({ collection: COLLECTION.FEED, limit: 50 }),
		timeout,
	]);
	return bundles.map(decodePost).filter((post) => post !== null);
}

async function emitFeed(id: number, includeRemote: boolean) {
	send({ id, ok: true, type: "feed_start" });
	let posts = localPosts();
	let notice = "";

	if (includeRemote) {
		try {
			const remote = await remotePosts();
			const merged = new Map(posts.map((post) => [post.id, post]));
			for (const post of remote) merged.set(post.id, post);
			posts = [...merged.values()];
		} catch (error) {
			notice = error instanceof Error ? error.message : String(error);
		}
	}

	posts.sort((a, b) => b.createdAt - a.createdAt);
	for (const post of posts) {
		send({
			id,
			ok: true,
			type: "feed_item",
			authorB64: b64(post.author),
			createdAtB64: b64(new Date(post.createdAt).toLocaleString()),
			textB64: b64(post.text),
			imagesB64: b64(post.images.join("\n")),
		});
	}
	send({
		id,
		ok: true,
		type: "feed_end",
		count: posts.length,
		messageB64: b64(notice),
	});
}

function emitState(id: number, message = "Standing by.") {
	send({
		id,
		ok: true,
		type: "state",
		identityB64: b64(client.activeIdentityKey ?? "NO IDENTITY"),
		serversB64: b64(client.servers.join(", ")),
		messageB64: b64(message),
	});
}

type PairingSessionInfo = {
	origin: string;
	identity: string;
	code: string;
};

/** Accept Harbor Web's copied hex token as well as the raw JSON in its QR. */
function decodePairingCode(input: string): PairingSessionInfo {
	const trimmed = input.trim();
	let parsed: unknown;
	try {
		if (!trimmed.startsWith("{") && !/^(?:[0-9a-fA-F]{2})+$/.test(trimmed)) {
			throw new Error("not hex");
		}
		const json = trimmed.startsWith("{")
			? trimmed
			: Buffer.from(trimmed, "hex").toString("utf8");
		parsed = JSON.parse(json) as unknown;
	} catch {
		throw new Error("Invalid pairing code.");
	}
	if (!parsed || typeof parsed !== "object") {
		throw new Error("Invalid pairing code.");
	}
	const value = parsed as Record<string, unknown>;
	if (
		typeof value.origin !== "string" ||
		typeof value.identity !== "string" ||
		typeof value.code !== "string"
	) {
		throw new Error("Invalid pairing code.");
	}
	const protocol = new URL(value.origin).protocol;
	if (protocol !== "http:" && protocol !== "https:") {
		throw new Error("Pairing server must use HTTP or HTTPS.");
	}
	return {
		origin: value.origin,
		identity: value.identity,
		code: value.code,
	};
}

async function pairIdentity(id: number, encodedCode: string) {
	const sessionInfo = decodePairingCode(encodedCode);
	const status = await client.pairingSessionManager.joinPairingSession(
		sessionInfo.code,
		sessionInfo.origin,
	);
	if (status.pairingSession.issuerIdentity !== sessionInfo.identity) {
		throw new Error("Pairing session identity does not match the issuer.");
	}

	send({
		id,
		ok: true,
		type: "pairing_progress",
		messageB64: b64("Waiting for approval on your other device..."),
	});

	let marker: bigint | null = null;
	const expiresAt = status.pairingSession.expiresAt.getTime();
	while (Date.now() < expiresAt) {
		const nextMarker = await client.identityManager
			.pollRemoteIdentityMarker(sessionInfo.identity, sessionInfo.origin)
			.catch(() => marker);

		if (nextMarker !== null && nextMarker !== marker) {
			if (!client.servers.includes(sessionInfo.origin)) {
				client.servers.push(sessionInfo.origin);
				client.core.setServers(client.servers);
			}
			const identity = await client.identityManager.claim(sessionInfo.identity);
			if (identity) {
				send({
					id,
					ok: true,
					type: "pairing_complete",
					messageB64: b64("Identity paired successfully."),
				});
				emitState(id, "Identity paired successfully.");
				await emitFeed(id, false);
				return;
			}
			marker = nextMarker;
		}
		await sleep(2_000);
	}

	throw new Error("The pairing session expired before it was approved.");
}

type Request = {
	id?: number;
	action?: string;
	textB64?: string;
	imagePathsB64?: string;
};

async function processImage(imagePath: string): Promise<v2.ImageSet> {
	const source = new Uint8Array(await readFile(imagePath));
	const variants = await Promise.all(
		[512, 1280].map(async (size) => {
			const { bytes, width, height } = client.processImageToJpeg(
				source,
				size,
				size,
				"fit",
			);
			const blob = await client.commitBlob(bytes, "image/jpeg");
			return {
				image: v2.Image.create({ blob, width, height }),
				bytes,
			};
		}),
	);
	await Promise.all(
		variants.map(({ image, bytes }) =>
			image.blob ? client.uploadBlob(image.blob, bytes) : Promise.resolve(),
		),
	);
	return v2.ImageSet.create({
		images: variants.map(({ image }) => image),
	});
}

async function dispatch(request: Request) {
	const id = Number(request.id ?? 0);
	switch (request.action) {
		case "state":
			emitState(id);
			await emitFeed(id, false);
			return;

		case "bootstrap": {
			if (!client.currentKeyPair) throw new Error("SDK has no key pair");
			if (!client.activeIdentityKey) {
				await client.identityManager.publish({
					rotationKeys: [client.currentKeyPair.publicKey],
					signingKeys: [],
					servers: client.servers,
				});
			}
			emitState(id, "Identity created.");
			await emitFeed(id, false);
			return;
		}

		case "create_post": {
			if (!client.activeIdentityKey) {
				throw new Error("Create or pair an identity before publishing.");
			}
			const text = fromB64(request.textB64).trim();
			const imagePaths = String(request.imagePathsB64 ?? "")
				.split(",")
				.filter(Boolean)
				.map(fromB64);
			if (!text && imagePaths.length === 0) {
				throw new Error("Add text or at least one image before publishing.");
			}
			if (imagePaths.length > 4) {
				throw new Error("A post can contain at most four images.");
			}
			const images = await Promise.all(imagePaths.map(processImage));
			const content = client.contentManager.build({
				oneofKind: "post",
				post: {
					text,
					images,
					links: [],
					labels: ["harbor"],
					attributedTo: [],
				},
			});
			await client.contentManager.save(content);
			const event = await client.buildEvent(content);
			const signedEvent = await client.signEvent(event);
			await client.commitEvent(signedEvent, content);

			let message = "Post signed and saved locally.";
			try {
				await client.sync();
				message = "Post published.";
			} catch (error) {
				const reason = error instanceof Error ? error.message : String(error);
				message = `Post saved locally; synchronization failed: ${reason}`;
			}
			send({
				id,
				ok: true,
				type: "post_complete",
				messageB64: b64(message),
			});
			emitState(id, message);
			await emitFeed(id, false);
			return;
		}

		case "refresh":
			await emitFeed(id, true);
			return;

		case "sync": {
			if (!client.activeIdentityKey) {
				throw new Error("Create an identity before synchronizing.");
			}
			let message = "Synchronization complete.";
			try {
				await client.sync();
			} catch (error) {
				message = `Synchronization failed: ${
					error instanceof Error ? error.message : String(error)
				}`;
			}
			emitState(id, message);
			await emitFeed(id, true);
			return;
		}

		case "pair_identity":
			await pairIdentity(id, fromB64(request.textB64));
			return;

		case "shutdown":
			send({ id, ok: true, type: "goodbye" });
			return process.exit(0);

		default:
			throw new Error(`Unknown bridge action: ${request.action}`);
	}
}

const input = createInterface({ input: process.stdin, terminal: false });
input.on("line", (line) => {
	let request: Request;
	try {
		request = JSON.parse(line) as Request;
	} catch (error) {
		fail(0, error);
		return;
	}
	void dispatch(request).catch((error) => fail(Number(request.id ?? 0), error));
});

send({
	id: 0,
	ok: true,
	type: "ready",
	messageB64: b64("NODE/WASM SDK CONNECTED"),
});
