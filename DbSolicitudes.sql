/* =====================================================================================
   DbSolicitudes — Script DDL + DML inicial
   Motor: PostgreSQL 13+   (probado en PostgreSQL 16)

   Estándar de nomenclatura aplicado (documento "Estándar de Nomenclatura"),
   adaptado de SQL Server a PostgreSQL:
     - Base de datos y esquemas con mayúscula inicial; no se usa el esquema por defecto (public).
     - Tablas:        tbl + entidad en plural, camelCase           -> "Solicitudes"."tblTickets"
     - Campos:        camelCase; llaves id + entidad en singular   -> "idTicket"
     - Constraints:   pk / uk / fk / chk + entidad(_campo|_referencia)
     - Funciones:     fn + acción + tipo de resultado              -> "fnTicketRegistrarHistorialTrigger"
     - Triggers:      tgr + tabla + acción                         -> "tgrTicketHistorialInsertarActualizar"
     - Auditoría:     todas las tablas incluyen "usuarioRegistro" y "fechaRegistro".

   Equivalencias de tipos SQL Server -> PostgreSQL:
     INT IDENTITY(1,1) -> INT GENERATED ALWAYS AS IDENTITY
     NVARCHAR(n)       -> VARCHAR(n)       (la BD se crea en UTF8)
     NVARCHAR(MAX)     -> TEXT
     BIT               -> BOOLEAN          (siempre con DEFAULT)
     DATETIME2         -> TIMESTAMPTZ
     SYSDATETIME()     -> CURRENT_TIMESTAMP

   Notas importantes para PostgreSQL:
     1. PostgreSQL convierte a minúsculas los identificadores sin comillas. Para conservar
        el camelCase del estándar, TODOS los objetos se escriben entre comillas dobles, y así
        deben referenciarse en las consultas:  SELECT "idTicket" FROM "Solicitudes"."tblTickets";
     2. PostgreSQL no admite DEFAULT con nombre (dfEntidad_Campo); los valores por defecto
        se declaran en línea en la columna.
     3. Los índices no están cubiertos por el estándar; se usa el prefijo ix + entidad_campo.
     4. Usuario aplicativo: el equivalente al parámetro @usuario es la variable de sesión
        "app.usuario". La aplicación debe ejecutar, dentro de cada transacción:
            SET LOCAL app.usuario = 'jperez';
        Los triggers la usan para auditar; si no está definida se usa el usuario de la sesión.
   ===================================================================================== */


/* -------------------------------------------------------------------------------------
   0. Base de datos
   CREATE DATABASE no puede ejecutarse dentro de una transacción. Ejecutar por separado
   (conectado a la BD "postgres") y luego conectarse a "DbSolicitudes" para correr el resto.
   ------------------------------------------------------------------------------------- */
-- CREATE DATABASE "DbSolicitudes" WITH ENCODING 'UTF8' TEMPLATE template0;
-- \c "DbSolicitudes"


BEGIN;

/* -------------------------------------------------------------------------------------
   1. Esquemas (agrupados por dominio y criticidad de acceso)
   ------------------------------------------------------------------------------------- */
CREATE SCHEMA IF NOT EXISTS "Seguridad";        -- usuarios, roles y su asignación
CREATE SCHEMA IF NOT EXISTS "Catalogos";        -- tipos de solicitud y estados
CREATE SCHEMA IF NOT EXISTS "Solicitudes";      -- formularios, tickets, historial y correcciones
CREATE SCHEMA IF NOT EXISTS "Notificaciones";   -- avisos a usuarios


/* -------------------------------------------------------------------------------------
   2. Función auxiliar: usuario aplicativo actual (equivalente a @usuario)
   ------------------------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION "Seguridad"."fnObtenerUsuarioActualEscalar"()
RETURNS VARCHAR(90)
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(NULLIF(current_setting('app.usuario', true), ''), session_user)::VARCHAR(90);
$$;

COMMENT ON FUNCTION "Seguridad"."fnObtenerUsuarioActualEscalar"() IS
    'Devuelve el usuario aplicativo (SET LOCAL app.usuario) o, en su defecto, el usuario de la sesión.';


/* =====================================================================================
   3. SEGURIDAD
   ===================================================================================== */

