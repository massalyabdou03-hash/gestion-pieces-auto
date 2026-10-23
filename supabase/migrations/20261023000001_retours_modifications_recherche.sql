-- =============================================================================
-- 5/5 — Retours clients, modification d'une facture validée, recherche dans tout l'historique
--
--  * retour_client()     : des pièces reviennent en stock, le montant de la facture baisse.
--  * modifier_facture()  : client, paiement, lignes ; le stock est recalculé (aucune limite de durée).
--  * factures_historique : trace de chaque retour / modification (avant, après, motif).
--  * rechercher_factures(): recherche sur tout l'historique (numéro, client, téléphone, pièce, montant, période).
--  * annuler_facture()   : ne remet en stock que ce qui n'a pas déjà été retourné.
--
-- A appliquer APRÈS les migrations 1 à 4 (il réutilise est_utilisateur_autorise, app.stock_op,
-- app.facture_op et le journal de stock automatique de la migration 3).
-- Les verrous de la migration 3 sont repris à l'identique ; la seule différence est le
-- contournement contrôlé « app.edition_facture », posé par retour_client() et modifier_facture()
-- pour la durée de leur transaction seulement.
-- =============================================================================

-- A) Quantité retournée par ligne + historique des changements de chaque facture
alter table public.factures_lignes
  add column if not exists quantite_retournee integer not null default 0;
alter table public.factures_lignes
  drop constraint if exists factures_lignes_retour_ck;
alter table public.factures_lignes
  add constraint factures_lignes_retour_ck check (quantite_retournee >= 0 and quantite_retournee <= quantite);

create table if not exists public.factures_historique (
  id bigint generated always as identity primary key,
  facture_id bigint not null references public.factures(id) on delete cascade,
  type_action varchar not null check (type_action in ('RETOUR', 'MODIFICATION')),
  motif varchar,
  montant_avant numeric not null,
  montant_apres numeric not null,
  details jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_factures_historique_facture
  on public.factures_historique (facture_id, created_at desc);

alter table public.factures_historique enable row level security;
drop policy if exists "lecture authentifie" on public.factures_historique;
drop policy if exists "lecture autorisee" on public.factures_historique;
create policy "lecture autorisee" on public.factures_historique for select to authenticated
  using ((select public.est_utilisateur_autorise()));
revoke all on public.factures_historique from anon;
revoke insert, update, delete on public.factures_historique from authenticated;
grant select on public.factures_historique to authenticated;

-- B) Verrous des factures et des lignes : identiques à la migration 3 + contournement contrôlé
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
  -- Correction contrôlée (retour_client / modifier_facture) : valable pour cette transaction seulement.
  if coalesce(current_setting('app.edition_facture', true), '') = '1' then
    return new;
  end if;

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


create or replace function public.trg_lignes_verrou()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_statut varchar;
  v_id bigint;
begin
  if coalesce(current_setting('app.edition_facture', true), '') = '1' then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;   -- le montant des lignes est alors fixé par la fonction appelante
  end if;

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


-- C) Annulation : ne remet en stock que ce qui n'a pas déjà été retourné
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
    select piece_id, sum(quantite - quantite_retournee)::integer as qte
      from factures_lignes where facture_id = p_facture_id
     group by piece_id having sum(quantite - quantite_retournee) > 0
     order by piece_id
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


