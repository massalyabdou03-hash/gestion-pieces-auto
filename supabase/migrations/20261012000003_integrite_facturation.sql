-- =============================================================================
-- 3/4 — Intégrité de la facturation et du stock
--
--  * valider_facture : refuse une facture déjà validée / inexistante / sans ligne, recalcule
--    le total côté serveur, vérifie le stock par pièce (deux lignes de la même pièce
--    comprises), verrouille les pièces dans un ordre fixe, numérote sans trou.
--  * Une facture validée ou annulée ne peut plus être modifiée ni supprimée
--    (seuls "payé / date de paiement" restent modifiables), ses lignes non plus.
--  * Toute modification directe du stock d'une pièce (fiche pièce, import Excel) laisse
--    une trace dans le journal des mouvements.
--  * Toutes les fonctions vérifient que l'appelant est un utilisateur autorisé.
--
-- Dépend de la migration 1 (est_utilisateur_autorise).
-- =============================================================================

-- 1) Journal automatique du stock ---------------------------------------------
create or replace function public.trg_pieces_journal_stock()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  -- Les fonctions serveur (vente, annulation, mouvement) écrivent déjà leur propre ligne.
  if current_setting('app.stock_op', true) = '1' then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.quantite_stock > 0 then
      insert into public.mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif)
      values (new.id, 'ENTREE', new.quantite_stock, 0, new.quantite_stock, 'Stock initial');
    end if;
  elsif new.quantite_stock is distinct from old.quantite_stock then
    insert into public.mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif)
    values (new.id, 'AJUSTEMENT', abs(new.quantite_stock - old.quantite_stock),
            old.quantite_stock, new.quantite_stock, 'Correction du stock (fiche pièce ou import)');
  end if;
  return new;
end;
$$;
revoke execute on function public.trg_pieces_journal_stock() from public, anon, authenticated;

drop trigger if exists pieces_journal_stock on public.pieces;
create trigger pieces_journal_stock
  after insert or update of quantite_stock on public.pieces
  for each row execute function public.trg_pieces_journal_stock();

-- 2) Verrou des factures ------------------------------------------------------
create or replace function public.trg_factures_verrou()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_op text := current_setting('app.facture_op', true);
begin
  if tg_op = 'INSERT' then
    if new.statut <> 'BROUILLON' then
      raise exception 'Une facture doit être créée en brouillon puis validée.';
    end if;
    return new;
  end if;

  if tg_op = 'DELETE' then
    if old.statut <> 'BROUILLON' then
      raise exception 'Une facture validée ou annulée ne peut pas être supprimée : annule-la plutôt.';
    end if;
    return old;
  end if;

  -- UPDATE
  if old.statut = 'BROUILLON' then
    if new.statut <> 'BROUILLON' and v_op is distinct from 'valider' then
      raise exception 'Pour valider une facture, utilise le bouton « Valider et déstocker ».';
    end if;
    return new;
  end if;

  if new.statut is distinct from old.statut then
    if not (old.statut = 'VALIDEE' and new.statut = 'ANNULEE' and coalesce(v_op, '') = 'annuler') then
      raise exception 'Le statut de cette facture ne peut pas être modifié directement.';
    end if;
  end if;

  if (new.numero_facture, new.client_id, new.mode_paiement, new.montant_total, new.created_at,
      new.validated_at, new.echeance_type, new.date_echeance)
     is distinct from
     (old.numero_facture, old.client_id, old.mode_paiement, old.montant_total, old.created_at,
      old.validated_at, old.echeance_type, old.date_echeance) then
    raise exception 'Une facture validée ne peut plus être modifiée (seul le paiement peut être mis à jour).';
  end if;

  if old.statut = 'ANNULEE'
     and (new.paye is distinct from old.paye or new.paye_at is distinct from old.paye_at) then
    raise exception 'Cette facture est annulée.';
  end if;

  return new;
end;
$$;

