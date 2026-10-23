-- =============================================================================
-- 1/4 — Sécurité des accès
--
--  * Liste blanche des utilisateurs autorisés : même si les inscriptions Auth étaient
--    ouvertes, un compte inconnu ne verrait aucune donnée.
--  * Le rôle "anon" (visiteur non connecté) n'a plus aucun droit sur les tables.
--  * Les 4 fonctions de facturation / stock ne sont plus exécutables sans connexion.
--  * Le journal des mouvements et le compteur de factures ne sont plus modifiables
--    directement depuis le navigateur (uniquement via les fonctions serveur).
--
-- À lancer en premier. Compatible avec la version actuelle de l'application.
-- =============================================================================

-- 1) Liste blanche -----------------------------------------------------------
create table if not exists public.utilisateurs_autorises (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.utilisateurs_autorises enable row level security;
revoke all on public.utilisateurs_autorises from anon, authenticated;
grant select on public.utilisateurs_autorises to authenticated;

drop policy if exists "voir son propre acces" on public.utilisateurs_autorises;
create policy "voir son propre acces" on public.utilisateurs_autorises
  for select to authenticated using (user_id = (select auth.uid()));

-- Tous les comptes existants au moment de la migration sont autorisés (ici : le compte de la boutique).
insert into public.utilisateurs_autorises (user_id)
select id from auth.users
on conflict do nothing;

create or replace function public.est_utilisateur_autorise()
returns boolean
language sql
stable
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.utilisateurs_autorises where user_id = (select auth.uid()));
$$;
revoke execute on function public.est_utilisateur_autorise() from public, anon;
grant execute on function public.est_utilisateur_autorise() to authenticated, service_role;

-- 2) Politiques RLS : réservées aux utilisateurs autorisés -------------------
drop policy if exists "auth full access" on public.pieces;
drop policy if exists "auth full access" on public.clients;
drop policy if exists "auth full access" on public.factures;
drop policy if exists "auth full access" on public.factures_lignes;
drop policy if exists "auth full access" on public.mouvements_stock;
drop policy if exists "auth full access" on public.compteur_factures;
drop policy if exists "auth full access" on public.recouvra_abonnement;

create policy "utilisateur autorise" on public.pieces for all to authenticated
  using ((select public.est_utilisateur_autorise()))
  with check ((select public.est_utilisateur_autorise()));
create policy "utilisateur autorise" on public.clients for all to authenticated
  using ((select public.est_utilisateur_autorise()))
  with check ((select public.est_utilisateur_autorise()));
create policy "utilisateur autorise" on public.factures for all to authenticated
  using ((select public.est_utilisateur_autorise()))
  with check ((select public.est_utilisateur_autorise()));
create policy "utilisateur autorise" on public.factures_lignes for all to authenticated
  using ((select public.est_utilisateur_autorise()))
  with check ((select public.est_utilisateur_autorise()));

-- Journal des mouvements : lecture seule depuis le navigateur.
create policy "lecture autorisee" on public.mouvements_stock for select to authenticated
  using ((select public.est_utilisateur_autorise()));

-- Recouvra : lecture, et mise à jour limitée (voir la migration 2 pour les colonnes).
create policy "lecture autorisee" on public.recouvra_abonnement for select to authenticated
  using ((select public.est_utilisateur_autorise()));
create policy "envoi preuve autorise" on public.recouvra_abonnement for update to authenticated
  using ((select public.est_utilisateur_autorise()))
  with check ((select public.est_utilisateur_autorise()));

-- compteur_factures : aucune policy, seules les fonctions serveur y écrivent.

-- 3) Droits sur les tables ---------------------------------------------------
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public revoke all on sequences from anon;

revoke truncate, references, trigger on all tables in schema public from authenticated;
revoke insert, update, delete on public.mouvements_stock from authenticated;
revoke all on public.compteur_factures from authenticated;

-- 4) Fonctions sensibles : plus d'exécution anonyme, search_path figé ---------
alter function public.annuler_facture(bigint)
  set search_path = public, pg_temp;
alter function public.enregistrer_mouvement_stock(bigint, character varying, integer, character varying)
  set search_path = public, pg_temp;
alter function public.valider_facture(bigint, character varying, character varying)
  set search_path = public, pg_temp;
alter function public.supprimer_mouvement_stock(bigint)
  set search_path = public, pg_temp;

revoke execute on function public.annuler_facture(bigint) from public, anon;
revoke execute on function public.enregistrer_mouvement_stock(bigint, character varying, integer, character varying) from public, anon;
revoke execute on function public.valider_facture(bigint, character varying, character varying) from public, anon;
revoke execute on function public.supprimer_mouvement_stock(bigint) from public, anon;

grant execute on function public.annuler_facture(bigint) to authenticated, service_role;
grant execute on function public.enregistrer_mouvement_stock(bigint, character varying, integer, character varying) to authenticated, service_role;
grant execute on function public.valider_facture(bigint, character varying, character varying) to authenticated, service_role;
grant execute on function public.supprimer_mouvement_stock(bigint) to authenticated, service_role;
