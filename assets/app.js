// Enregistre le Service Worker qui met l'application en cache (pages, styles, scripts) :
// c'est ce qui permet d'ouvrir l'app sans aucune connexion, même après avoir redémarré
// l'ordinateur. Le cache vit sur le disque, dans le profil du navigateur.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("sw.js").catch((err) => console.error("Échec de l'enregistrement du Service Worker", err));
  });
}

// getSession() peut essayer de rafraîchir le jeton de connexion via le réseau : hors
// ligne, cet appel peut soit échouer, soit rester bloqué indéfiniment. On ne le laisse
// donc jamais dépasser quelques secondes.
function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((resolve) => setTimeout(() => resolve({ data: { session: null }, timedOut: true }), ms)),
  ]);
}

// Repère juste la présence d'une session Supabase déjà stockée sur ce poste (lecture
// locale pure, sans réseau) : sert de filet de secours hors ligne si getSession()
// échoue ou traîne, pour ne pas bloquer l'accès à un poste déjà connecté auparavant.
function hasStoredSupabaseSession() {
  try {
    return Object.keys(localStorage).some((k) => k.startsWith("sb-") && k.endsWith("-auth-token"));
  } catch {
    return false;
  }
}

// Redirige vers login.html si aucune session active. A appeler en haut de chaque page protégée.
async function requireAuth() {
  let session = null;
  try {
    const { data } = await withTimeout(supabaseClient.auth.getSession(), 4000);
    session = data.session;
  } catch {
    // getSession() a levé une erreur (typiquement hors ligne) : on retombe ci-dessous
    // sur la présence d'une session déjà connue, plutôt que de bloquer l'accès.
  }

  if (!session && !navigator.onLine && hasStoredSupabaseSession()) {
    // Hors ligne, mais ce poste s'est déjà connecté avec succès auparavant : on laisse
    // passer. Les lectures retombent sur le cache local ; toute écriture nécessitant
    // vraiment le réseau échouera proprement (message clair), sans jamais être perdue
    // silencieusement grâce aux files d'attente hors ligne.
    session = { offline: true, user: null };
  }

  if (!session) {
    window.location.href = "login.html";
    return null;
  }

  const email = session.user?.email;
  const el = document.getElementById("current-user-email");
  // L'email est un identifiant technique généré à partir du code d'accès (ex: "1234@acces.local").
  // On affiche uniquement la partie code, pour ne pas exposer ce détail à l'utilisateur.
  if (el) el.textContent = email ? "Code : " + email.split("@")[0] : "Hors ligne";
  initConnectivity();
  return session;
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
// Chaque poste (ordinateur/navigateur) a sa propre file d'attente locale, sans savoir
// ce que fait l'autre poste pendant qu'il est aussi hors ligne. On ne fait donc pas de
// vraie résolution de conflits multi-appareils ici : on rejoue simplement, sur chaque
// poste, ses propres actions dans l'ordre au retour du réseau. Conséquences si les DEUX
// postes sont hors ligne en même temps sur la même pièce :
// - Ventes / mouvements ENTREE-SORTIE : sans risque de corruption — le stock réel est
//   toujours recalculé côté serveur au moment de la synchro, donc une vente en trop
//   échoue proprement ("Stock insuffisant", visible et à réessayer), rien n'est perdu.
// - Ajustements d'inventaire (AJUSTEMENT, quantité absolue) : c'est le seul cas où le
//   dernier poste à synchroniser écrase silencieusement le comptage de l'autre. Éviter
//   de faire un inventaire physique sur les deux postes en même temps hors connexion.
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

// Cache local générique pour toute autre liste (mouvements, factures, emprunts...).
function cacheCollection(key, items) {
  writeLocal(`sylla_cache_${key}`, { savedAt: new Date().toISOString(), items });
}
function getCachedCollection(key) {
  return readLocal(`sylla_cache_${key}`, { savedAt: null, items: [] });
}

// Essaie une requête Supabase ; si elle échoue (hors ligne ou erreur réseau), retombe
// sur la dernière copie locale connue. `queryFn` doit renvoyer une Promise<{data, error}>.
async function loadWithCache(cacheKey, queryFn) {
  try {
    const { data, error } = await queryFn();
    if (!error && data) {
      cacheCollection(cacheKey, data);
      return { items: data, offline: false, savedAt: new Date().toISOString() };
    }
  } catch {
    // requête impossible (hors ligne) : on tombe sur le cache ci-dessous.
  }
  const cached = getCachedCollection(cacheKey);
  return { items: cached.items, offline: true, savedAt: cached.savedAt };
}

// ---------- File d'attente générique pour de petites modifications (ex: "marquer payé")
// faites hors ligne sur une ligne déjà existante en base. Une seule table + un seul id,
// donc pas de risque d'écraser un travail concurrent : on rejoue simplement le PATCH.
function getFieldUpdates() {
  return readLocal("sylla_pending_updates", []);
}
function saveFieldUpdates(updates) {
  writeLocal("sylla_pending_updates", updates);
}
function queueFieldUpdate(table, id, patch, label) {
  const updates = getFieldUpdates();
  updates.push({
    id: `upd-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    table, recordId: id, patch, label,
    createdAt: new Date().toISOString(),
    status: "pending",
    errorMsg: null,
  });
  saveFieldUpdates(updates);
  document.dispatchEvent(new CustomEvent("sylla:pending-updates-updated"));
}
function removeFieldUpdate(id) {
  saveFieldUpdates(getFieldUpdates().filter(u => u.id !== id));
  document.dispatchEvent(new CustomEvent("sylla:pending-updates-updated"));
}

// Superpose les modifications encore en attente de synchro sur une liste fraîchement
// chargée (ou mise en cache), pour que l'affichage reflète immédiatement l'action de
// l'utilisateur même si l'écriture réelle n'a pas encore atteint Supabase.
function applyPendingFieldUpdates(table, items) {
  const updates = getFieldUpdates().filter(u => u.table === table);
  if (updates.length === 0) return items;
  const byId = new Map(items.map(it => [String(it.id), it]));
  updates.forEach(u => {
    const it = byId.get(String(u.recordId));
    if (it) Object.assign(it, u.patch, { _pendingSync: true });
  });
  return items;
}

// ---------- File d'attente des mouvements de stock faits hors ligne (entrées, sorties,
// ajustements). Même logique que les ventes : on rejoue dans l'ordre via la RPC
// `enregistrer_mouvement_stock`, qui recalcule le stock à partir de la valeur réelle en
// base au moment de la synchro — donc l'ordre de rejeu suffit, pas besoin de fusion.
function getPendingMovements() {
  return readLocal("sylla_pending_movements", []);
}
function savePendingMovements(movements) {
  writeLocal("sylla_pending_movements", movements);
}
function queuePendingMovement(movement) {
  const movements = getPendingMovements();
  const entry = {
    id: `mvt-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    createdAt: new Date().toISOString(),
    status: "pending",
    errorMsg: null,
    ...movement,
  };
  movements.push(entry);
  savePendingMovements(movements);
  document.dispatchEvent(new CustomEvent("sylla:pending-movements-updated"));
  return entry;
}
function updatePendingMovement(id, patch) {
  const movements = getPendingMovements();
  const idx = movements.findIndex(m => m.id === id);
  if (idx === -1) return;
  movements[idx] = { ...movements[idx], ...patch };
  savePendingMovements(movements);
}
function removePendingMovement(id) {
  savePendingMovements(getPendingMovements().filter(m => m.id !== id));
  document.dispatchEvent(new CustomEvent("sylla:pending-movements-updated"));
}

// Stock affiché hors ligne pour une pièce = stock connu (cache) + mouvements en attente
// + réservations des ventes en attente. Purement indicatif : le stock réel et définitif
// est toujours recalculé côté serveur au moment de la synchronisation.
function computeEffectiveStock(pieceId, baseQuantity) {
  let qty = baseQuantity;
  getPendingMovements()
    .filter(m => m.status !== "error" && m.piece_id === pieceId)
    .sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt))
    .forEach(m => {
      if (m.type_mouvement === "ENTREE") qty += m.quantite;
      else if (m.type_mouvement === "SORTIE") qty -= m.quantite;
      else if (m.type_mouvement === "AJUSTEMENT") qty = m.quantite;
    });
  return qty - getReservedQuantity(pieceId);
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
    banner.textContent = "Hors connexion — l'application reste utilisable : les ventes, mouvements de stock et autres actions sont enregistrés localement et seront synchronisés automatiquement au retour d'internet.";
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

// Rejoue les trois files d'attente hors ligne, dans l'ordre où elles ont le plus de
// chances de rester cohérentes : d'abord les mouvements de stock (souvent des réceptions
// qui rendent une vente possible), puis les ventes, puis les petites mises à jour de champ.
async function syncAllPending() {
  await syncPendingMovements();
  await syncPendingSales();
  await syncFieldUpdates();
}

async function handleBackOnline() {
  if (offlineRecheckTimer) { clearInterval(offlineRecheckTimer); offlineRecheckTimer = null; }
  setOnlineState(true);
  await syncAllPending();
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
    probeOnline().then(ok => ok ? syncAllPending() : setOnlineState(false));
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

// ---------- Moteur de synchronisation des mouvements de stock en attente ----------
let movementsSyncInProgress = false;

async function syncPendingMovements() {
  if (movementsSyncInProgress) return;
  movementsSyncInProgress = true;
  try {
    const movements = getPendingMovements()
      .filter(m => m.status === "pending" || m.status === "error")
      .sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt));

    for (const mvt of movements) {
      updatePendingMovement(mvt.id, { status: "syncing", errorMsg: null });
      try {
        const { error } = await supabaseClient.rpc("enregistrer_mouvement_stock", {
          p_piece_id: mvt.piece_id,
          p_type: mvt.type_mouvement,
          p_quantite: mvt.quantite,
          p_motif: mvt.motif || null,
        });
        if (error) throw error;
        removePendingMovement(mvt.id);
        showToast(`Mouvement de stock (${mvt.piece_designation || "pièce"}) synchronisé.`, "success");
      } catch (err) {
        updatePendingMovement(mvt.id, { status: "error", errorMsg: friendlyError(err) });
      }
    }
  } finally {
    movementsSyncInProgress = false;
    document.dispatchEvent(new CustomEvent("sylla:pending-movements-updated"));
  }
}

