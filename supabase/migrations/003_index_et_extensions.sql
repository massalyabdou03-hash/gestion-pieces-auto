-- 003 — Performance et hygiène

-- Index manquants sur les clés étrangères
create index if not exists idx_factures_client on public.factures (client_id);
create index if not exists idx_factures_lignes_piece on public.factures_lignes (piece_id);
create index if not exists idx_mouvements_facture on public.mouvements_stock (facture_id);

-- pg_trgm ne doit pas vivre dans le schéma public
create schema if not exists extensions;
alter extension pg_trgm set schema extensions;
