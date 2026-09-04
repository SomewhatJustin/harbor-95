/**
 * Node platform adapter derived from @polycentric/js-node. Keeping the small
 * SQLite/filesystem adapter here avoids its unpublished PostgreSQL dependency.
 */

import * as crypto from "node:crypto";
import { promises as fs } from "node:fs";
import { createRequire } from "node:module";
import * as path from "node:path";
import {
	type IFileStoreDriver,
	PolycentricClient,
	toDigestKey,
	v2,
} from "@polycentric/js-core";
import {
	DrizzleStorageDriver,
	migrate as migrateSqlite,
	type SqliteDb,
} from "@polycentric/js-storage-sqlite";
import { PolycentricCore, uniffiInitAsync } from "@polycentric/rs-core-wasm";
import Database from "better-sqlite3";
import { drizzle } from "drizzle-orm/better-sqlite3";

const { version: applicationVersion } = createRequire(import.meta.url)(
	"../package.json",
) as { version: string };

const application = v2.Application.create({
	name: "Harbor 95",
	id: "io.github.somewhatjustin.harbor95",
	version: applicationVersion,
	url: "https://github.com/SomewhatJustin/harbor-95",
});

class NodeFileStoreDriver implements IFileStoreDriver {
	private constructor(private readonly directory: string) {}

	static async create(directory: string): Promise<NodeFileStoreDriver> {
		await fs.mkdir(directory, { recursive: true });
		return new NodeFileStoreDriver(directory);
	}

	private pathFor(digest: v2.ContentDigest): string {
		return path.join(this.directory, toDigestKey(digest));
	}

	async has(digest: v2.ContentDigest): Promise<boolean> {
		try {
			await fs.access(this.pathFor(digest));
			return true;
		} catch {
			return false;
		}
	}

	async get(digest: v2.ContentDigest): Promise<Uint8Array | null> {
		try {
			const buffer = await fs.readFile(this.pathFor(digest));
			return new Uint8Array(
				buffer.buffer,
				buffer.byteOffset,
				buffer.byteLength,
			);
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
			throw error;
		}
	}

	async put(digest: v2.ContentDigest, bytes: Uint8Array): Promise<void> {
		const destination = this.pathFor(digest);
		const temporary = `${destination}.tmp.${crypto.randomBytes(8).toString("hex")}`;
		await fs.writeFile(temporary, bytes);
		await fs.rename(temporary, destination);
	}

	async delete(digest: v2.ContentDigest): Promise<void> {
		try {
			await fs.unlink(this.pathFor(digest));
		} catch (error) {
			if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
		}
	}
}

type ClientConfig = {
	databasePath: string;
	blobDirectory: string;
	seedServers?: string[];
};

export async function createPolycentricNodeClient(config: ClientConfig) {
	await uniffiInitAsync();
	const rawDatabase = new Database(config.databasePath);
	const database = drizzle(rawDatabase) as unknown as SqliteDb;
	await migrateSqlite(database);

	return PolycentricClient.create({
		core: new PolycentricCore(),
		storageDriver: new DrizzleStorageDriver(database),
		filestoreDriver: await NodeFileStoreDriver.create(config.blobDirectory),
		application,
		...(config.seedServers ? { seedServers: config.seedServers } : {}),
	});
}
