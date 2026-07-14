/* =============================================================================
   BASE DE HIDRÔMETROS - SÃO LUÍS
   Granularidade: UM REGISTRO POR EVENTO DE INSTALAÇÃO (não por imóvel).

   Um mesmo imóvel que teve o hidrômetro trocado 3 vezes gera 3 linhas. É essa
   a granularidade que a meta dos 130 mil mede: instalações executadas, não
   parque atual.

   -----------------------------------------------------------------------------
   ATENÇÃO - CONFIRMAR ANTES DE USAR EM PRODUÇÃO
   -----------------------------------------------------------------------------
   O vínculo entre o histórico de instalação e a ligação de água está marcado
   abaixo como  his.lagu_id = lagu.lagu_id  (ver "PONTO A CONFIRMAR").
   Esse é o padrão do GSAN, mas NÃO foi verificado contra este banco.

   Rode isto e confira qual coluna de vínculo a tabela realmente expõe
   (lagu_id? imov_id? outra?):

       SELECT column_name, data_type
       FROM information_schema.columns
       WHERE table_schema = 'micromedicao'
         AND table_name   = 'hidrometro_inst_hist'
       ORDER BY ordinal_position;

   Se a coluna for outra, ajuste APENAS aquele ON.
   ============================================================================= */

WITH imoveis_base AS (
    SELECT
        imo.imov_id,
        imo.loca_id,
        imo.last_id,
        bai.bair_nmbairro,
        une.uneg_nmunidadenegocio,
        hid.hidr_nnhidrometro,
        his.hidi_dtinstalacaohidrometro,
        his.hidi_dtretiradahidrometro

    FROM cadastro.imovel imo

    INNER JOIN cadastro.localidade loc
        ON imo.loca_id = loc.loca_id

    INNER JOIN cadastro.unidade_negocio une
        ON une.uneg_id = loc.uneg_id

    INNER JOIN cadastro.setor_comercial sec
        ON imo.stcm_id = sec.stcm_id

    INNER JOIN cadastro.quadra qdr
        ON qdr.qdra_id = imo.qdra_id

    INNER JOIN micromedicao.rota rot
        ON rot.rota_id = qdr.rota_id

    INNER JOIN faturamento.faturamento_grupo ftg
        ON ftg.ftgr_id = rot.ftgr_id

    INNER JOIN cadastro.logradouro_bairro lgb
        ON lgb.lgbr_id = imo.lgbr_id

    INNER JOIN cadastro.logradouro logr
        ON logr.logr_id = lgb.logr_id

    INNER JOIN cadastro.bairro bai
        ON bai.bair_id = lgb.bair_id

    INNER JOIN cadastro.municipio mun
        ON mun.muni_id = bai.muni_id

    INNER JOIN atendimentopublico.ligacao_agua lagu
        ON lagu.lagu_id = imo.imov_id

    /* -------------------------------------------------------------------------
       PONTO A CONFIRMAR - é esta linha que abre o histórico completo.

       ANTES:  ON his.hidi_id = lagu.hidi_id
               lagu.hidi_id aponta para a instalação CORRENTE (uma única linha,
               a que tem dtretirada NULL). O join por ele trazia só o parque de
               hoje; todo hidrômetro instalado desde 2016 e depois trocado ficava
               invisível. O filtro "AND hidi_dtretiradahidrometro IS NULL" era,
               por isso, redundante: o join já garantia o mesmo efeito.

       AGORA:  join pela LIGAÇÃO, trazendo todas as instalações que ela já teve.
       ------------------------------------------------------------------------- */
    INNER JOIN micromedicao.hidrometro_inst_hist his
        ON his.lagu_id = lagu.lagu_id

    INNER JOIN micromedicao.hidrometro hid
        ON hid.hidr_id = his.hidr_id

    WHERE imo.imov_icexclusao = 2
      AND mun.muni_id = 1
      AND his.hidi_dtinstalacaohidrometro IS NOT NULL
),

ultimo_consumo AS (
    SELECT DISTINCT ON (
        cshi.imov_id,
        cshi.lgti_id
    )
        cshi.imov_id,
        cshi.lgti_id,
        cstp.cstp_dsconsumotipo

    FROM micromedicao.consumo_historico cshi

    /* DISTINCT porque imoveis_base agora tem N linhas por imóvel (uma por
       instalação); sem isso o join multiplicaria as linhas de consumo. */
    INNER JOIN (SELECT DISTINCT imov_id FROM imoveis_base) ib
        ON ib.imov_id = cshi.imov_id

    INNER JOIN micromedicao.consumo_tipo cstp
        ON cstp.cstp_id = cshi.cstp_id

    WHERE cshi.lgti_id IN (1, 2)

    ORDER BY
        cshi.imov_id,
        cshi.lgti_id,
        cshi.cshi_amfaturamento DESC
),

