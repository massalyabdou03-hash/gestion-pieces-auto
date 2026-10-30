-- =============================================================================
-- Abonnement mensuel de la base de données (11 500 F)
--
--  * Une ligne par mois payé (ex. '2026-10').
--  * L'application lit cette table : si le mois en cours est payé, le rappel
--    de fin de mois ne s'affiche pas.
--  * Seul le compte administrateur de Massaly peut ajouter / modifier / supprimer
--    un paiement (depuis la page « Massaly Admin »).
--
-- AVANT de lancer ce script : créer le compte admin dans
--   Authentication > Users > Add user  (email massalyabdou03@gmail.com, « Auto Confirm User » coché)
-- Le script l'inscrit automatiquement comme administrateur.
-- =============================================================================

-- 1) Administrateurs de l'abonnement ------------------------------------------
create table if not exists public.abonnement_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.abonnement_admins enable row level security;
revoke all on public.abonnement_admins from anon, authenticated;

insert into public.abonnement_admins (user_id)
select id from auth.users where lower(email) = 'massalyabdou03@gmail.com'
on conflict do nothing;

create or replace function public.est_admin_abonnement()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.abonnement_admins where user_id = (select auth.uid()));
$$;
revoke execute on function public.est_admin_abonnement() from public, anon;
grant execute on function public.est_admin_abonnement() to authenticated;

-- 2) Paiements ----------------------------------------------------------------
create table if not exists public.abonnement_bdd (
  mois       text primary key check (mois ~ '^[0-9]{4}-[0-9]{2}$'),
  montant    integer not null default 11500,
  paye_le    timestamptz not null default now(),
  note       text
);
alter table public.abonnement_bdd enable row level security;
revoke all on public.abonnement_bdd from anon, authenticated;
grant select, insert, update, delete on public.abonnement_bdd to authenticated;

drop policy if exists "abonnement lecture" on public.abonnement_bdd;
drop policy if exists "abonnement admin ajout" on public.abonnement_bdd;
drop policy if exists "abonnement admin modif" on public.abonnement_bdd;
drop policy if exists "abonnement admin suppr" on public.abonnement_bdd;

-- Tout compte connecté peut voir si le mois est payé (sert à masquer le rappel)
create policy "abonnement lecture" on public.abonnement_bdd
  for select to authenticated using (true);
-- Seul l'admin écrit
create policy "abonnement admin ajout" on public.abonnement_bdd
  for insert to authenticated with check ((select public.est_admin_abonnement()));
create policy "abonnement admin modif" on public.abonnement_bdd
  for update to authenticated
  using ((select public.est_admin_abonnement()))
  with check ((select public.est_admin_abonnement()));
create policy "abonnement admin suppr" on public.abonnement_bdd
  for delete to authenticated using ((select public.est_admin_abonnement()));

-- 3) Permet à la page admin de vérifier qu'on est bien admin --------------------
-- (appel : supabase.rpc('est_admin_abonnement'))