-- 3.1 Usuarios -------------------------------------------------------------------------
CREATE TABLE "Seguridad"."tblUsuarios"
(
    "idUsuario"         INT           NOT NULL GENERATED ALWAYS AS IDENTITY,
    "nombreUsuario"     VARCHAR(100),
    "correoUsuario"     VARCHAR(150)  NOT NULL,
    "passwordUsuario"   VARCHAR(255)  NOT NULL,   -- almacenar SOLO el hash (bcrypt / argon2)
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkUsuario"          PRIMARY KEY ("idUsuario"),
    CONSTRAINT "ukUsuario_Correo"   UNIQUE ("correoUsuario"),
    CONSTRAINT "chkUsuario_Correo"  CHECK ("correoUsuario" = lower(btrim("correoUsuario"))
                                           AND "correoUsuario" LIKE '%_@_%')
);
COMMENT ON TABLE  "Seguridad"."tblUsuarios" IS 'Usuarios del sistema.';
COMMENT ON COLUMN "Seguridad"."tblUsuarios"."correoUsuario" IS
    'Se guarda en minúsculas para que la unicidad no dependa de mayúsculas/minúsculas.';

-- 3.2 Roles ----------------------------------------------------------------------------
CREATE TABLE "Seguridad"."tblRoles"
(
    "idRol"             SMALLINT      NOT NULL GENERATED ALWAYS AS IDENTITY,
    "nombreRol"         VARCHAR(50)   NOT NULL,
    "descripcionRol"    TEXT,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkRol"          PRIMARY KEY ("idRol"),
    CONSTRAINT "ukRol_Nombre"   UNIQUE ("nombreRol")
);
COMMENT ON TABLE "Seguridad"."tblRoles" IS 'Catálogo de roles.';

-- 3.3 Usuarios - Roles (N:M) -----------------------------------------------------------
CREATE TABLE "Seguridad"."tblUsuariosRoles"
(
    "idUsuario"         INT           NOT NULL,
    "idRol"             SMALLINT      NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkUsuarioRol"           PRIMARY KEY ("idUsuario", "idRol"),
    CONSTRAINT "fkUsuarioRol_Usuario"   FOREIGN KEY ("idUsuario")
        REFERENCES "Seguridad"."tblUsuarios" ("idUsuario") ON DELETE CASCADE,
    CONSTRAINT "fkUsuarioRol_Rol"       FOREIGN KEY ("idRol")
        REFERENCES "Seguridad"."tblRoles" ("idRol") ON DELETE CASCADE
);
-- La PK ya indexa ("idUsuario", ...); se indexa "idRol" para búsquedas/borrados por rol.
CREATE INDEX "ixUsuarioRol_Rol" ON "Seguridad"."tblUsuariosRoles" ("idRol");


/* =====================================================================================
   4. CATÁLOGOS
   ===================================================================================== */

-- 4.1 Tipos de solicitud ---------------------------------------------------------------
CREATE TABLE "Catalogos"."tblTiposSolicitud"
(
    "idTipoSolicitud"       SMALLINT      NOT NULL GENERATED ALWAYS AS IDENTITY,
    "nombreTipoSolicitud"   VARCHAR(100)  NOT NULL,
    "usuarioRegistro"       VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"         TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkTipoSolicitud"          PRIMARY KEY ("idTipoSolicitud"),
    CONSTRAINT "ukTipoSolicitud_Nombre"   UNIQUE ("nombreTipoSolicitud")
);
COMMENT ON TABLE "Catalogos"."tblTiposSolicitud" IS 'Catálogo de tipos de solicitud.';

