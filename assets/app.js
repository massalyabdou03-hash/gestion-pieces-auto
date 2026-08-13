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
  initConnectivity();
  return data.session;
}

async function logout() {
  await supabaseClient.auth.signOut();
  window.location.href = "login.html";
}

// Supabase (PostgREST) plafonne chaque requête à 1000 lignes par défaut : au-delà,
// il faut paginer avec .range() pour récupérer la totalité des lignes. `queryBuilder`
// doit être une fonction qui renvoie une nouvelle requête Supabase à chaque appel
// (ex: () => supabaseClient.from("pieces").select("*").eq("actif", true).order("designation")).
async function fetchAllRows(queryBuilder, pageSize = 1000) {
  let rows = [];
  let offset = 0;
  while (true) {
    const { data, error } = await queryBuilder().range(offset, offset + pageSize - 1);
    if (error) return { data: null, error };
    rows = rows.concat(data || []);
    if (!data || data.length < pageSize) break;
    offset += pageSize;
  }
  return { data: rows, error: null };
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
const DUPLICATE_FIELD_LABELS = {
  reference_interne: "La référence interne (SKU)",
  code_barre: "Le code-barres",
  reference_oem: "La référence OEM",
  numero_facture: "Le numéro de facture",
};

function friendlyError(err) {
  const msg = err?.message || String(err);
  if (msg.includes("duplicate key")) {
    // Le détail Postgres a la forme : Key (champ)=(valeur) already exists.
    const m = (err?.details || "").match(/Key \(([^)]+)\)=\(([^)]+)\)/);
    if (m) {
      const label = DUPLICATE_FIELD_LABELS[m[1]] || `Le champ "${m[1]}"`;
      return `${label} "${m[2]}" est déjà utilisé par une autre pièce.`;
    }
    return "Cette référence existe déjà.";
  }
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

// =============================================================================
// MODE HORS CONNEXION — cache local (catalogue/clients) + ventes en différé
// La boutique n'a qu'un seul poste : pas besoin de résoudre des conflits entre
// plusieurs appareils, juste de rejouer les ventes dans l'ordre au retour du réseau.
// =============================================================================

