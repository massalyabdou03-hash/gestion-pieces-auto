-- =============================================================================
-- 2/4 — Recouvra : activation réservée au propriétaire
--
-- Avant : le client (utilisateur connecté) pouvait modifier recouvra_abonnement.actif
-- lui-même et s'offrir l'extension sans payer.
-- Après : le client peut seulement envoyer sa preuve de paiement Wave. Seul le
-- propriétaire (SQL, service_role, ou ton autre application Recouvra avec la clé
-- service) peut passer actif à vrai — voir supabase/activer_recouvra.sql.
--
-- expire_at (facultatif) : date de fin de l'abonnement mensuel. L'application
-- considère l'extension active tant que actif = vrai ET (expire_at est vide OU dans le futur).
-- =============================================================================

alter table public.recouvra_abonnement
  add column if not exists expire_at timestamptz;

revoke insert, update, delete on public.recouvra_abonnement from authenticated;
grant update (reference_wave, preuve_paiement_path, demande_at, updated_at)
  on public.recouvra_abonnement to authenticated;

-- Preuves de paiement : accès réservé aux utilisateurs autorisés, 5 Mo max, images/PDF seulement.
drop policy if exists recouvra_preuve_insert on storage.objects;
drop policy if exists recouvra_preuve_read on storage.objects;

create policy recouvra_preuve_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'recouvra-preuves' and (select public.est_utilisateur_autorise()));
create policy recouvra_preuve_read on storage.objects for select to authenticated
  using (bucket_id = 'recouvra-preuves' and (select public.est_utilisateur_autorise()));

update storage.buckets
   set file_size_limit    = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'application/pdf']
 where id = 'recouvra-preuves';
