-- =============================================================================
-- Activer / désactiver l'extension Recouvra pour la boutique (à lancer par le propriétaire
-- dans l'éditeur SQL Supabase, ou depuis ton autre application avec la clé service_role).
-- Ne jamais mettre la clé service_role dans ce dépôt ni dans le navigateur.
-- =============================================================================

-- Activer pour 1 mois après réception du paiement Wave (15 000 F) :
update public.recouvra_abonnement
   set actif     = true,
       valide_at = now(),
       expire_at = now() + interval '1 month',
       updated_at = now()
 where id = true;

-- Prolonger d'un mois à partir de la fin actuelle (renouvellement) :
-- update public.recouvra_abonnement
--    set actif = true,
--        expire_at = greatest(coalesce(expire_at, now()), now()) + interval '1 month',
--        updated_at = now()
--  where id = true;

-- Couper l'accès (impayé) :
-- update public.recouvra_abonnement set actif = false, updated_at = now() where id = true;

-- Voir la demande en attente (référence Wave + chemin de la capture) :
-- select actif, reference_wave, preuve_paiement_path, demande_at, valide_at, expire_at
--   from public.recouvra_abonnement;
