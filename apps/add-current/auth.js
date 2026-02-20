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

function getRedirectUri() {
  const configured = (process.env.PI_HOST || "127.0.0.1").trim();
  const withoutScheme = configured.replace(/^https?:\/\//, "");
  const hasPort = /:\d+$/.test(withoutScheme);
  const host = hasPort ? withoutScheme : `${withoutScheme}:${PORT}`;
  return `http://${host}/callback`;
}

app.get("/login", (_req, res) => {
  const REDIRECT_URI = getRedirectUri();
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
  const REDIRECT_URI = getRedirectUri();

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
    <p>Spotify authorization completed.</p>
    <p>Your setup session captures the refresh token automatically.</p>
    <p>You can close this page and return to setup.</p>
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
  console.log(`Redirect URI in use: ${getRedirectUri()}`);
});