function readLocal(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

function writeLocal(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch (err) {
    console.error("Erreur d'écriture locale", err);
  }
}

function cachePiecesLocally(pieces) {
  writeLocal("sylla_cache_pieces", { savedAt: new Date().toISOString(), items: pieces });
}
function getCachedPieces() {
  return readLocal("sylla_cache_pieces", { savedAt: null, items: [] });
}
function cacheClientsLocally(clients) {
  writeLocal("sylla_cache_clients", { savedAt: new Date().toISOString(), items: clients });
}
function getCachedClients() {
  return readLocal("sylla_cache_clients", { savedAt: null, items: [] });
}

function getPendingSales() {
  return readLocal("sylla_pending_sales", []);
}
function savePendingSales(sales) {
  writeLocal("sylla_pending_sales", sales);
}
function queuePendingSale(sale) {
  const sales = getPendingSales();
  const entry = {
    id: `local-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    createdAt: new Date().toISOString(),
    status: "pending",
    errorMsg: null,
    ...sale,
  };
  sales.push(entry);
  savePendingSales(sales);
  document.dispatchEvent(new CustomEvent("sylla:pending-sales-updated"));
  return entry;
}
function updatePendingSale(id, patch) {
  const sales = getPendingSales();
  const idx = sales.findIndex(s => s.id === id);
  if (idx === -1) return;
  sales[idx] = { ...sales[idx], ...patch };
  savePendingSales(sales);
}
function removePendingSale(id) {
  savePendingSales(getPendingSales().filter(s => s.id !== id));
  document.dispatchEvent(new CustomEvent("sylla:pending-sales-updated"));
}

// Quantité déjà réservée par des ventes pas encore synchronisées, pour ne pas
// survendre les derniers exemplaires pendant qu'on est hors ligne.
function getReservedQuantity(pieceId) {
  return getPendingSales()
    .filter(s => s.status !== "error")
    .reduce((sum, s) => sum + s.lignes.filter(l => l.piece_id === pieceId).reduce((a, l) => a + l.quantite, 0), 0);
}

// ---------- Détection de connexion ----------
const OFFLINE_PROBE_TIMEOUT_MS = 5000;
const OFFLINE_RECHECK_INTERVAL_MS = 30000;

let appIsOnline = navigator.onLine;
let connectivityInitialized = false;
let offlineRecheckTimer = null;
let syncInProgress = false;

// navigator.onLine ne garantit pas un accès internet réel (juste qu'une interface
// réseau existe) : on vérifie avec une vraie requête avant de déclarer la reconnexion.
async function probeOnline() {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), OFFLINE_PROBE_TIMEOUT_MS);
    const { error } = await supabaseClient.from("pieces").select("id").limit(1).abortSignal(controller.signal);
    clearTimeout(timeout);
    return !error;
  } catch {
    return false;
  }
}

function ensureOfflineBanner() {
  let el = document.getElementById("offline-banner");
  if (!el) {
    el = document.createElement("div");
    el.id = "offline-banner";
    el.className = "offline-banner";
    document.body.prepend(el);
  }
  return el;
}

function setOnlineState(isOnline) {
  const wasOnline = appIsOnline;
  appIsOnline = isOnline;
  const banner = ensureOfflineBanner();

  if (!isOnline) {
    banner.textContent = "Hors connexion — les ventes sont enregistrées localement et seront synchronisées automatiquement au retour d'internet.";
    banner.className = "offline-banner offline-banner-off show";
    if (!offlineRecheckTimer) {
      offlineRecheckTimer = setInterval(async () => {
        if (await probeOnline()) handleBackOnline();
      }, OFFLINE_RECHECK_INTERVAL_MS);
    }
  } else {
    if (offlineRecheckTimer) { clearInterval(offlineRecheckTimer); offlineRecheckTimer = null; }
    if (!wasOnline) {
      banner.textContent = "Connexion rétablie — synchronisation en cours...";
      banner.className = "offline-banner offline-banner-on show";
      setTimeout(() => banner.classList.remove("show"), 4000);
    } else {
      banner.classList.remove("show");
    }
  }
  document.dispatchEvent(new CustomEvent("sylla:connectivity-changed", { detail: { online: isOnline } }));
}

async function handleBackOnline() {
  if (offlineRecheckTimer) { clearInterval(offlineRecheckTimer); offlineRecheckTimer = null; }
  setOnlineState(true);
  await syncPendingSales();
}

function initConnectivity() {
  if (connectivityInitialized) return;
  connectivityInitialized = true;

  window.addEventListener("offline", () => setOnlineState(false));
  window.addEventListener("online", async () => {
    if (await probeOnline()) handleBackOnline();
  });

  setOnlineState(navigator.onLine);
  if (navigator.onLine) {
    probeOnline().then(ok => ok ? syncPendingSales() : setOnlineState(false));
  }
}

// ---------- Moteur de synchronisation des ventes en attente ----------
// Rejoue exactement le même chemin que la vente en ligne (brouillon + factures_lignes
// + RPC valider_facture) donc le numéro de facture officiel et le déstockage réel
// n'existent qu'à partir de la synchronisation, pas au moment de la vente hors ligne.
async function syncPendingSales() {
  if (syncInProgress) return;
  syncInProgress = true;
  try {
    const sales = getPendingSales()
      .filter(s => s.status === "pending" || s.status === "error")
      .sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt));

    for (const sale of sales) {
      updatePendingSale(sale.id, { status: "syncing", errorMsg: null });
      try {
        let clientId = sale.client.id;
        if (sale.client.mode === "new") {
          const { data: newClient, error: errClient } = await supabaseClient
            .from("clients")
            .insert({ nom: sale.client.nom, telephone: sale.client.telephone || null, email: sale.client.email || null })
            .select().single();
          if (errClient) throw errClient;
          clientId = newClient.id;
          // On fige le client en "existing" tout de suite : si une étape suivante échoue et
          // qu'on retente plus tard, on ne recrée pas un deuxième client en double.
          updatePendingSale(sale.id, { client: { mode: "existing", id: clientId, nom: sale.client.nom } });
        }

        const { data: facture, error: errFacture } = await supabaseClient
          .from("factures").insert({ client_id: clientId, montant_total: sale.total }).select().single();
        if (errFacture) throw errFacture;

        const lignesPayload = sale.lignes.map(l => ({ ...l, facture_id: facture.id }));
        const { error: errLignes } = await supabaseClient.from("factures_lignes").insert(lignesPayload);
        if (errLignes) throw errLignes;

        const { error: errValidation } = await supabaseClient.rpc("valider_facture", {
          p_facture_id: facture.id,
          p_mode_paiement: sale.mode_paiement,
          p_echeance_type: sale.echeance_type || null,
        });
        if (errValidation) throw errValidation;

        removePendingSale(sale.id);
        showToast(`Vente de ${sale.client.nom} synchronisée.`, "success");
      } catch (err) {
        updatePendingSale(sale.id, { status: "error", errorMsg: friendlyError(err) });
      }
    }
  } finally {
    syncInProgress = false;
    document.dispatchEvent(new CustomEvent("sylla:pending-sales-updated"));
  }
}
