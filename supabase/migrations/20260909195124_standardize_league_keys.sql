-- Migration 19
-- Padroniza as chaves das competições usadas pelas Ligas CravaAí
-- com as mesmas chaves utilizadas em public.matches e na sincronização.

update public.leagues
set
  competition_key = 'br-seriea',
  competition_name = 'Brasileirão Série A'
where competition_key = 'brasileirao';