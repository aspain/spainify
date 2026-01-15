import express from "express";
import fetch from "node-fetch";
import dotenv from "dotenv";
import { URLSearchParams } from "node:url";

dotenv.config();
const app = express();

const {
  SPOTIFY_CLIENT_ID,
  SPOTIFY_CLIENT_SECRET
} = process.env;

const PORT = 8888;
const REDIRECT_URI = `http://${
  process.env.PI_HOST || "localhost"
}:${PORT}/callback`;
const SCOPES = [
  "playlist-modify-public",
  "playlist-modify-private",
  "user-read-currently-playing",
  "user-read-playback-state",
  "user-modify-playback-state"
].join(" ");

app.get("/login", (_req, res) => {
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

  const refresh = j.refresh_token;
  res.send(`
    <h3>Success!</h3>
    <p><strong>Refresh token:</strong></p>
    <pre style="white-space:pre-wrap">${refresh}</pre>
    <p>Copy this into your <code>.env</code> as <code>SPOTIFY_REFRESH_TOKEN</code>, then you can stop this auth server.</p>
  `);

  console.log("\nREFRESH TOKEN:\n", refresh, "\n");
});

app.listen(PORT, () => {
  console.log(`Auth helper on http://localhost:${PORT}`);
  console.log(`If browsing from another device, use http://<PI_IP>:${PORT}/login`);
  console.log(`Redirect URI expected: ${REDIRECT_URI}`);
});