-- 4.2 Estados --------------------------------------------------------------------------
CREATE TABLE "Catalogos"."tblEstados"
(
    "idEstado"          SMALLINT      NOT NULL GENERATED ALWAYS AS IDENTITY,
    "nombreEstado"      VARCHAR(50)   NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkEstado"          PRIMARY KEY ("idEstado"),
    CONSTRAINT "ukEstado_Nombre"   UNIQUE ("nombreEstado")
);
COMMENT ON TABLE "Catalogos"."tblEstados" IS 'Catálogo de estados del ticket.';


/* =====================================================================================
   5. SOLICITUDES
   ===================================================================================== */

-- 5.1 Formularios (tabla padre) --------------------------------------------------------
-- "fechaRegistro" cumple la función de fecha_creacion.
CREATE TABLE "Solicitudes"."tblFormularios"
(
    "idFormulario"      INT           NOT NULL GENERATED ALWAYS AS IDENTITY,
    "idTipoSolicitud"   SMALLINT      NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormulario"                PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormulario_TipoSolicitud"  FOREIGN KEY ("idTipoSolicitud")
        REFERENCES "Catalogos"."tblTiposSolicitud" ("idTipoSolicitud")
);
CREATE INDEX "ixFormulario_TipoSolicitud" ON "Solicitudes"."tblFormularios" ("idTipoSolicitud");
COMMENT ON TABLE "Solicitudes"."tblFormularios" IS
    'Datos generales de cada formulario. El detalle vive en la tabla específica (relación 1:1).';

-- 5.2 Formularios específicos (1:1 con tblFormularios, PK = FK) ------------------------
CREATE TABLE "Solicitudes"."tblFormulariosAfiche"
(
    "idFormulario"      INT           NOT NULL,
    "dimensiones"       VARCHAR(50)   NOT NULL,          -- ej. '60x90 cm', 'A3'
    "orientacion"       VARCHAR(10)   NOT NULL,
    "textoPrincipal"    TEXT          NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormularioAfiche"              PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormularioAfiche_Formulario"   FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario") ON DELETE CASCADE,
    CONSTRAINT "chkFormularioAfiche_Orientacion" CHECK ("orientacion" IN ('Vertical', 'Horizontal'))
);

CREATE TABLE "Solicitudes"."tblFormulariosComunicado"
(
    "idFormulario"          INT           NOT NULL,
    "tituloComunicado"      VARCHAR(200)  NOT NULL,
    "contenidoComunicado"   TEXT          NOT NULL,
    "dirigidoA"             VARCHAR(200)  NOT NULL,      -- ej. 'Estudiantes', 'Docentes'
    "usuarioRegistro"       VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"         TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormularioComunicado"             PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormularioComunicado_Formulario"  FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario") ON DELETE CASCADE
);

CREATE TABLE "Solicitudes"."tblFormulariosAviso"
(
    "idFormulario"      INT           NOT NULL,
    "tituloAviso"       VARCHAR(200)  NOT NULL,
    "urgencia"          VARCHAR(10)   NOT NULL DEFAULT 'Media',
    "medioDifusion"     VARCHAR(100)  NOT NULL,          -- ej. 'Correo', 'Pantallas', 'Web'
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormularioAviso"             PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormularioAviso_Formulario"  FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario") ON DELETE CASCADE,
    CONSTRAINT "chkFormularioAviso_Urgencia"   CHECK ("urgencia" IN ('Baja', 'Media', 'Alta'))
);

CREATE TABLE "Solicitudes"."tblFormulariosCoberturaEventos"
(
    "idFormulario"      INT           NOT NULL,
    "nombreEvento"      VARCHAR(200)  NOT NULL,
    "lugar"             VARCHAR(200)  NOT NULL,
    "fechaInicio"       TIMESTAMPTZ   NOT NULL,
    "fechaFin"          TIMESTAMPTZ   NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormularioCoberturaEvento"             PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormularioCoberturaEvento_Formulario"  FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario") ON DELETE CASCADE,
    CONSTRAINT "chkFormularioCoberturaEvento_Fechas"     CHECK ("fechaFin" >= "fechaInicio")
);

