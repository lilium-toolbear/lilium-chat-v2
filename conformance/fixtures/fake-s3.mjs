// Conformance S3 fixture store (issue #27 batch B/C).
//
// A minimal deterministic S3 stand-in so the presign/finalize/upload
// scenarios run self-contained against the SAME object store on both
// targets (spec §7.1: "the script IS the fixture" — the store is the
// fixture's external state).
//
// Topology (mirrors production gina, minus the nginx bucket re-injection):
//   * browser/harness PUT  -> {S3_ENDPOINT}/{key}        (path WITHOUT bucket;
//     the signature was computed over /{bucket}/{key} — a real store like
//     production SeaweedFS would verify against the re-injected path; this
//     fixture does not verify SigV4, both sides sign identical creds)
//   * app finalize HEAD    -> {S3_PUBLIC_BASE}/{key}     (public-read, no auth)
//
// Objects are keyed by EXACT request path and hold the PUT body + the
// Content-Type the PUT sent. HEAD answers with exactly that content-type and
// content-length, which is the only contract surface finalize checks
// (contract §8.2: "检查对象已存在（HEAD）+ 校验 Content-Type 与 Content-Length
// 一致").
//
// In-memory: state resets when the container restarts; scenario runs use
// unique UUID keys so cross-run residue can never collide.

import { createHash } from "node:crypto";
import http from "node:http";

const PORT = Number(process.env.FAKE_S3_PORT ?? 8900);

/** @type {Map<string, { body: Buffer, contentType: string }>} */
const objects = new Map();

// Content-hash etag: scenario PUTs send IDENTICAL bytes to both targets, so
// the etag — captured in the diff — is deterministic across targets even
// though the two targets' object KEY paths differ (contract key `chat/{id}`
// vs old-Worker legacy `chat/attachments/{id}.{ext}`).
const etagFor = (body) => `"${createHash("sha256").update(body).digest("hex").slice(0, 16)}"`;

const server = http.createServer((req, res) => {
  const path = (req.url ?? "/").split("?")[0];
  const chunks = [];
  req.on("data", (c) => chunks.push(c));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    if (req.method === "PUT") {
      const contentType =
        (typeof req.headers["content-type"] === "string" && req.headers["content-type"]) ||
        "application/octet-stream";
      objects.set(path, { body, contentType });
      res.writeHead(200, { etag: etagFor(body) });
      res.end();
    } else if (req.method === "HEAD") {
      const o = objects.get(path);
      if (o) {
        res.writeHead(200, {
          "content-type": o.contentType,
          "content-length": String(o.body.length),
          etag: etagFor(o.body),
        });
      } else {
        res.writeHead(404, { "content-type": "application/xml" });
      }
      res.end();
    } else if (req.method === "GET") {
      const o = objects.get(path);
      if (o) {
        res.writeHead(200, {
          "content-type": o.contentType,
          "content-length": String(o.body.length),
          etag: etagFor(o.body),
        });
        res.end(o.body);
      } else {
        res.writeHead(404, { "content-type": "application/xml" });
        res.end("<Error><Code>NoSuchKey</Code></Error>");
      }
    } else {
      res.writeHead(405, { "content-type": "application/xml" });
      res.end();
    }
  });
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`fake-s3 listening on :${PORT}`);
});
