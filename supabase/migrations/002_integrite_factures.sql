-- 002 — Intégrité : validation de facture fiable, factures validées verrouillées

-- A) valider_facture : contrôle du statut, des lignes, du mode de paiement,
--    verrouillage des pièces, total recalculé côté serveur.
create or replace function public.valider_facture(
  p_facture_id bigint,
  p_mode_paiement varchar,
  p_echeance_type varchar default null
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_annee  integer := extract(year from now());
  v_numero integer;
  v_ligne  record;
  v_stock_actuel integer;
  v_date_echeance date;
  v_statut varchar;
  v_nb integer;
  v_total numeric;
begin
  select statut into v_statut from factures where id = p_facture_id for update;
  if not found then
    raise exception 'Facture introuvable (id=%)', p_facture_id;
  end if;
  if v_statut <> 'BROUILLON' then
    raise exception 'Cette facture n''est plus en brouillon (statut : %)', v_statut;
  end if;

  if p_mode_paiement is null or p_mode_paiement not in ('ESPECES','CARTE','VIREMENT','CHEQUE','WAVE','OM','CREDIT') then
    raise exception 'Mode de paiement invalide : %', coalesce(p_mode_paiement, 'vide');
  end if;

  if p_mode_paiement = 'CREDIT' then
    if p_echeance_type is null or p_echeance_type not in ('SEMAINE','MOIS') then
      raise exception 'Échéance requise pour une vente à crédit (semaine ou mois)';
    end if;
    v_date_echeance := case p_echeance_type
      when 'SEMAINE' then (now() + interval '7 days')::date
      else (now() + interval '1 month')::date
    end;
  end if;

  -- Le montant de chaque ligne et le total sont recalculés ici : on ne fait pas confiance au navigateur.
  update factures_lignes set montant = quantite * prix_unitaire where facture_id = p_facture_id;
  select count(*), coalesce(sum(montant), 0) into v_nb, v_total
    from factures_lignes where facture_id = p_facture_id;
  if v_nb = 0 then
    raise exception 'Facture vide : ajoute au moins une ligne avant de valider';
  end if;

  -- Verrouille toutes les pièces concernées (ordre fixe pour éviter les blocages croisés).
  perform 1 from pieces
    where id in (select piece_id from factures_lignes where facture_id = p_facture_id)
    order by id for update;

  -- 1) on vérifie TOUT le stock avant de toucher à quoi que ce soit (quantités cumulées par pièce)
  for v_ligne in
    select fl.piece_id, sum(fl.quantite) as quantite, p.quantite_stock, p.designation
    from factures_lignes fl join pieces p on p.id = fl.piece_id
    where fl.facture_id = p_facture_id
    group by fl.piece_id, p.quantite_stock, p.designation
  loop
    if v_ligne.quantite_stock < v_ligne.quantite then
      raise exception 'Stock insuffisant pour "%" : disponible %, demandé %',
        v_ligne.designation, v_ligne.quantite_stock, v_ligne.quantite;
    end if;
  end loop;

  insert into compteur_factures(annee, dernier_numero) values (v_annee, 0)
    on conflict (annee) do nothing;
  update compteur_factures set dernier_numero = dernier_numero + 1
    where annee = v_annee returning dernier_numero into v_numero;

  -- 2) déstockage ligne par ligne + journal
  for v_ligne in
    select piece_id, quantite from factures_lignes where facture_id = p_facture_id order by id
  loop
    select quantite_stock into v_stock_actuel from pieces where id = v_ligne.piece_id;
    update pieces set quantite_stock = quantite_stock - v_ligne.quantite, updated_at = now()
      where id = v_ligne.piece_id;
    insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif, facture_id)
    values (v_ligne.piece_id, 'SORTIE', v_ligne.quantite, v_stock_actuel, v_stock_actuel - v_ligne.quantite,
            'Vente - facture validée', p_facture_id);
  end loop;

  update factures
    set statut = 'VALIDEE',
        numero_facture = 'FA-' || v_annee || '-' || lpad(v_numero::text, 4, '0'),
        mode_paiement = p_mode_paiement,
        echeance_type = p_echeance_type,
        date_echeance = v_date_echeance,
        montant_total = v_total,
        paye = (p_mode_paiement <> 'CREDIT'),
        paye_at = case when p_mode_paiement <> 'CREDIT' then now() else null end,
        validated_at = now()
    where id = p_facture_id;