CREATE TABLE "Solicitudes"."tblFormulariosEdicionFotografica"
(
    "idFormulario"      INT           NOT NULL,
    "cantidadFotos"     SMALLINT      NOT NULL,
    "estiloEdicion"     VARCHAR(100)  NOT NULL,          -- ej. 'Natural', 'Blanco y negro'
    "enlaceDrive"       VARCHAR(500)  NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormularioEdicionFotografica"               PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormularioEdicionFotografica_Formulario"    FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario") ON DELETE CASCADE,
    CONSTRAINT "chkFormularioEdicionFotografica_CantidadFotos" CHECK ("cantidadFotos" > 0),
    CONSTRAINT "chkFormularioEdicionFotografica_EnlaceDrive"   CHECK ("enlaceDrive" ~* '^https?://')
);

CREATE TABLE "Solicitudes"."tblFormulariosPublicacionRedesSociales"
(
    "idFormulario"      INT             NOT NULL,
    "plataformas"       VARCHAR(50)[]   NOT NULL,        -- ej. '{Facebook,Instagram}'
    "textoCopy"         TEXT            NOT NULL,
    "horaSugerida"      TIME,
    "usuarioRegistro"   VARCHAR(90)     NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkFormularioPublicacionRedSocial"              PRIMARY KEY ("idFormulario"),
    CONSTRAINT "fkFormularioPublicacionRedSocial_Formulario"   FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario") ON DELETE CASCADE,
    CONSTRAINT "chkFormularioPublicacionRedSocial_Plataformas" CHECK (cardinality("plataformas") > 0)
);

-- 5.3 Tickets --------------------------------------------------------------------------
-- "fechaRegistro" cumple la función de fecha. Un formulario genera un único ticket.
CREATE TABLE "Solicitudes"."tblTickets"
(
    "idTicket"          INT           NOT NULL GENERATED ALWAYS AS IDENTITY,
    "idTipoSolicitud"   SMALLINT      NOT NULL,
    "idFormulario"      INT           NOT NULL,
    "idEstado"          SMALLINT      NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkTicket"                PRIMARY KEY ("idTicket"),
    CONSTRAINT "ukTicket_Formulario"     UNIQUE ("idFormulario"),
    CONSTRAINT "fkTicket_TipoSolicitud"  FOREIGN KEY ("idTipoSolicitud")
        REFERENCES "Catalogos"."tblTiposSolicitud" ("idTipoSolicitud"),
    CONSTRAINT "fkTicket_Formulario"     FOREIGN KEY ("idFormulario")
        REFERENCES "Solicitudes"."tblFormularios" ("idFormulario"),
    CONSTRAINT "fkTicket_Estado"         FOREIGN KEY ("idEstado")
        REFERENCES "Catalogos"."tblEstados" ("idEstado")
);
-- "idFormulario" ya queda indexado por ukTicket_Formulario.
CREATE INDEX "ixTicket_TipoSolicitud" ON "Solicitudes"."tblTickets" ("idTipoSolicitud");
CREATE INDEX "ixTicket_Estado"        ON "Solicitudes"."tblTickets" ("idEstado");

-- 5.4 Historial de tickets (auditoría) --------------------------------------------------
CREATE TABLE "Solicitudes"."tblTicketLogs"
(
    "idTicketLog"           BIGINT        NOT NULL GENERATED ALWAYS AS IDENTITY,
    "idTicket"              INT           NOT NULL,
    "numeroVersion"         INT           NOT NULL,
    "descripcionCambio"     TEXT          NOT NULL,
    "usuarioRegistro"       VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"         TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkTicketLog"                PRIMARY KEY ("idTicketLog"),
    CONSTRAINT "ukTicketLog_Version"        UNIQUE ("idTicket", "numeroVersion"),
    CONSTRAINT "fkTicketLog_Ticket"         FOREIGN KEY ("idTicket")
        REFERENCES "Solicitudes"."tblTickets" ("idTicket") ON DELETE CASCADE,
    CONSTRAINT "chkTicketLog_NumeroVersion" CHECK ("numeroVersion" > 0)
);
-- "idTicket" ya queda indexado por ukTicketLog_Version (primera columna).
COMMENT ON TABLE "Solicitudes"."tblTicketLogs" IS
    'Historial de versiones del ticket. Se llena automáticamente por trigger; no insertar manualmente.';

