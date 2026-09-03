-- =========================================================
-- CravaAi - Standardize Bet Type
-- Padroniza os tipos para:
-- single   = aposta simples
-- multiple = aposta múltipla
-- =========================================================


-- Remove temporariamente a constraint antiga
alter table public.bets
drop constraint if exists bets_bet_type_check;


-- Converte registros antigos que eventualmente usem "multi"
update public.bets
set bet_type = 'multiple'
where bet_type = 'multi';


-- Cria a constraint padronizada
alter table public.bets
add constraint bets_bet_type_check
check (bet_type in ('single', 'multiple'));