end;
$$;

-- B) enregistrer_mouvement_stock : quantités contrôlées.
create or replace function public.enregistrer_mouvement_stock(
  p_piece_id bigint,
  p_type varchar,
  p_quantite integer,
  p_motif varchar
) returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stock_actuel  integer;
  v_nouveau_stock integer;
begin
  if p_quantite is null then
    raise exception 'Quantité requise';
  end if;
  if p_type in ('ENTREE','SORTIE') and p_quantite <= 0 then
    raise exception 'La quantité doit être supérieure à 0';
  end if;
  if p_type = 'AJUSTEMENT' and p_quantite < 0 then
    raise exception 'Le stock ne peut pas être négatif';
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

  update pieces set quantite_stock = v_nouveau_stock, updated_at = now() where id = p_piece_id;

  insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif)
  values (
    p_piece_id, p_type,
    case when p_type = 'AJUSTEMENT' then greatest(abs(v_nouveau_stock - v_stock_actuel), 1) else p_quantite end,
    v_stock_actuel, v_nouveau_stock, p_motif
  );
end;
$$;

-- C) Une facture validée ou annulée est une pièce comptable : on ne la modifie pas "à la main"
--    par l'API. Restent autorisés en direct : marquer payé / non payé, et passer de VALIDEE à ANNULEE.
--    Les corrections (retour client, modification) passent par les fonctions retour_client() et
--    modifier_facture() (migration 004), qui lèvent le verrou pour leur transaction seulement,
--    remettent le stock d'aplomb et gardent une trace dans factures_historique.
create or replace function public.trg_factures_verrou() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if old.statut <> 'BROUILLON' then
      raise exception 'Une facture validée ou annulée ne peut pas être supprimée : annule-la plutôt.';
    end if;
    return old;
  end if;

  if old.statut = 'BROUILLON' then
    return new;
  end if;

  -- Modification contrôlée par retour_client() / modifier_facture() (valable pour cette transaction uniquement).
  if coalesce(current_setting('app.edition_facture', true), '') = '1' then
    return new;
  end if;

  if new.client_id        is distinct from old.client_id
  or new.montant_total    is distinct from old.montant_total
  or new.numero_facture   is distinct from old.numero_facture
  or new.mode_paiement    is distinct from old.mode_paiement
  or new.echeance_type    is distinct from old.echeance_type
  or new.date_echeance    is distinct from old.date_echeance
  or new.validated_at     is distinct from old.validated_at
  or new.created_at       is distinct from old.created_at then
    raise exception 'Cette facture est validée : elle ne peut plus être modifiée.';
  end if;

  if new.statut is distinct from old.statut
     and not (old.statut = 'VALIDEE' and new.statut = 'ANNULEE') then
    raise exception 'Changement de statut impossible (% vers %).', old.statut, new.statut;
  end if;

  return new;
end;
$$;

drop trigger if exists factures_verrou on public.factures;
create trigger factures_verrou before update or delete on public.factures
  for each row execute function public.trg_factures_verrou();

create or replace function public.trg_lignes_verrou() returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_statut varchar;
begin
  if coalesce(current_setting('app.edition_facture', true), '') = '1' then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op in ('UPDATE','DELETE') then
    select statut into v_statut from factures where id = old.facture_id;
    if found and v_statut <> 'BROUILLON' then
      raise exception 'Les lignes d''une facture validée ne peuvent plus être modifiées.';
    end if;
  end if;
  if tg_op in ('INSERT','UPDATE') then
    select statut into v_statut from factures where id = new.facture_id;
    if found and v_statut <> 'BROUILLON' then
      raise exception 'Les lignes d''une facture validée ne peuvent plus être modifiées.';
    end if;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists lignes_verrou on public.factures_lignes;
create trigger lignes_verrou before insert or update or delete on public.factures_lignes
  for each row execute function public.trg_lignes_verrou();
