// The header's Gist button: the project's files, as they are in this tab
// right now, become a GitHub gist, which opens in a new tab (its link is
// also copied). Click = secret gist (unlisted, anyone with the link);
// ⇧-click = public.
//
// The browser talks to api.github.com itself: the studio server has no
// route to the internet and holds no secrets. The GitHub token (a classic
// token with only the `gist` scope) is asked for once and kept in this
// browser's localStorage; a token GitHub rejects is forgotten.

const TOKEN_KEY = "puffin-studio.github-gist-token";
const NEW_TOKEN_URL =
  "https://github.com/settings/tokens/new?scopes=gist&description=Puffin%20Studio%20gists";

function storedToken() {
  try { return localStorage.getItem(TOKEN_KEY) || ""; } catch { return ""; }
}
function storeToken(token) {
  try {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  } catch { /* private window: asked again next time */ }
}

function askForToken() {
  const answer = window.prompt(
    "Paste a GitHub token with the \"gist\" scope (a classic token: fine-grained tokens can't make gists).\n\n" +
    `Make one at ${NEW_TOKEN_URL}\n\n` +
    "It stays in this browser only; the studio server never sees it.");
  return (answer || "").trim();
}

// Gist file names can't hold "/": a nested path keeps its folders as "__".
const gistName = (path) => path.replaceAll("/", "__");

export function initGist({ button, texts, project, note }) {
  let busy = false;

  button.addEventListener("click", async (event) => {
    if (busy) return;
    const isPublic = event.shiftKey;
    const files = {};
    for (const [path, text] of Object.entries(texts())) {
      if (text.trim()) files[gistName(path)] = { content: text }; // GitHub rejects empty files
    }
    if (!Object.keys(files).length) return note("nothing to gist: every file is empty");

    let token = storedToken();
    if (!token) {
      token = askForToken();
      if (!token) return;
    }

    // Open the tab now, while the click still counts as a user gesture;
    // a window opened after the request finishes would be popup-blocked.
    const tab = window.open("about:blank", "_blank");
    busy = true;
    button.disabled = true;
    const label = button.textContent;
    button.textContent = "Gisting…";
    try {
      const response = await fetch("https://api.github.com/gists", {
        method: "POST",
        headers: {
          Accept: "application/vnd.github+json",
          Authorization: `Bearer ${token}`,
          "X-GitHub-Api-Version": "2022-11-28",
        },
        body: JSON.stringify({
          description: `${project() || "Puffin"} (Puffin Studio)`,
          public: isPublic,
          files,
        }),
      });
      const reply = await response.json().catch(() => ({}));
      if (response.status === 401 || response.status === 403) {
        storeToken("");
        tab?.close();
        return note(`GitHub refused the token (${reply.message || response.status}); the next Gist asks for a new one`);
      }
      if (!response.ok || !reply.html_url) {
        tab?.close();
        return note(`gist failed: ${reply.message || response.status}`);
      }
      storeToken(token);
      if (tab) tab.location.href = reply.html_url;
      else window.open(reply.html_url, "_blank");
      navigator.clipboard?.writeText(reply.html_url).catch(() => {});
      note(`${isPublic ? "public" : "secret"} gist: ${reply.html_url} (link copied)`);
    } catch (error) {
      tab?.close();
      note(`gist failed: couldn't reach GitHub (${error.message})`);
    } finally {
      busy = false;
      button.disabled = false;
      button.textContent = label;
    }
  });
}
