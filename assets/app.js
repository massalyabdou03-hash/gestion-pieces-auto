// Redirige vers login.html si aucune session active. A appeler en haut de chaque page protégée.
async function requireAuth() {
  const { data } = await supabaseClient.auth.getSession();
  if (!data.session) {
    window.location.href = "login.html";
    return null;
  }
  const email = data.session.user.email;
  const el = document.getElementById("current-user-email");
  // L'email est un identifiant technique généré à partir du code d'accès (ex: "1234@acces.local").
  // On affiche uniquement la partie code, pour ne pas exposer ce détail à l'utilisateur.
  if (el) el.textContent = "Code : " + (email ? email.split("@")[0] : "");
  return data.session;
}

async function logout() {
  await supabaseClient.auth.signOut();
  window.location.href = "login.html";
}

function fmtMoney(n) {
  const v = Number(n || 0);
  return v.toLocaleString("fr-FR", { minimumFractionDigits: 0, maximumFractionDigits: 0 }) + " F";
}

function fmtDate(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric" });
}

function fmtDateTime(iso) {
  if (!iso) return "—";
  return new Date(iso).toLocaleString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric", hour: "2-digit", minute: "2-digit" });
}

function esc(str) {
  if (str === null || str === undefined) return "";
  return String(str).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function showMsg(containerEl, text, type = "error") {
  containerEl.innerHTML = `<div class="${type === "error" ? "error-msg" : "success-msg"}">${esc(text)}</div>`;
}

function clearMsg(containerEl) {
  containerEl.innerHTML = "";
}

// Traduit les erreurs Postgres/Supabase les plus courantes en messages compréhensibles
function friendlyError(err) {
  const msg = err?.message || String(err);
  if (msg.includes("duplicate key")) return "Cette référence existe déjà.";
  if (msg.includes("violates foreign key")) return "Cet élément est utilisé ailleurs et ne peut pas être supprimé.";
  if (msg.includes("Stock insuffisant")) return msg.split("CONTEXT")[0].trim();
  if (msg.includes("Invalid login credentials")) return "Code d'accès incorrect.";
  if (msg.includes("facture n'est plus en brouillon") || msg.includes("déjà")) return msg.split("CONTEXT")[0].trim();
  return msg;
}

// Construit l'email technique utilisé en interne par Supabase Auth à partir d'un code d'accès.
// Le domaine est arbitraire et n'a pas besoin d'exister réellement.
function codeToEmail(code) {
  return code.trim().toLowerCase().replace(/\s+/g, "") + "@acces.local";
}
