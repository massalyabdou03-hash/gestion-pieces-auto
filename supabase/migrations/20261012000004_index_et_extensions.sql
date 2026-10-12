-- =============================================================================
-- 4/4 — Performance et hygiène
--  * index sur les 3 clés étrangères signalées par l'advisor Supabase
--  * extension pg_trgm sortie du schéma public (les index de recherche existants
--    continuent de fonctionner)
-- =============================================================================

create index if not exists idx_factures_client on public.factures (client_id);
create index if not exists idx_factures_lignes_piece on public.factures_lignes (piece_id);
create index if not exists idx_mouvements_facture on public.mouvements_stock (facture_id);

create schema if not exists extensions;
alter extension pg_trgm set schema extensions;