-- C) Retour client : p_retours = [{"ligne_id": 12, "quantite": 1}, ...]
create or replace function public.retour_client(
  p_facture_id bigint,
  p_retours jsonb,
  p_motif varchar default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fact factures%rowtype;
  v_item jsonb;
  v_ligne factures_lignes%rowtype;
  v_qte integer;
  v_stock integer;
  v_avant numeric;
  v_apres numeric;
  v_restant integer;
  v_nb integer := 0;
  v_details jsonb := '[]'::jsonb;
  v_rembourse numeric;
begin
  if not public.est_utilisateur_autorise() then
    raise exception 'Accès refusé.';
  end if;

  select * into v_fact from factures where id = p_facture_id for update;
  if not found then
    raise exception 'Facture introuvable (id=%)', p_facture_id;
  end if;
  if v_fact.statut <> 'VALIDEE' then
    raise exception 'Seule une facture validée peut avoir un retour (statut actuel : %)', v_fact.statut;
  end if;
  if p_retours is null or jsonb_typeof(p_retours) <> 'array' or jsonb_array_length(p_retours) = 0 then
    raise exception 'Aucun article à retourner';
  end if;

  perform set_config('app.edition_facture', '1', true);
  perform set_config('app.stock_op', '1', true);   -- le journal de stock est écrit ici, pas par le déclencheur
  v_avant := v_fact.montant_total;

  for v_item in select value from jsonb_array_elements(p_retours) loop
    v_qte := coalesce((v_item->>'quantite')::integer, 0);
    if v_qte = 0 then continue; end if;
    if v_qte < 0 then raise exception 'Quantité retournée invalide'; end if;

    select * into v_ligne from factures_lignes
      where id = (v_item->>'ligne_id')::bigint and facture_id = p_facture_id for update;
    if not found then
      raise exception 'Ligne de facture introuvable';
    end if;
    if v_qte > v_ligne.quantite - v_ligne.quantite_retournee then
      raise exception 'Retour impossible pour "%" : % vendu(s), % déjà retourné(s), % demandé(s)',
        v_ligne.designation, v_ligne.quantite, v_ligne.quantite_retournee, v_qte;
    end if;

    select quantite_stock into v_stock from pieces where id = v_ligne.piece_id for update;
    update pieces set quantite_stock = quantite_stock + v_qte, updated_at = now() where id = v_ligne.piece_id;
    insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif, facture_id)
    values (v_ligne.piece_id, 'ENTREE', v_qte, v_stock, v_stock + v_qte,
            'Retour client - facture ' || coalesce(v_fact.numero_facture, '#' || p_facture_id), p_facture_id);

    update factures_lignes
      set quantite_retournee = quantite_retournee + v_qte,
          montant = (quantite - quantite_retournee - v_qte) * prix_unitaire
      where id = v_ligne.id;

    v_details := v_details || jsonb_build_object(
      'ligne_id', v_ligne.id, 'piece_id', v_ligne.piece_id, 'designation', v_ligne.designation,
      'quantite', v_qte, 'prix_unitaire', v_ligne.prix_unitaire, 'montant', v_qte * v_ligne.prix_unitaire);
    v_nb := v_nb + 1;
  end loop;

  if v_nb = 0 then
    raise exception 'Aucun article à retourner';
  end if;

  select coalesce(sum(montant), 0), coalesce(sum(quantite - quantite_retournee), 0)
    into v_apres, v_restant from factures_lignes where facture_id = p_facture_id;

  -- Argent à rendre au client seulement si la facture avait déjà été payée ;
  -- sur un bon à crédit non payé, c'est la dette qui diminue.
  v_rembourse := case when v_fact.paye then v_avant - v_apres else 0 end;

  update factures
    set montant_total = v_apres,
        statut = case when v_restant = 0 then 'ANNULEE' else statut end
    where id = p_facture_id;

  insert into factures_historique (facture_id, type_action, motif, montant_avant, montant_apres, details)
  values (p_facture_id, 'RETOUR', p_motif, v_avant, v_apres,
          jsonb_build_object('lignes', v_details, 'a_rembourser', v_rembourse, 'facture_entierement_retournee', v_restant = 0));

  perform set_config('app.edition_facture', '', true);
  perform set_config('app.stock_op', '', true);

  return jsonb_build_object('montant_avant', v_avant, 'montant_apres', v_apres,
                            'a_rembourser', v_rembourse, 'annulee', v_restant = 0);
end;
$$;