-- 5.5 Correcciones ---------------------------------------------------------------------
-- "fechaRegistro" cumple la función de fecha_creacion.
CREATE TABLE "Solicitudes"."tblCorrecciones"
(
    "idCorreccion"      INT           NOT NULL GENERATED ALWAYS AS IDENTITY,
    "idTicket"          INT           NOT NULL,
    "comentario"        TEXT          NOT NULL,          -- ej. 'Ajustar colores'
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkCorreccion"            PRIMARY KEY ("idCorreccion"),
    CONSTRAINT "fkCorreccion_Ticket"     FOREIGN KEY ("idTicket")
        REFERENCES "Solicitudes"."tblTickets" ("idTicket") ON DELETE CASCADE,
    CONSTRAINT "chkCorreccion_Comentario" CHECK (btrim("comentario") <> '')
);
CREATE INDEX "ixCorreccion_Ticket" ON "Solicitudes"."tblCorrecciones" ("idTicket");


/* =====================================================================================
   6. NOTIFICACIONES
   Se agregan "idUsuario" (destinatario) e "idTicket" (origen, opcional): sin destinatario
   no es posible saber a quién mostrar la notificación.
   ===================================================================================== */
CREATE TABLE "Notificaciones"."tblNotificaciones"
(
    "idNotificacion"    BIGINT        NOT NULL GENERATED ALWAYS AS IDENTITY,
    "idUsuario"         INT           NOT NULL,
    "idTicket"          INT,
    "visto"             BOOLEAN       NOT NULL DEFAULT false,
    "mensaje"           TEXT          NOT NULL,
    "usuarioRegistro"   VARCHAR(90)   NOT NULL DEFAULT "Seguridad"."fnObtenerUsuarioActualEscalar"(),
    "fechaRegistro"     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "pkNotificacion"           PRIMARY KEY ("idNotificacion"),
    CONSTRAINT "fkNotificacion_Usuario"   FOREIGN KEY ("idUsuario")
        REFERENCES "Seguridad"."tblUsuarios" ("idUsuario") ON DELETE CASCADE,
    CONSTRAINT "fkNotificacion_Ticket"    FOREIGN KEY ("idTicket")
        REFERENCES "Solicitudes"."tblTickets" ("idTicket") ON DELETE CASCADE
);
CREATE INDEX "ixNotificacion_Usuario"        ON "Notificaciones"."tblNotificaciones" ("idUsuario");
CREATE INDEX "ixNotificacion_Ticket"         ON "Notificaciones"."tblNotificaciones" ("idTicket");
-- Índice parcial para la consulta más frecuente: "notificaciones no vistas del usuario X".
CREATE INDEX "ixNotificacion_UsuarioNoVisto" ON "Notificaciones"."tblNotificaciones" ("idUsuario", "fechaRegistro" DESC)
    WHERE "visto" = false;


/* =====================================================================================
   7. LÓGICA AUTOMÁTICA (FUNCIONES Y TRIGGERS)
   ===================================================================================== */

-- 7.1 Validación: el tipo de solicitud del ticket debe coincidir con el del formulario --
CREATE OR REPLACE FUNCTION "Solicitudes"."fnTicketValidarTipoSolicitudTrigger"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    vIdTipoFormulario SMALLINT;
BEGIN
    SELECT f."idTipoSolicitud"
      INTO vIdTipoFormulario
      FROM "Solicitudes"."tblFormularios" f
     WHERE f."idFormulario" = NEW."idFormulario";

    IF NOT FOUND THEN
        RAISE EXCEPTION 'El formulario % no existe.', NEW."idFormulario"
              USING ERRCODE = 'foreign_key_violation';
    END IF;

    IF vIdTipoFormulario IS DISTINCT FROM NEW."idTipoSolicitud" THEN
        RAISE EXCEPTION 'Tipo de solicitud inconsistente: el ticket indica % pero el formulario % es de tipo %.',
              NEW."idTipoSolicitud", NEW."idFormulario", vIdTipoFormulario
              USING ERRCODE = 'check_violation',
                    HINT    = 'Use el mismo idTipoSolicitud registrado en Solicitudes.tblFormularios.';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER "tgrTicketValidacionInsertarActualizar"
