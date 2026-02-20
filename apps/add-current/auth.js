import express from "express";
import fetch from "node-fetch";
import dotenv from "dotenv";
import fs from "node:fs/promises";
import { URLSearchParams } from "node:url";

dotenv.config();
const app = express();

const {
  SPOTIFY_CLIENT_ID,
  SPOTIFY_CLIENT_SECRET
} = process.env;

const PORT = 8888;
const SCOPES = [
  "playlist-modify-public",
  "playlist-modify-private",
  "user-read-currently-playing"
].join(" ");
const { SPAINIFY_TOKEN_FILE } = process.env;
let latestRefreshToken = "";

function getRedirectUri(req) {
  const configured = (process.env.PI_HOST || "").trim();
  if (configured) {
    const withoutScheme = configured.replace(/^https?:\/\//, "");
    const hasPort = /:\d+$/.test(withoutScheme);
    const host = hasPort ? withoutScheme : `${withoutScheme}:${PORT}`;
    return `http://${host}/callback`;
  }

  const hostHeader = (req.get("host") || "").trim();
  if (hostHeader) return `http://${hostHeader}/callback`;

  return `http://127.0.0.1:${PORT}/callback`;
}

app.get("/login", (_req, res) => {
  const REDIRECT_URI = getRedirectUri(_req);
  const params = new URLSearchParams({
    client_id: SPOTIFY_CLIENT_ID,
    response_type: "code",
    redirect_uri: REDIRECT_URI,
    scope: SCOPES,
    show_dialog: "true"
  });
  res.redirect("https://accounts.spotify.com/authorize?" + params.toString());
});

app.get("/callback", async (req, res) => {
  const code = req.query.code;
  if (!code) return res.status(400).send("Missing ?code");
  const REDIRECT_URI = getRedirectUri(req);

  const body = new URLSearchParams({
    grant_type: "authorization_code",
    code: code.toString(),
    redirect_uri: REDIRECT_URI,
    client_id: SPOTIFY_CLIENT_ID,
    client_secret: SPOTIFY_CLIENT_SECRET
  });

  const r = await fetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body
  });

  const j = await r.json();
  if (!r.ok) {
    return res.status(500).send("Token exchange failed: " + JSON.stringify(j));
  }

  const refresh = (j.refresh_token || "").trim();
  if (!refresh) {
    return res.status(500).send("Spotify returned no refresh_token. Re-run /login and approve access.");
  }

  latestRefreshToken = refresh;
  if (SPAINIFY_TOKEN_FILE) {
    try {
      await fs.writeFile(SPAINIFY_TOKEN_FILE, refresh, "utf8");
    } catch (_err) {
      // Best effort only; setup.sh can still read via /token endpoint.
    }
  }

  res.send(`
    <h3>Success!</h3>
    <p><strong>Refresh token:</strong></p>
    <pre style="white-space:pre-wrap">${refresh}</pre>
    <p>Copy this into your <code>.env</code> as <code>SPOTIFY_REFRESH_TOKEN</code>, then you can stop this auth server.</p>
  `);

  console.log("\nREFRESH TOKEN:\n", refresh, "\n");
});

app.get("/token", (_req, res) => {
  if (!latestRefreshToken) return res.status(204).send("");
  return res.type("text/plain").send(latestRefreshToken);
});

app.get("/healthz", (_req, res) => {
  res.json({ ok: true });
});

app.listen(PORT, () => {
  console.log(`Auth helper on http://localhost:${PORT}`);
  console.log(`Use the same host in /login and Spotify redirect URI (for example: 127.0.0.1 or <PI_IP>).`);
});
