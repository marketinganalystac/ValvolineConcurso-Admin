# Concurso Cliente Manía · Valvoline

Dashboard de un solo archivo (`index.html`) para el concurso de ventas Valvoline de Auto Centro, S.A.
Lee y guarda sus datos en **Supabase**. No necesita build ni servidor propio.

## Contenido

```
index.html                                   # el dashboard completo (HTML + CSS + JS; el logo va embebido)
assets/logo.png                              # logo original de Auto Centro (copia de referencia)
supabase/
  migrations/
    20261002000001_esquema_inicial.sql       # tablas, índices, RLS y datos iniciales
    20261003000002_admin_por_codigo_y_rpc.sql# código de admin (hash) y funciones RPC
    20261003000003_fix_admin_activar_delete_con_where.sql# corrección: DELETE con WHERE (PostgREST)
  set_admin_code.example.sql                 # plantilla para definir el código de admin
```

## Cómo funciona

- **Viewer (por defecto):** cualquiera que abra la página ve los dashboards, filtra por mes y exporta Excel/PDF. No ve los botones de carga ni la pestaña de Metas.
- **Admin:** el botón **🔐 Admin** pide un código de 8 caracteres. Se verifica **en Supabase** (la base solo guarda el hash bcrypt) y devuelve una sesión de 12 h que vive solo en memoria: al recargar la página se vuelve a viewer.
  Con sesión de admin se habilitan las cargas (ventas CSV, multiplicadores, maestro de clientes), la edición de metas/reglas/conversión y el cambio de código.
- **Lectura:** función `datos_concurso(slug)` (pública).
- **Escritura:** funciones `guardar_*`, `ventas_iniciar`, `ventas_lote`; todas exigen el token de admin y fallan con `SESION_INVALIDA` si no es válido. Las tablas no tienen acceso directo para `anon`.
- **Bloqueo:** 5 intentos fallidos de código en 15 min bloquean nuevos intentos durante ese lapso.
- **Ventas por mes:** al cargar un CSV se reemplazan solo los meses que trae el archivo; los demás se conservan.

## Puesta en marcha en un proyecto Supabase nuevo

1. Crea el proyecto en Supabase.
2. Aplica las migraciones **en orden**:
   - CLI: `supabase link --project-ref <REF>` y luego `supabase db push`, o
   - SQL Editor: pega y ejecuta cada archivo de `supabase/migrations/` en orden.
3. Define el código de admin: copia `supabase/set_admin_code.example.sql`, cambia `CAMBIAME8` por tu código de 8 caracteres y ejecútalo en el SQL Editor. **No subas el archivo con el código real al repositorio** (ya está en `.gitignore` como `supabase/set_admin_code.sql`).
4. En `index.html`, busca el bloque `/* ===== Supabase` y ajusta:
   ```js
   var SB_URL='https://<REF>.supabase.co',   // Project Settings → API → Project URL
       SB_KEY='sb_publishable_...',          // Project Settings → API Keys → Publishable key
       SLUG='valvoline';                     // slug del concurso (tabla concursos)
   ```
   La *publishable key* es pública por diseño; **nunca** pongas la `service_role` / secret key en el HTML.
5. Publica `index.html` (Vercel, GitHub Pages, Netlify, o como archivo estático dentro del portal).

> El proyecto actual (`hvydhrtaovnrdfsagyey`) ya tiene las tres migraciones aplicadas. No vuelvas a ejecutarlas ahí; los archivos son para reproducir el esquema en otro proyecto o ambiente.

## Formato del CSV de ventas

Columnas que usa el dashboard (el resto se ignora): `AñoMes` (ej. `2026-10`), `Cuenta` (id del cliente), `Nombre Cliente`, `Nombre Vendedor`, `Descripcion`, `Item Number`, `Cantidad` y `Venta`.
Acepta codificación UTF-8 o ISO-8859-1 (se detecta sola). Sigue aceptándose el formato anterior (`Venta Por`, `ID`, `Empresa`, `Mes`, `Ventas`).
Se ignoran las filas con cantidad ≤ 0 o venta negativa, y los vendedores que no estén en la lista del concurso.

## Operación

- **Cambiar el código de admin:** botón Admin → *Cambiar código* (exactamente 8 caracteres). Cierra las demás sesiones abiertas.
  Si lo olvidaste: ejecuta de nuevo `set_admin_code` desde el SQL Editor.
- **Carga mensual:** como admin, sube `Data Valvoline.csv`; luego, si cambió, el maestro de clientes y el archivo de multiplicadores.
  Si aparecen códigos sin multiplicador, la alerta ⚠️ permite agregarlos.
- **Historial de cargas:** tabla `cargas` (archivo, filas, fecha).
- **Respaldo:** `supabase db dump` o Database → Backups en el panel de Supabase.

## Seguridad: puntos a tener presentes

- Los viewers **no inician sesión**: quien tenga el enlace de la página puede *leer* los datos (ventas, metas, incentivos). Si eso no es aceptable, protege la página (login del portal, Vercel Password Protection, etc.).
- Escribir siempre requiere el código de admin; el navegador no puede saltarse esa validación.
- Los avisos del linter de Supabase sobre funciones `SECURITY DEFINER` ejecutables por `anon` son esperados: son las puertas de entrada y cada una valida token/código dentro.

## Dependencias (CDN, ya incluidas en `index.html`)

SheetJS (lectura de Excel/CSV), jsPDF y html2canvas (PDF), ExcelJS (Excel con formato y fórmulas).
