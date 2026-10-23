# Sylla Automobile — gestion de stock et facturation

Application web (HTML / CSS / JavaScript) pour une boutique de pièces automobiles à Ziguinchor :
catalogue, mouvements de stock, ruptures, factures, emprunts (bons à crédit), clients,
et l'extension payante **Recouvra** (relance WhatsApp des crédits impayés).
Fonctionne hors connexion (ventes et mouvements mis en file d'attente, synchronisés au retour d'internet).

## Technique

- Front : pages HTML statiques + `assets/app.js` (logique commune) + `assets/style.css`.
- Données : Supabase (Postgres + Auth). Projet `gestion-pieces-auto`.
- Hébergement : Netlify (`sylla-automobile.netlify.app`). Un poste ouvre l'app avec `Lancer-Sylla-Automobile.bat`.
- Hors ligne : `sw.js` (Service Worker) + file d'attente dans le navigateur.

## Base de données

Les changements de base sont dans `supabase/migrations/` (à appliquer dans l'ordre : 001, 002, 003, 004).

- Toutes les opérations sensibles passent par des fonctions SQL : `valider_facture`, `annuler_facture`,
  `enregistrer_mouvement_stock`, `supprimer_mouvement_stock`. Elles ne sont appelables que par un utilisateur connecté.
- Une facture validée ou annulée ne peut pas être modifiée ou supprimée directement dans la base (seul « payé » change).
  Pour corriger une facture, on passe par les deux fonctions ci-dessous : aucune limite de durée (une semaine, un an…).
- **Retour client** (`retour_client`) : bouton sur la facture. Les pièces reviennent en stock, le montant baisse,
  une dette à crédit diminue d'autant ; si tout est retourné la facture devient « annulée ».
  Si la facture était déjà payée, l'app rappelle le montant à rembourser.
- **Modifier une facture** (`modifier_facture`) : client, mode de paiement et lignes. Le stock est recalculé
  automatiquement (pièces en plus = sortie, en moins = entrée) et refusé si le stock est insuffisant.
- **Historique des changements** : chaque retour ou modification est enregistré (date, motif, avant/après) dans `factures_historique`.
- **Recherche** (`rechercher_factures`) sur tout l'historique : numéro, client, téléphone, pièce (désignation, OEM, référence),
  montant exact, période, statut.
- Le journal des mouvements et le compteur de factures ne s'écrivent que par ces fonctions.

## Activer Recouvra pour un client (administrateur uniquement)

1. Le client paie 15 000 F par Wave et envoie la référence + la capture depuis la page Recouvra.
2. Tu vérifies la preuve (Supabase > Storage > `recouvra-preuves`, et `recouvra_abonnement.reference_wave`).
3. Tu actives : dans l'éditeur SQL de Supabase, passer `actif` à `true` et renseigner `valide_at` dans la ligne unique de `recouvra_abonnement`.
   Le client ne peut pas le faire lui-même (droits de colonne).

## Mettre à jour l'application

1. Modifier les fichiers, puis augmenter `CACHE_VERSION` dans `sw.js`.
2. Publier (Netlify). Les postes passent à la nouvelle version au 2e chargement.

## Règles à retenir

- Ne jamais mettre la clé `service_role` dans le code. La clé publique de `assets/config.js` est faite pour être visible.
- Changer la version de supabase-js = modifier l'URL dans toutes les pages + `CACHE_VERSION`.