drop trigger if exists factures_verrou on public.factures;
create trigger factures_verrou
  before insert or update or delete on public.factures
  for each row execute function public.trg_factures_verrou();

create or replace function public.trg_lignes_verrou()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_statut varchar;
  v_id bigint;
begin
  for v_id in
    select distinct x from unnest(array[
      case when tg_op in ('UPDATE', 'DELETE') then old.facture_id end,
      case when tg_op in ('INSERT', 'UPDATE') then new.facture_id end
    ]) as x where x is not null
  loop
    select statut into v_statut from public.factures where id = v_id;
    -- v_statut vide : la facture est en cours de suppression (cascade d'un brouillon) -> autorisé.
    if v_statut is not null and v_statut <> 'BROUILLON' then
      raise exception 'Les lignes d''une facture validée ou annulée ne peuvent plus être modifiées.';
    end if;
  end loop;

  if tg_op = 'DELETE' then
    return old;
  end if;
  -- Le montant d'une ligne est toujours quantité x prix unitaire, quoi qu'envoie le navigateur.
  new.montant := new.quantite * new.prix_unitaire;
  return new;
end;
$$;

drop trigger if exists lignes_verrou on public.factures_lignes;
create trigger lignes_verrou
  before insert or update or delete on public.factures_lignes
  for each row execute function public.trg_lignes_verrou();

-- 3) valider_facture ----------------------------------------------------------
create or replace function public.valider_facture(
  p_facture_id     bigint,
  p_mode_paiement  character varying,
  p_echeance_type  character varying default null
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_annee         integer := extract(year from now())::integer;
  v_numero        integer;
  v_ligne         record;
  v_stock_actuel  integer;
  v_date_echeance date;
  v_statut        varchar;
  v_nb            integer;
  v_total         numeric;
begin
  if not public.est_utilisateur_autorise() then
    raise exception 'Accès refusé.';
  end if;

  select statut into v_statut from factures where id = p_facture_id for update;
  if v_statut is null then
    raise exception 'Facture introuvable (id=%)', p_facture_id;
  end if;
  if v_statut <> 'BROUILLON' then
    raise exception 'Cette facture n''est plus en brouillon (statut : %)', v_statut;
  end if;

  if p_mode_paiement is null
     or p_mode_paiement not in ('ESPECES', 'CARTE', 'VIREMENT', 'CHEQUE', 'WAVE', 'OM', 'CREDIT') then
    raise exception 'Mode de paiement invalide : %', coalesce(p_mode_paiement, '(vide)');
  end if;

  if p_mode_paiement = 'CREDIT' then
    if p_echeance_type is null or p_echeance_type not in ('SEMAINE', 'MOIS') then
      raise exception 'Échéance requise pour une vente à crédit (semaine ou mois)';
    end if;
    v_date_echeance := case p_echeance_type
      when 'SEMAINE' then (now() + interval '7 days')::date
      else (now() + interval '1 month')::date
    end;
  else
    p_echeance_type := null;
  end if;

  select count(*), coalesce(sum(quantite * prix_unitaire), 0)
    into v_nb, v_total
    from factures_lignes where facture_id = p_facture_id;
  if v_nb = 0 then
    raise exception 'La facture ne contient aucune ligne.';
  end if;

  perform set_config('app.stock_op', '1', true);
  perform set_config('app.facture_op', 'valider', true);

  -- On verrouille toutes les pièces concernées dans un ordre fixe (évite les blocages entre deux ventes).
  perform 1 from pieces
   where id in (select piece_id from factures_lignes where facture_id = p_facture_id)
   order by id for update;

  -- 1) on vérifie TOUT le stock (par pièce) avant de toucher à quoi que ce soit
  for v_ligne in
    select fl.piece_id, sum(fl.quantite)::integer as qte, p.quantite_stock, p.designation
      from factures_lignes fl join pieces p on p.id = fl.piece_id
     where fl.facture_id = p_facture_id
     group by fl.piece_id, p.quantite_stock, p.designation
     order by fl.piece_id
  loop
    if v_ligne.quantite_stock < v_ligne.qte then
      raise exception 'Stock insuffisant pour "%" : disponible %, demandé %',
        v_ligne.designation, v_ligne.quantite_stock, v_ligne.qte;
    end if;
  end loop;

  -- 2) déstockage pièce par pièce + journal
  for v_ligne in
    select piece_id, sum(quantite)::integer as qte
      from factures_lignes where facture_id = p_facture_id
     group by piece_id order by piece_id
  loop
    select quantite_stock into v_stock_actuel from pieces where id = v_ligne.piece_id;

    update pieces set quantite_stock = quantite_stock - v_ligne.qte, updated_at = now()
     where id = v_ligne.piece_id;

    insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif, facture_id)
    values (v_ligne.piece_id, 'SORTIE', v_ligne.qte, v_stock_actuel, v_stock_actuel - v_ligne.qte,
            'Vente - facture validée', p_facture_id);
  end loop;

  -- 3) numéro définitif (pris à la fin : une facture refusée ne consomme aucun numéro)
  insert into compteur_factures (annee, dernier_numero) values (v_annee, 0)
    on conflict (annee) do nothing;
  update compteur_factures set dernier_numero = dernier_numero + 1
   where annee = v_annee
   returning dernier_numero into v_numero;

  update factures
     set statut         = 'VALIDEE',
         numero_facture = 'FA-' || v_annee || '-' || lpad(v_numero::text, 4, '0'),
         mode_paiement  = p_mode_paiement,
         echeance_type  = p_echeance_type,
         date_echeance  = v_date_echeance,
         montant_total  = v_total,
         paye           = (p_mode_paiement <> 'CREDIT'),
         paye_at        = case when p_mode_paiement <> 'CREDIT' then now() else null end,
         validated_at   = now()
   where id = p_facture_id;

  perform set_config('app.facture_op', '', true);
  perform set_config('app.stock_op', '', true);