BEFORE INSERT OR UPDATE OF "idTipoSolicitud", "idFormulario"
ON "Solicitudes"."tblTickets"
FOR EACH ROW
EXECUTE FUNCTION "Solicitudes"."fnTicketValidarTipoSolicitudTrigger"();


-- 7.2 Protección complementaria: impedir cambiar el tipo de un formulario que ya tiene
--     ticket (de lo contrario, el ticket quedaría inconsistente sin que su trigger se dispare).
CREATE OR REPLACE FUNCTION "Solicitudes"."fnFormularioValidarTipoSolicitudTrigger"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT 1
                 FROM "Solicitudes"."tblTickets" t
                WHERE t."idFormulario" = NEW."idFormulario"
                  AND t."idTipoSolicitud" <> NEW."idTipoSolicitud") THEN
        RAISE EXCEPTION 'No se puede cambiar el tipo de solicitud del formulario %: ya tiene un ticket asociado de otro tipo.',
              NEW."idFormulario"
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER "tgrFormularioActualizar"
BEFORE UPDATE OF "idTipoSolicitud"
ON "Solicitudes"."tblFormularios"
FOR EACH ROW
WHEN (OLD."idTipoSolicitud" IS DISTINCT FROM NEW."idTipoSolicitud")
EXECUTE FUNCTION "Solicitudes"."fnFormularioValidarTipoSolicitudTrigger"();


-- 7.3 Historial automático en tblTicketLogs ----------------------------------------------
-- Número de versión correlativo por ticket. Es seguro ante concurrencia: en un UPDATE la
-- fila del ticket ya está bloqueada por la propia sentencia, y en un INSERT el ticket es
-- nuevo y aún no es visible para otras transacciones.
CREATE OR REPLACE FUNCTION "Solicitudes"."fnTicketRegistrarHistorialTrigger"()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    vCambios        TEXT[] := ARRAY[]::TEXT[];
    vVersion        INT;
    vNombreAnterior VARCHAR(100);
    vNombreNuevo    VARCHAR(100);
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT e."nombreEstado" INTO vNombreNuevo
          FROM "Catalogos"."tblEstados" e WHERE e."idEstado" = NEW."idEstado";

        vCambios := array_append(vCambios,
            format('Ticket creado para el formulario %s con estado "%s"', NEW."idFormulario", vNombreNuevo));

    ELSE  -- UPDATE
        IF NEW."idEstado" IS DISTINCT FROM OLD."idEstado" THEN
            SELECT e."nombreEstado" INTO vNombreAnterior
              FROM "Catalogos"."tblEstados" e WHERE e."idEstado" = OLD."idEstado";
            SELECT e."nombreEstado" INTO vNombreNuevo
              FROM "Catalogos"."tblEstados" e WHERE e."idEstado" = NEW."idEstado";
            vCambios := array_append(vCambios,
                format('Estado: "%s" -> "%s"', vNombreAnterior, vNombreNuevo));
        END IF;

        IF NEW."idTipoSolicitud" IS DISTINCT FROM OLD."idTipoSolicitud" THEN
            SELECT ts."nombreTipoSolicitud" INTO vNombreAnterior
              FROM "Catalogos"."tblTiposSolicitud" ts WHERE ts."idTipoSolicitud" = OLD."idTipoSolicitud";
            SELECT ts."nombreTipoSolicitud" INTO vNombreNuevo
              FROM "Catalogos"."tblTiposSolicitud" ts WHERE ts."idTipoSolicitud" = NEW."idTipoSolicitud";
            vCambios := array_append(vCambios,
                format('Tipo de solicitud: "%s" -> "%s"', vNombreAnterior, vNombreNuevo));
        END IF;

        IF NEW."idFormulario" IS DISTINCT FROM OLD."idFormulario" THEN
            vCambios := array_append(vCambios,
                format('Formulario: %s -> %s', OLD."idFormulario", NEW."idFormulario"));
        END IF;

        -- Nada relevante cambió: no se genera versión.
        IF cardinality(vCambios) = 0 THEN
            RETURN NULL;
        END IF;
    END IF;

    SELECT COALESCE(MAX(l."numeroVersion"), 0) + 1
      INTO vVersion
      FROM "Solicitudes"."tblTicketLogs" l
     WHERE l."idTicket" = NEW."idTicket";

    INSERT INTO "Solicitudes"."tblTicketLogs"
           ("idTicket", "numeroVersion", "descripcionCambio", "usuarioRegistro")
    VALUES (NEW."idTicket", vVersion, array_to_string(vCambios, '; '),
            "Seguridad"."fnObtenerUsuarioActualEscalar"());

    RETURN NULL;  -- AFTER trigger: el valor de retorno se ignora