// ---------- Barre de recherche pour choisir une pièce (facture, mouvement de stock) ----------
// Remplace un <select> classique par un champ texte avec suggestions filtrées en direct :
// un <select> devient impraticable dès que le catalogue dépasse une trentaine de pièces.
// `container` doit contenir un `.piece-search-input` (texte) et un `.piece-search-results`
// (liste déroulante). `pieces` est la liste initiale ; `setPieces()` permet de la rafraîchir
// sans recréer le composant (et donc sans dupliquer les écouteurs d'évènements).
let pieceSearchGlobalListenerAdded = false;
function ensurePieceSearchGlobalListener() {
  if (pieceSearchGlobalListenerAdded) return;
  pieceSearchGlobalListenerAdded = true;
  // Un seul écouteur global (plutôt qu'un par instance) : ferme n'importe quelle liste
  // ouverte quand on clique en dehors de son propre champ, sans jamais s'accumuler.
  document.addEventListener("mousedown", (e) => {
    document.querySelectorAll(".piece-search-results.open").forEach((results) => {
      const container = results.closest(".piece-search");
      if (container && !container.contains(e.target)) {
        results.classList.remove("open");
        results.innerHTML = "";
      }
    });
  });
}

function initPieceSearch(container, pieces, { onSelect, getStockLabel } = {}) {
  ensurePieceSearchGlobalListener();
  const input = container.querySelector(".piece-search-input");
  const results = container.querySelector(".piece-search-results");
  let filtered = [];
  let activeIndex = -1;
  let selected = null;

  const canonicalText = (p) => `${p.designation} (${p.reference_oem})`;
  const stockValue = (p) => (getStockLabel ? getStockLabel(p) : p.quantite_stock);

  function matches(p, q) {
    const hay = `${p.designation} ${p.reference_oem} ${p.reference_interne} ${p.marque || ""}`.toLowerCase();
    return hay.includes(q);
  }

  function renderResults() {
    if (filtered.length === 0) {
      results.innerHTML = `<div class="piece-search-empty">Aucune pièce trouvée.</div>`;
    } else {
      const shown = filtered.slice(0, 50);
      results.innerHTML = shown.map((p, i) => {
        const stock = stockValue(p);
        const stockClass = stock <= 0 ? "badge-danger" : (stock <= (p.seuil_alerte ?? 0) ? "badge-warn" : "badge-success");
        return `
        <div class="piece-search-item ${i === activeIndex ? "active" : ""}" data-idx="${i}">
          <div class="psi-desig">${esc(p.designation)}</div>
          <div class="psi-meta">${esc(p.reference_oem)}${p.marque ? " · " + esc(p.marque) : ""} · <span class="badge ${stockClass}">stock : ${stock}</span></div>
        </div>`;
      }).join("") + (filtered.length > shown.length
        ? `<div class="piece-search-empty">… affine ta recherche (${filtered.length} résultats)</div>`
        : "");
    }
    results.classList.add("open");
  }

  function open(query) {
    const q = (query || "").trim().toLowerCase();
    filtered = q ? pieces.filter((p) => matches(p, q)) : pieces.slice();
    activeIndex = -1;
    renderResults();
  }

  function close() {
    results.classList.remove("open");
    results.innerHTML = "";
  }

  function select(p) {
    selected = p;
    input.value = canonicalText(p);
    close();
    if (onSelect) onSelect(p);
  }

  function scrollActiveIntoView() {
    results.querySelector(".piece-search-item.active")?.scrollIntoView({ block: "nearest" });
  }

  input.addEventListener("focus", () => open(selected ? "" : input.value));
  input.addEventListener("input", () => {
    if (selected && input.value !== canonicalText(selected)) {
      selected = null;
      if (onSelect) onSelect(null);
    }
    open(input.value);
  });
  input.addEventListener("keydown", (e) => {
    if (!results.classList.contains("open")) return;
    if (e.key === "ArrowDown") { e.preventDefault(); activeIndex = Math.min(activeIndex + 1, filtered.length - 1); renderResults(); scrollActiveIntoView(); }
    else if (e.key === "ArrowUp") { e.preventDefault(); activeIndex = Math.max(activeIndex - 1, 0); renderResults(); scrollActiveIntoView(); }
    else if (e.key === "Enter") { e.preventDefault(); if (activeIndex >= 0 && filtered[activeIndex]) select(filtered[activeIndex]); }
    else if (e.key === "Escape") { close(); }
  });
  // mousedown + preventDefault (plutôt que "click") : empêche l'input de perdre le focus
  // au clic sur un résultat, donc le "blur" ci-dessous ne se déclenche jamais pour un clic
  // légitime sur la liste, seulement pour un clic réellement en dehors du composant.
  results.addEventListener("mousedown", (e) => {
    const item = e.target.closest(".piece-search-item");
    if (!item) return;
    e.preventDefault();
    const idx = Number(item.dataset.idx);
    if (filtered[idx]) select(filtered[idx]);
  });
  input.addEventListener("blur", () => {
    setTimeout(() => {
      if (!selected) input.value = "";
      close();
    }, 120);
  });

  return {
    setPieces(newPieces) { pieces = newPieces; },
    getSelected() { return selected; },
    setSelected(p) {
      selected = p;
      input.value = p ? canonicalText(p) : "";
    },
    clear() {
      selected = null;
      input.value = "";
      close();
    },
  };
}

// ---------- Moteur de synchronisation des petites mises à jour en attente ----------
let fieldUpdatesSyncInProgress = false;

async function syncFieldUpdates() {
  if (fieldUpdatesSyncInProgress) return;
  fieldUpdatesSyncInProgress = true;
  try {
    const updates = getFieldUpdates()
      .filter(u => u.status === "pending" || u.status === "error")
      .sort((a, b) => new Date(a.createdAt) - new Date(b.createdAt));

    for (const upd of updates) {
      try {
        const { error } = await supabaseClient.from(upd.table).update(upd.patch).eq("id", upd.recordId);
        if (error) throw error;
        removeFieldUpdate(upd.id);
        if (upd.label) showToast(`${upd.label} synchronisé.`, "success");
      } catch (err) {
        const all = getFieldUpdates();
        const idx = all.findIndex(u => u.id === upd.id);
        if (idx !== -1) { all[idx].status = "error"; all[idx].errorMsg = friendlyError(err); saveFieldUpdates(all); }
      }
    }
  } finally {
    fieldUpdatesSyncInProgress = false;
    document.dispatchEvent(new CustomEvent("sylla:pending-updates-updated"));
  }
}