end;
$$;

-- 4) annuler_facture ----------------------------------------------------------
create or replace function public.annuler_facture(p_facture_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_statut        varchar;
  v_numero        varchar;
  v_ligne         record;
  v_stock_actuel  integer;
begin
  if not public.est_utilisateur_autorise() then
    raise exception 'Accès refusé.';
  end if;

  select statut, numero_facture into v_statut, v_numero
    from factures where id = p_facture_id for update;
  if v_statut is null then
    raise exception 'Facture introuvable (id=%)', p_facture_id;
  end if;
  if v_statut <> 'VALIDEE' then
    raise exception 'Seule une facture validée peut être annulée (statut actuel : %)', v_statut;
  end if;

  perform set_config('app.stock_op', '1', true);
  perform set_config('app.facture_op', 'annuler', true);

  for v_ligne in
    select piece_id, sum(quantite)::integer as qte
      from factures_lignes where facture_id = p_facture_id
     group by piece_id order by piece_id
  loop
    select quantite_stock into v_stock_actuel from pieces where id = v_ligne.piece_id for update;

    update pieces set quantite_stock = quantite_stock + v_ligne.qte, updated_at = now()
     where id = v_ligne.piece_id;

    insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif, facture_id)
    values (v_ligne.piece_id, 'ENTREE', v_ligne.qte, v_stock_actuel, v_stock_actuel + v_ligne.qte,
            'Annulation facture ' || coalesce(v_numero, '#' || p_facture_id), p_facture_id);
  end loop;

  update factures set statut = 'ANNULEE' where id = p_facture_id;

  perform set_config('app.facture_op', '', true);
  perform set_config('app.stock_op', '', true);
end;
$$;