END;
$$;

CREATE TRIGGER "tgrTicketHistorialInsertarActualizar"
AFTER INSERT OR UPDATE
ON "Solicitudes"."tblTickets"
FOR EACH ROW
EXECUTE FUNCTION "Solicitudes"."fnTicketRegistrarHistorialTrigger"();


/* =====================================================================================
   8. DATOS INICIALES (DML) — idempotente gracias a ON CONFLICT
   ===================================================================================== */
INSERT INTO "Catalogos"."tblTiposSolicitud" ("nombreTipoSolicitud", "usuarioRegistro")
VALUES ('Afiche',                        'sistema'),
       ('Comunicado',                    'sistema'),
       ('Aviso',                         'sistema'),
       ('Cobertura de eventos',          'sistema'),
       ('Edición fotográfica',           'sistema'),
       ('Publicación en redes sociales', 'sistema')
ON CONFLICT ON CONSTRAINT "ukTipoSolicitud_Nombre" DO NOTHING;

INSERT INTO "Catalogos"."tblEstados" ("nombreEstado", "usuarioRegistro")
VALUES ('Enviado',     'sistema'),
       ('En revisión', 'sistema'),
       ('En proceso',  'sistema'),
       ('Finalizado',  'sistema'),
       ('Corrección',  'sistema'),
       ('Aprobado',    'sistema')
ON CONFLICT ON CONSTRAINT "ukEstado_Nombre" DO NOTHING;

COMMIT;


/* =====================================================================================
   9. EJEMPLO DE USO (opcional, no forma parte del despliegue)
   -------------------------------------------------------------------------------------
   BEGIN;
   SET LOCAL app.usuario = 'jperez';

   WITH f AS (
       INSERT INTO "Solicitudes"."tblFormularios" ("idTipoSolicitud")
       SELECT "idTipoSolicitud" FROM "Catalogos"."tblTiposSolicitud"
        WHERE "nombreTipoSolicitud" = 'Afiche'
       RETURNING "idFormulario", "idTipoSolicitud"
   ), d AS (
       INSERT INTO "Solicitudes"."tblFormulariosAfiche"
              ("idFormulario", "dimensiones", "orientacion", "textoPrincipal")
       SELECT "idFormulario", 'A3', 'Vertical', 'Feria de ciencias 2026' FROM f
   )
   INSERT INTO "Solicitudes"."tblTickets" ("idTipoSolicitud", "idFormulario", "idEstado")
   SELECT f."idTipoSolicitud", f."idFormulario", e."idEstado"
     FROM f, "Catalogos"."tblEstados" e
    WHERE e."nombreEstado" = 'Enviado';

   COMMIT;
   -- -> tblTicketLogs: versión 1 'Ticket creado para el formulario N con estado "Enviado"'
   ===================================================================================== */
