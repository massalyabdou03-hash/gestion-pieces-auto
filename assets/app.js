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

// ---------- Notifications toast (remplace alert()) ----------
function ensureToastContainer() {
  let c = document.getElementById("toast-container");
  if (!c) {
    c = document.createElement("div");
    c.id = "toast-container";
    c.className = "toast-container";
    document.body.appendChild(c);
  }
  return c;
}

function showToast(text, type = "error", duration = 4500) {
  const icons = { error: "⛔", success: "✅", info: "ℹ️" };
  const c = ensureToastContainer();
  const el = document.createElement("div");
  el.className = `toast toast-${type}`;
  const iconSpan = document.createElement("span");
  iconSpan.className = "toast-icon";
  iconSpan.textContent = icons[type] || icons.info;
  const textSpan = document.createElement("span");
  textSpan.className = "toast-text";
  textSpan.textContent = text;
  const closeBtn = document.createElement("button");
  closeBtn.className = "toast-close";
  closeBtn.setAttribute("aria-label", "Fermer");
  closeBtn.textContent = "×";
  el.append(iconSpan, textSpan, closeBtn);

  const close = () => {
    el.classList.remove("toast-in");
    el.classList.add("toast-out");
    setTimeout(() => el.remove(), 200);
  };
  closeBtn.addEventListener("click", close);
  c.appendChild(el);
  requestAnimationFrame(() => el.classList.add("toast-in"));
  if (duration) setTimeout(close, duration);
  return el;
}

// ---------- Confirmation stylée (remplace confirm()) ----------
function confirmDialog(message, opts = {}) {
  const { title = "Confirmer", confirmLabel = "Confirmer", cancelLabel = "Annuler", danger = true } = opts;
  return new Promise((resolve) => {
    const backdrop = document.createElement("div");
    backdrop.className = "modal-backdrop open";
    backdrop.innerHTML = `
      <div class="modal modal-sm modal-confirm">
        <div class="confirm-icon ${danger ? "danger" : ""}">${danger ? "⚠️" : "❓"}</div>
        <h3>${esc(title)}</h3>
        <p class="confirm-text">${esc(message)}</p>
        <div class="modal-actions">
          <button type="button" class="btn btn-secondary" data-action="cancel">${esc(cancelLabel)}</button>
          <button type="button" class="btn ${danger ? "btn-danger-solid" : ""}" data-action="confirm">${esc(confirmLabel)}</button>
        </div>
      </div>`;
    document.body.appendChild(backdrop);
    const cleanup = (result) => { backdrop.remove(); resolve(result); };
    backdrop.addEventListener("click", (e) => { if (e.target === backdrop) cleanup(false); });
    backdrop.querySelector('[data-action="cancel"]').addEventListener("click", () => cleanup(false));
    backdrop.querySelector('[data-action="confirm"]').addEventListener("click", () => cleanup(true));
  });
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