-- 5) enregistrer_mouvement_stock ----------------------------------------------
create or replace function public.enregistrer_mouvement_stock(
  p_piece_id  bigint,
  p_type      character varying,
  p_quantite  integer,
  p_motif     character varying
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stock_actuel  integer;
  v_nouveau_stock integer;
begin
  if not public.est_utilisateur_autorise() then
    raise exception 'Accès refusé.';
  end if;

  if p_quantite is null or p_quantite < 0 or (p_type in ('ENTREE', 'SORTIE') and p_quantite = 0) then
    raise exception 'La quantité doit être supérieure à 0.';
  end if;

  select quantite_stock into v_stock_actuel from pieces where id = p_piece_id for update;
  if v_stock_actuel is null then
    raise exception 'Pièce introuvable (id=%)', p_piece_id;
  end if;

  if p_type = 'ENTREE' then
    v_nouveau_stock := v_stock_actuel + p_quantite;
  elsif p_type = 'SORTIE' then
    if v_stock_actuel < p_quantite then
      raise exception 'Stock insuffisant : disponible %, demandé %', v_stock_actuel, p_quantite;
    end if;
    v_nouveau_stock := v_stock_actuel - p_quantite;
  elsif p_type = 'AJUSTEMENT' then
    v_nouveau_stock := p_quantite;  -- pour un ajustement, p_quantite est la nouvelle valeur absolue
  else
    raise exception 'Type de mouvement invalide : %', p_type;
  end if;

  perform set_config('app.stock_op', '1', true);

  update pieces set quantite_stock = v_nouveau_stock, updated_at = now() where id = p_piece_id;

  insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif)
  values (
    p_piece_id, p_type,
    case when p_type = 'AJUSTEMENT' then greatest(abs(v_nouveau_stock - v_stock_actuel), 1) else p_quantite end,
    v_stock_actuel, v_nouveau_stock, p_motif
  );

  perform set_config('app.stock_op', '', true);
end;
$$;

-- 6) supprimer_mouvement_stock ------------------------------------------------
create or replace function public.supprimer_mouvement_stock(p_mouvement_id bigint)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_mvt           mouvements_stock%rowtype;
  v_stock_actuel  integer;
  v_nouveau_stock integer;
begin
  if not public.est_utilisateur_autorise() then
    raise exception 'Accès refusé.';
  end if;

  select * into v_mvt from mouvements_stock where id = p_mouvement_id for update;
  if v_mvt.id is null then
    raise exception 'Mouvement introuvable (id=%)', p_mouvement_id;
  end if;
  if v_mvt.facture_id is not null then
    raise exception 'Ce mouvement provient d''une facture : annule la facture plutôt que ce mouvement.';
  end if;

  select quantite_stock into v_stock_actuel from pieces where id = v_mvt.piece_id for update;
  v_nouveau_stock := v_stock_actuel - (v_mvt.quantite_apres - v_mvt.quantite_avant);
  if v_nouveau_stock < 0 then
    raise exception 'Impossible de supprimer ce mouvement : le stock deviendrait négatif (%).', v_nouveau_stock;
  end if;

  perform set_config('app.stock_op', '1', true);

  update pieces set quantite_stock = v_nouveau_stock, updated_at = now() where id = v_mvt.piece_id;
  delete from mouvements_stock where id = p_mouvement_id;

  perform set_config('app.stock_op', '', true);
end;
$$;

-- Droits (CREATE OR REPLACE conserve les droits, on les réaffirme par sécurité)
revoke execute on function public.annuler_facture(bigint) from public, anon;
revoke execute on function public.enregistrer_mouvement_stock(bigint, character varying, integer, character varying) from public, anon;
revoke execute on function public.valider_facture(bigint, character varying, character varying) from public, anon;
revoke execute on function public.supprimer_mouvement_stock(bigint) from public, anon;
grant execute on function public.annuler_facture(bigint) to authenticated, service_role;
grant execute on function public.enregistrer_mouvement_stock(bigint, character varying, integer, character varying) to authenticated, service_role;
grant execute on function public.valider_facture(bigint, character varying, character varying) to authenticated, service_role;
grant execute on function public.supprimer_mouvement_stock(bigint) to authenticated, service_role;