-- D) Modification complète d'une facture validée : client, paiement, lignes (quantités, prix, articles).
--    p_lignes = [{"piece_id": 3, "designation": "...", "quantite": 2, "prix_unitaire": 5000}, ...]
--    Le stock est recalculé : retour en stock si on retire, sortie (avec contrôle) si on ajoute.
create or replace function public.modifier_facture(
  p_facture_id bigint,
  p_client_id bigint,
  p_mode_paiement varchar,
  p_echeance_type varchar,
  p_lignes jsonb,
  p_motif varchar default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_fact factures%rowtype;
  v_num text;
  v_item jsonb;
  v_ligne record;
  v_stock integer;
  v_diff integer;
  v_avant jsonb;
  v_apres_json jsonb;
  v_montant_apres numeric;
  v_date_ech date;
  v_paye boolean;
  v_paye_at timestamptz;
begin
  if not public.est_utilisateur_autorise() then
    raise exception 'Accès refusé.';
  end if;

  select * into v_fact from factures where id = p_facture_id for update;
  if not found then
    raise exception 'Facture introuvable (id=%)', p_facture_id;
  end if;
  if v_fact.statut <> 'VALIDEE' then
    raise exception 'Seule une facture validée peut être modifiée (statut actuel : %)', v_fact.statut;
  end if;
  v_num := coalesce(v_fact.numero_facture, '#' || p_facture_id);

  if not exists (select 1 from clients where id = p_client_id) then
    raise exception 'Client introuvable';
  end if;
  if p_mode_paiement is null or p_mode_paiement not in ('ESPECES','CARTE','VIREMENT','CHEQUE','WAVE','OM','CREDIT') then
    raise exception 'Mode de paiement invalide : %', coalesce(p_mode_paiement, 'vide');
  end if;
  if p_mode_paiement = 'CREDIT' and (p_echeance_type is null or p_echeance_type not in ('SEMAINE','MOIS')) then
    raise exception 'Échéance requise pour une vente à crédit (semaine ou mois)';
  end if;

  if p_lignes is null or jsonb_typeof(p_lignes) <> 'array' or jsonb_array_length(p_lignes) = 0 then
    raise exception 'La facture doit garder au moins une ligne (pour tout reprendre, utilise Annuler la facture)';
  end if;
  for v_item in select value from jsonb_array_elements(p_lignes) loop
    if (v_item->>'piece_id') is null or coalesce((v_item->>'quantite')::integer, 0) <= 0 then
      raise exception 'Chaque ligne doit avoir une pièce et une quantité supérieure à 0';
    end if;
    if coalesce((v_item->>'prix_unitaire')::numeric, -1) < 0 then
      raise exception 'Prix unitaire invalide';
    end if;
  end loop;

  perform set_config('app.edition_facture', '1', true);
  perform set_config('app.stock_op', '1', true);   -- le journal de stock est écrit ici, pas par le déclencheur

  v_avant := jsonb_build_object(
    'client_id', v_fact.client_id, 'mode_paiement', v_fact.mode_paiement, 'echeance_type', v_fact.echeance_type,
    'montant_total', v_fact.montant_total,
    'lignes', (select coalesce(jsonb_agg(jsonb_build_object(
        'piece_id', piece_id, 'designation', designation, 'quantite', quantite,
        'quantite_retournee', quantite_retournee, 'prix_unitaire', prix_unitaire, 'montant', montant) order by id), '[]'::jsonb)
      from factures_lignes where facture_id = p_facture_id));

  -- Verrouille toutes les pièces concernées (anciennes et nouvelles), ordre fixe.
  perform 1 from pieces
    where id in (
      select piece_id from factures_lignes where facture_id = p_facture_id
      union
      select (x->>'piece_id')::bigint from jsonb_array_elements(p_lignes) x
    )
    order by id for update;

  -- Ajustement du stock : (quantité nette actuellement vendue) - (nouvelle quantité) par pièce.
  for v_ligne in
    with ancien as (
      select piece_id, sum(quantite - quantite_retournee)::integer as q
      from factures_lignes where facture_id = p_facture_id group by piece_id
    ), nouveau as (
      select (x->>'piece_id')::bigint as piece_id, sum((x->>'quantite')::integer)::integer as q
      from jsonb_array_elements(p_lignes) x group by 1
    )
    select coalesce(a.piece_id, n.piece_id) as piece_id, coalesce(a.q, 0) as ancien, coalesce(n.q, 0) as nouveau
    from ancien a full join nouveau n on n.piece_id = a.piece_id
    order by 1
  loop
    v_diff := v_ligne.ancien - v_ligne.nouveau;   -- > 0 : remise en stock ; < 0 : sortie supplémentaire
    select quantite_stock into v_stock from pieces where id = v_ligne.piece_id;
    if not found then
      raise exception 'Pièce introuvable (id=%)', v_ligne.piece_id;
    end if;
    if v_diff <> 0 then
      if v_diff < 0 and v_stock < -v_diff then
        raise exception 'Stock insuffisant pour "%" : disponible %, supplément demandé %',
          (select designation from pieces where id = v_ligne.piece_id), v_stock, -v_diff;
      end if;
      update pieces set quantite_stock = v_stock + v_diff, updated_at = now() where id = v_ligne.piece_id;
      insert into mouvements_stock (piece_id, type_mouvement, quantite, quantite_avant, quantite_apres, motif, facture_id)
      values (v_ligne.piece_id, case when v_diff > 0 then 'ENTREE' else 'SORTIE' end, abs(v_diff),
              v_stock, v_stock + v_diff, 'Modification facture ' || v_num, p_facture_id);
    end if;
  end loop;

  -- Remplacement des lignes (les retours déjà enregistrés sont repris dans les quantités nettes
  -- et restent visibles dans l'historique).
  delete from factures_lignes where facture_id = p_facture_id;
  insert into factures_lignes (facture_id, piece_id, designation, quantite, prix_unitaire, montant)
  select p_facture_id, (x->>'piece_id')::bigint,
         coalesce(nullif(btrim(x->>'designation'), ''), p.designation),
         (x->>'quantite')::integer, (x->>'prix_unitaire')::numeric,
         (x->>'quantite')::integer * (x->>'prix_unitaire')::numeric
  from jsonb_array_elements(p_lignes) x
  join pieces p on p.id = (x->>'piece_id')::bigint;

  select coalesce(sum(montant), 0) into v_montant_apres from factures_lignes where facture_id = p_facture_id;

  -- Paiement : crédit <-> comptant
  if p_mode_paiement = 'CREDIT' then
    if v_fact.mode_paiement = 'CREDIT' and v_fact.echeance_type = p_echeance_type then
      v_date_ech := v_fact.date_echeance;
    else
      v_date_ech := case p_echeance_type when 'SEMAINE' then (now() + interval '7 days')::date
                                         else (now() + interval '1 month')::date end;
    end if;
    if v_fact.mode_paiement = 'CREDIT' then
      v_paye := v_fact.paye; v_paye_at := v_fact.paye_at;
    else
      v_paye := false; v_paye_at := null;
    end if;
  else
    v_date_ech := null;
    v_paye := true;
    v_paye_at := coalesce(v_fact.paye_at, now());
  end if;

  update factures
    set client_id = p_client_id,
        mode_paiement = p_mode_paiement,
        echeance_type = case when p_mode_paiement = 'CREDIT' then p_echeance_type else null end,
        date_echeance = v_date_ech,
        montant_total = v_montant_apres,
        paye = v_paye,
        paye_at = v_paye_at
    where id = p_facture_id;

  v_apres_json := jsonb_build_object(
    'client_id', p_client_id, 'mode_paiement', p_mode_paiement, 'echeance_type', p_echeance_type,
    'montant_total', v_montant_apres,
    'lignes', (select coalesce(jsonb_agg(jsonb_build_object(
        'piece_id', piece_id, 'designation', designation, 'quantite', quantite,
        'prix_unitaire', prix_unitaire, 'montant', montant) order by id), '[]'::jsonb)
      from factures_lignes where facture_id = p_facture_id));

  insert into factures_historique (facture_id, type_action, motif, montant_avant, montant_apres, details)
  values (p_facture_id, 'MODIFICATION', p_motif, v_fact.montant_total, v_montant_apres,
          jsonb_build_object('avant', v_avant, 'apres', v_apres_json));

  perform set_config('app.edition_facture', '', true);
  perform set_config('app.stock_op', '', true);

  return jsonb_build_object('montant_avant', v_fact.montant_total, 'montant_apres', v_montant_apres);
end;
$$;

-- E) Recherche dans TOUT l'historique : numéro, client, téléphone, article (désignation ou référence),
--    montant exact, période, statut. Les droits de l'utilisateur s'appliquent (SECURITY INVOKER).
create or replace function public.rechercher_factures(
  p_q text default null,
  p_statut text default null,
  p_du date default null,
  p_au date default null,
  p_limit integer default 200
) returns table (
  id bigint, numero_facture varchar, statut varchar, montant_total numeric, mode_paiement varchar,
  created_at timestamptz, paye boolean, client_nom varchar, client_telephone varchar
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $$
  with params as (
    select btrim(coalesce(p_q, '')) as q,
           '%' || regexp_replace(btrim(coalesce(p_q, '')), '([\\%_])', '\\\1', 'g') || '%' as motif,
           regexp_replace(coalesce(p_q, ''), '[^0-9]', '', 'g') as chiffres
  )
  select f.id, f.numero_facture, f.statut, f.montant_total, f.mode_paiement, f.created_at, f.paye,
         c.nom, c.telephone
  from factures f
  join clients c on c.id = f.client_id
  cross join params
  where (p_statut is null or f.statut = p_statut)
    and (p_du is null or f.created_at >= p_du::timestamptz)
    and (p_au is null or f.created_at < (p_au + 1)::timestamptz)
    and (
      params.q = ''
      or f.numero_facture ilike params.motif
      or c.nom ilike params.motif
      or coalesce(c.telephone, '') ilike params.motif
      or (params.chiffres <> '' and f.montant_total::bigint::text = params.chiffres)
      or exists (
        select 1 from factures_lignes l
        left join pieces p on p.id = l.piece_id
        where l.facture_id = f.id
          and (l.designation ilike params.motif or p.reference_oem ilike params.motif or p.reference_interne ilike params.motif)
      )
    )
  order by f.created_at desc
  limit least(coalesce(p_limit, 200), 500);
$$;

-- F) Droits : uniquement pour un utilisateur connecté et autorisé (le contrôle est aussi fait dans chaque fonction)
revoke execute on function public.retour_client(bigint, jsonb, varchar) from public, anon;
revoke execute on function public.modifier_facture(bigint, bigint, varchar, varchar, jsonb, varchar) from public, anon;
revoke execute on function public.rechercher_factures(text, text, date, date, integer) from public, anon;
revoke execute on function public.annuler_facture(bigint) from public, anon;
grant execute on function public.retour_client(bigint, jsonb, varchar) to authenticated, service_role;
grant execute on function public.modifier_facture(bigint, bigint, varchar, varchar, jsonb, varchar) to authenticated, service_role;
grant execute on function public.rechercher_factures(text, text, date, date, integer) to authenticated, service_role;
grant execute on function public.annuler_facture(bigint) to authenticated, service_role;
