-- =============================================================================
-- Abonnement mensuel de la base de données (11 500 F)
--
--  * Une ligne par mois payé (ex. '2026-10').
--  * L'application lit cette table : si le mois en cours est payé, le rappel
--    de fin de mois ne s'affiche pas.
--  * Seul le compte admin de Massaly (massalyabdou03@gmail.com, email confirmé)
--    peut ajouter / modifier / supprimer un paiement, depuis « Massaly Admin ».
--    Le compte se crée dans Authentication > Users > Add user (Auto Confirm User).
-- =============================================================================

create or replace function public.est_admin_abonnement()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from auth.users
    where id = (select auth.uid())
      and lower(email) = 'massalyabdou03@gmail.com'
      and email_confirmed_at is not null
  );
$$;
revoke execute on function public.est_admin_abonnement() from public, anon;
grant execute on function public.est_admin_abonnement() to authenticated;

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
