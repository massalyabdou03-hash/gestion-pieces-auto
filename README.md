# Sylla Automobile — gestion de pièces auto

Application web (HTML/JS statique, sans build) : catalogue de pièces, mouvements de stock, factures, emprunts (ventes à crédit), clients et extension payante **Recouvra**. Données : Supabase. Hébergement : Netlify. Fonctionne hors ligne (service worker + files d'attente locales).

## Lancer en local
```
python3 -m http.server 8765
```
puis ouvrir http://localhost:8765. Le client Supabase est embarqué dans `assets/vendor/` (plus de dépendance CDN pour le cœur de l'app).

## Base de données Supabase
Les migrations sont dans `supabase/migrations/`. **À exécuter dans l'ordre**, dans l'éditeur SQL du projet :

1. `20261012000001_securite_acces.sql` — liste blanche `utilisateurs_autorises`, RLS, retrait des droits `anon`.
2. `20261012000002_recouvra_proprietaire.sql` — Recouvra : seul le propriétaire active/expire l'abonnement ; le client envoie seulement une preuve de paiement.
3. `20261012000003_integrite_facturation.sql` — verrouillage des factures validées, journal de stock automatique, fonctions `valider_facture` / `annuler_facture` / mouvements de stock durcies.
4. `20261012000004_index_et_extensions.sql` — index manquants, `pg_trgm` déplacé dans le schéma `extensions`.
5. `20261023000001_retours_modifications_recherche.sql` — retour client, modification d'une facture validée, historique des changements, recherche sur tout l'historique.

Après la migration 1, tout nouvel utilisateur doit être ajouté à `utilisateurs_autorises` pour accéder aux données.

## Recouvra (extension payante)
Le client voit la fenêtre complète uniquement si `recouvra_abonnement.actif = true` et que `expire_at` est vide ou dans le futur. Pour activer / renouveler / couper : `supabase/activer_recouvra.sql` (à lancer par le propriétaire uniquement).

## Retours clients, modification de facture, recherche (migration 5)
À appliquer après les migrations 1 à 4 : `supabase/migrations/20261023000001_retours_modifications_recherche.sql`.
Sans elle, les boutons « Retour client » et « Modifier » affichent un message disant que la fonction n'est pas installée ; le reste de l'application fonctionne.

- Une facture validée ou annulée ne peut toujours pas être modifiée ou supprimée directement dans la base (seul « payé » change).
  Pour la corriger, on passe par les deux fonctions ci-dessous : aucune limite de durée (une semaine, un an…).
  Le bouton « Corriger » (nouveau brouillon puis annulation de l'ancienne facture) reste disponible.
- **Retour client** (`retour_client`) : bouton sur la facture. Les pièces reviennent en stock, le montant baisse,
  une dette à crédit diminue d'autant ; si tout est retourné la facture devient « annulée ».
  Si la facture était déjà payée, l'app rappelle le montant à rembourser.
- **Modifier une facture** (`modifier_facture`) : client, mode de paiement et lignes. Le stock est recalculé
  automatiquement (pièces en plus = sortie, en moins = entrée) et refusé si le stock est insuffisant.
- **Historique des changements** : chaque retour ou modification est enregistré (date, motif, avant/après) dans `factures_historique`.
- **Recherche** (`rechercher_factures`) sur tout l'historique : numéro, client, téléphone, pièce (désignation, OEM, référence),
  montant exact, période, statut.

## Déploiement et mise à jour du client
Le site est publié par GitHub Pages à chaque fusion sur `main` : `https://massalyabdou03-hash.github.io/gestion-pieces-auto/`.

Côté client, l'application détecte toute seule la nouvelle version (à l'ouverture, toutes les 30 minutes et au retour sur l'onglet) et affiche une bannière « Nouvelle version disponible — Actualiser ». En cas de doute, le bouton **Mettre à jour l'application** (bas du menu à gauche sur ordinateur, menu « Plus » sur téléphone) vide les copies en cache et recharge ; il affiche aussi le numéro de version. Les ventes en attente hors ligne ne sont pas touchées.

Chaque modification de fichier de l'app doit s'accompagner d'un changement de `CACHE_VERSION` dans `sw.js`, sinon les postes déjà installés gardent l'ancienne version.

## Sécurité — à faire dans le tableau de bord Supabase
- Authentication → désactiver les inscriptions publiques (sign-ups).
- Authentication → activer la protection contre les mots de passe compromis.
- Remplacer le code d'accès par défaut par un code long et unique.