tipo_consumo AS (
    SELECT
        uc.imov_id,

        MAX(
            CASE
                WHEN uc.lgti_id = 1
                THEN uc.cstp_dsconsumotipo
            END
        ) AS tipoConsumoAgua,

        MAX(
            CASE
                WHEN uc.lgti_id = 2
                THEN uc.cstp_dsconsumotipo
            END
        ) AS tipoConsumoEsgoto

    FROM ultimo_consumo uc

    GROUP BY
        uc.imov_id
)

SELECT
    ib.imov_id                       AS "MATRICULA",
    ib.loca_id                       AS "LOCALIDADE",
    ib.uneg_nmunidadenegocio         AS "NOME UNIDADE",
    ib.bair_nmbairro                 AS "BAIRRO",
    ib.hidr_nnhidrometro             AS "NR HID.",
    ib.hidi_dtinstalacaohidrometro   AS "DATA INSTALACAO",
    ib.hidi_dtretiradahidrometro     AS "DATA RETIRADA",

    /* Situação do hidrômetro no parque de hoje. Com o histórico aberto, a base
       passa a ter instalações já encerradas - sem esta coluna não há como
       distinguir "instalei e ainda está lá" de "instalei e já foi trocado". */
    CASE
        WHEN ib.hidi_dtretiradahidrometro IS NULL
        THEN 'ATIVO'
        ELSE 'RETIRADO'
    END                              AS "STATUS HIDROMETRO",

    /* -------------------------------------------------------------------------
       EMPRESA CONTRATADA - derivada da data de instalação, não lida de tabela.
       Não é um dado de origem: é uma atribuição por janela de contrato.

       Faixas half-open [inicio, fim+1):  >= inicio AND < fim_exclusivo.
       O BETWEEN anterior truncava o último dia à meia-noite caso a coluna seja
       timestamp - instalações feitas ao longo do dia final do contrato caíam
       em 'EQUIPE CAEMA'. Assim funciona para date e para timestamp.
       ------------------------------------------------------------------------- */
    CASE
        /* ALLSAN: 26/08/2019 a 28/02/2021 */
        WHEN ib.hidi_dtinstalacaohidrometro >= DATE '2019-08-26'
         AND ib.hidi_dtinstalacaohidrometro <  DATE '2021-03-01'
            THEN 'ALLSAN ENGENHARIA E ADMINISTRAÇÃO LTDA'

        /* ESAC: 01/03/2021 a 05/07/2022 */
        WHEN ib.hidi_dtinstalacaohidrometro >= DATE '2021-03-01'
         AND ib.hidi_dtinstalacaohidrometro <  DATE '2022-07-06'
            THEN 'ESAC - EMPRESA DE SANEAMENTO AMBIENTAL E CONCESSÕES LTDA'

        /* RIO UNA (sem sobreposição): 06/07/2022 a 18/07/2023 */
        WHEN ib.hidi_dtinstalacaohidrometro >= DATE '2022-07-06'
         AND ib.hidi_dtinstalacaohidrometro <  DATE '2023-07-19'
            THEN 'RIO UNA SERVIÇOS GERAIS EIRELI'

        /* SOBREPOSIÇÃO RIO UNA + ATLANTIS: 19/07/2023 a 10/07/2024 */
        WHEN ib.hidi_dtinstalacaohidrometro >= DATE '2023-07-19'
         AND ib.hidi_dtinstalacaohidrometro <  DATE '2024-07-11'
            THEN 'RIO UNA SERVIÇOS GERAIS EIRELI / ATLANTIS SANEAMENTO AMBIENTAL LTDA'

        /* ATLANTIS (sem sobreposição): 11/07/2024 a 27/09/2024 */
        WHEN ib.hidi_dtinstalacaohidrometro >= DATE '2024-07-11'
         AND ib.hidi_dtinstalacaohidrometro <  DATE '2024-09-28'
            THEN 'ATLANTIS SANEAMENTO AMBIENTAL LTDA'

        /* FIMM: a partir de 15/05/2025, SEM data final.
           O fim estava fixo em 09/07/2026 - como o contrato segue vigente, cada
           dia que passava jogava as instalações novas da FIMM em 'EQUIPE CAEMA'
           (eram os 20 registros de julho/2026). Quando o contrato encerrar de
           fato, feche a janela com o < da data seguinte. */
        WHEN ib.hidi_dtinstalacaohidrometro >= DATE '2025-05-15'
            THEN 'FIMM BRASIL LTDA'

        /* Execução própria da CAEMA - tudo que não caiu em janela de contrato:
           - instalações anteriores ao 1º contrato (2016 a ago/2019);
           - os vãos ENTRE contratos, sobretudo 28/09/2024 a 14/05/2025. */
        ELSE 'EQUIPE CAEMA'
    END                              AS "EMPRESA CONTRATADA",

    tc.tipoConsumoAgua               AS "TIPO CONSUMO AGUA",
    tc.tipoConsumoEsgoto             AS "TIPO CONSUMO ESGOTO",
    las.last_dsligacaoaguasituacao   AS "SITUACAO AGUA"

FROM imoveis_base ib

INNER JOIN atendimentopublico.ligacao_agua_situacao las
    ON las.last_id = ib.last_id

LEFT JOIN tipo_consumo tc
    ON tc.imov_id = ib.imov_id
