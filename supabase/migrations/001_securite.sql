-- 001 — Sécurité : droits des fonctions, module Recouvra, journal de stock
-- A appliquer sur le projet Supabase "gestion-pieces-auto".

-- 1) Les fonctions SECURITY DEFINER ne sont plus appelables sans connexion (rôle anon).
revoke execute on function public.valider_facture(bigint, varchar, varchar) from public, anon;
revoke execute on function public.annuler_facture(bigint) from public, anon;
revoke execute on function public.enregistrer_mouvement_stock(bigint, varchar, integer, varchar) from public, anon;
revoke execute on function public.supprimer_mouvement_stock(bigint) from public, anon;
grant execute on function public.valider_facture(bigint, varchar, varchar) to authenticated;
grant execute on function public.annuler_facture(bigint) to authenticated;
grant execute on function public.enregistrer_mouvement_stock(bigint, varchar, integer, varchar) to authenticated;
grant execute on function public.supprimer_mouvement_stock(bigint) to authenticated;

-- 2) search_path figé sur les fonctions qui ne sont pas réécrites en 002.
alter function public.annuler_facture(bigint) set search_path = public, pg_temp;
alter function public.supprimer_mouvement_stock(bigint) set search_path = public, pg_temp;

-- 3) Recouvra : le client peut envoyer sa preuve de paiement, mais seul l'administrateur
--    (SQL ou tableau de bord Supabase) peut passer "actif" à vrai.
revoke insert, update, delete on public.recouvra_abonnement from authenticated, anon;
grant update (reference_wave, preuve_paiement_path, demande_at, updated_at)
  on public.recouvra_abonnement to authenticated;

-- 4) Le journal des mouvements et le compteur de factures ne s'écrivent que via les fonctions.
drop policy if exists "auth full access" on public.mouvements_stock;
create policy "lecture seule authentifie" on public.mouvements_stock
  for select to authenticated using (true);
revoke insert, update, delete on public.mouvements_stock from authenticated, anon;

drop policy if exists "auth full access" on public.compteur_factures;
revoke all on public.compteur_factures from authenticated, anon;
